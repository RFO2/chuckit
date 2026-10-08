// RFO2 — DeletionService.swift
// Moves only the reviewed selection to recoverable macOS Trash.
// Native recycling runs first; Finder can handle refused moves and its own
// authorization UI. Each result is accounted for as confirmed or failed.
// See DEVELOPMENT.md for the full workflow and file map.

import AppKit
import Foundation
import Darwin
import Carbon

/// Removal uses the macOS Trash API and a Finder move-to-Trash fallback. There is no permanent deletion.
enum DeletionService {
    enum PermissionHelp: Sendable { case application, appData, finderAutomation }
    struct Failure: Sendable {
        let file: RelatedFile
        let reason: String
        var permissionHelp: PermissionHelp? = nil
    }
    typealias Outcome = (trashed: [RelatedFile], failed: [Failure])
    // RFO2 — Map each original URL to its reported Trash destination. Partial batches
    // need per-item receipts so one success never hides a different failure.
    struct TrashReceipt: Sendable {
        let destinations: [URL: URL]
        let failureMessage: String?
        var permissionDenied = false
        var permissionHelp: PermissionHelp? = nil
    }
    // RFO2 — Filesystem identity survives a rename within a volume (APFS file ID).
    // A Trash receipt must identify the moved file itself; its old name is not proof.
    struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        static func of(_ url: URL) -> FileIdentity? {
            var st = stat()
            guard stat(url.path, &st) == 0 else { return nil }
            return FileIdentity(device: st.st_dev, inode: st.st_ino)
        }
    }
    typealias Recycler = @Sendable ([URL]) async -> TrashReceipt

    // RFO2 — Revalidate the reviewed paths, collapse nested selections and request a polite
    // quit for the app and known helpers. If they keep running, leave the files alone.
    static func chuck(_ files: [RelatedFile], target: AppTarget,
                      progress: @escaping @Sendable (Double) -> Void,
                      recycler: Recycler? = nil) async -> Outcome {
        var failed: [Failure] = []
        let valid = files.filter { file in
            if let reason = RemovalPolicy.rejectionReason(for: file.url) {
                failed.append(.init(file: file, reason: reason)); return false
            }
            return true
        }
        let ordered = deduplicated(valid)
        guard !ordered.isEmpty else { return ([], failed) }
        let identifiers = Set([target.bundleIdentifier].compactMap { $0 } + target.helperBundleIdentifiers)
        await MainActor.run {
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier.map(identifiers.contains) == true { app.terminate() }
        }
        for _ in 0..<30 {
            let running = await MainActor.run {
                NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier.map(identifiers.contains) == true }
            }
            if !running { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let stillRunning = await MainActor.run {
            NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier.map(identifiers.contains) == true }
        }
        if stillRunning { return ([], failed + ordered.map { .init(file: $0, reason: "The app or a helper is still running. Quit it and try again.") }) }

        let recycleItems: Recycler = recycler ?? { urls in await recycle(urls) }
        var trashed: [RelatedFile] = []
        // RFO2 — Move selected leftovers first. Keep the main app when any selected move fails,
        // so the user can resolve the failure and retry from a known installation.
        let leftovers = ordered.filter { $0.url != target.url }
        let leftoverOutcome = await trashBatch(leftovers, recycler: recycleItems)
        trashed += leftoverOutcome.trashed
        failed += leftoverOutcome.failed
        progress(Double(leftovers.count) / Double(ordered.count))
        if let appFile = ordered.first(where: { $0.url == target.url }) {
            if failed.isEmpty {
                let appOutcome = await trashBatch([appFile], recycler: recycleItems)
                trashed += appOutcome.trashed
                failed += appOutcome.failed
            } else {
                failed.append(.init(file: appFile, reason: "The app was kept because some selected items could not be moved to Trash. Resolve those errors and retry."))
            }
        }
        progress(1)
        return (trashed, failed)
    }

    private static func trashBatch(_ files: [RelatedFile], recycler: Recycler) async -> Outcome {
        var failed: [Failure] = []
        let ready = files.filter { file in
            if let reason = RemovalPolicy.rejectionReason(for: file.url) {
                failed.append(.init(file: file, reason: reason)); return false
            }
            guard !isAbsent(file.url) else {
                failed.append(.init(file: file, reason: "This item is no longer at its reviewed location. It was skipped; Chuckit did not move it to Trash.")); return false
            }
            return true
        }
        guard !ready.isEmpty else { return ([], failed) }
        await Task.detached {
            for file in ready { stopLaunchJob(for: file.url) }
        }.value
        // The native recycler handles destination collisions. A denied move
        // does not prove that Full Disk Access is disabled.
        // A receipt is required for each item, including a partially failed batch.
        let receipt = await recycler(ready.map(\.url))
        recordDiagnostic(stage: "final", urls: ready.map(\.url), receipt: receipt)
        var trashed: [RelatedFile] = []
        for file in ready {
            if let destination = receipt.destinations[file.url], confirmedTrashMove(from: file.url, to: destination) {
                trashed.append(file)
            } else {
                let help: PermissionHelp? = receipt.permissionHelp ?? (receipt.permissionDenied
                    ? (file.url.pathExtension.lowercased() == "app" ? .application : .appData) : nil)
                var reason = receipt.failureMessage ?? "The move to Trash could not be verified. Check the original location and Trash before retrying. No permanent deletion was attempted."
                if help == .application {
                    reason += " Check Privacy & Security → App Management."
                    if isOwnedByAnotherUser(file.url) {
                        reason += " This app is owned by another Mac user; Finder may require an administrator password to move it."
                    }
                } else if help == .appData {
                    reason += " Check the item's permissions and Full Disk Access for this copy of Chuckit."
                }
                failed.append(.init(file: file, reason: reason, permissionHelp: help))
            }
        }
        return (trashed, failed)
    }

    // RFO2 — NSWorkspace and Finder integration run on the main actor. The native callback
    // is bridged to async without treating a callback itself as proof of success.
    @MainActor static func recycle(_ urls: [URL]) async -> TrashReceipt {
        let initial: TrashReceipt = await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { destinations, error in
                continuation.resume(returning: TrashReceipt(destinations: destinations,
                    failureMessage: error.map(explanation), permissionDenied: error.map(isPermissionDenied) ?? false))
            }
        }
        recordDiagnostic(stage: "native", urls: urls, receipt: initial)
        return await completeReceipt(for: urls, initial: initial, fallback: { pending in
            await MainActor.run { FinderTrashService.recycle(pending) }
        })
    }

    /// Only retry refused items, never a cancellation or an unverified success.
    // RFO2 — Retry only a denied item that still exists and has no successful receipt.
    // Cancellation and an unverified disappearance must not start a second operation.
    static func completeReceipt(for urls: [URL], initial: TrashReceipt, fallback: Recycler) async -> TrashReceipt {
        guard initial.permissionDenied else { return initial }
        let pending = urls.filter { initial.destinations[$0] == nil && !isAbsent($0) && RemovalPolicy.rejectionReason(for: $0) == nil }
        guard !pending.isEmpty else { return initial }
        let recovered = await fallback(pending)
        return .init(destinations: initial.destinations.merging(recovered.destinations) { first, _ in first },
                     failureMessage: recovered.failureMessage,
                     permissionDenied: recovered.permissionDenied,
                     permissionHelp: recovered.permissionHelp)
    }

    /// Local diagnostics for development builds; no file contents or passwords are recorded.
    static func recordDiagnostic(stage: String, urls: [URL], receipt: TrashReceipt) {
        #if DEBUG
        let payload: [String: Any] = ["stage": stage, "date": ISO8601DateFormatter().string(from: Date()),
            "app": Bundle.main.bundleURL.path, "version": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "error": receipt.failureMessage ?? "", "permissionDenied": receipt.permissionDenied,
            "items": urls.map { url -> [String: Any] in
                let destination = receipt.destinations[url]
                return ["source": url.path, "sourceAbsent": isAbsent(url),
                    "destination": destination?.path ?? "", "destinationPresent": destination.map { !isAbsent($0) } ?? false,
                    "destinationStat": destination.map { dest in
                        do { _ = try FileManager.default.attributesOfItem(atPath: dest.path); return "exists" }
                        catch { return explanation(error) }
                    } ?? "no destination"]
            }]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("Chuckit-" + stage + "-trash-diagnostic.json")
            try? data.write(to: log, options: .atomic)
        }
        #endif
    }

    // RFO2 — Require an absent source and an inspectable destination under internal Trash.
    // Finder destinations are located by filesystem identity, so an older same-name
    // Trash item can never satisfy the receipt.
    static func confirmedTrashMove(from original: URL, to destination: URL) -> Bool {
        guard destination.isFileURL, InternalDrivePolicy.allows(destination),
              original.standardizedFileURL != destination.standardizedFileURL,
              destination.pathComponents.contains(".Trash") || destination.pathComponents.contains(".Trashes"),
              isAbsent(original), !isAbsent(destination) else { return false }
        // Failure to stat a destination is not evidence it exists in Trash.
        return (try? FileManager.default.attributesOfItem(atPath: destination.path)) != nil
    }

    static func deduplicated(_ files: [RelatedFile]) -> [RelatedFile] {
        var seen = Set<String>()
        let unique = files.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
        return unique.filter { child in
            !unique.contains { parent in
                guard parent.url != child.url,
                      (try? parent.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
                return RemovalPolicy.contains(child.url, in: parent.url)
            }
        }
    }

    // RFO2 — Only a no-such-file error establishes absence. A permissions or metadata error
    // must never be interpreted as successful removal.
    static func isAbsent(_ url: URL) -> Bool {
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return false }
        catch {
            let e = error as NSError
            let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError
            return e.domain == NSCocoaErrorDomain && e.code == NSFileNoSuchFileError ||
                e.domain == NSPOSIXErrorDomain && e.code == ENOENT ||
                underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOENT)
        }
    }

    // Keep wrapped errors. EACCES/EPERM do not identify a particular TCC grant.
    static func errorChain(_ error: Error) -> [NSError] {
        var result: [NSError] = []
        var next: NSError? = error as NSError
        for _ in 0..<8 {
            guard let current = next else { break }
            result.append(current)
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }

    static func isPermissionDenied(_ error: Error) -> Bool {
        let chain = errorChain(error)
        if chain.contains(where: { $0.domain == NSCocoaErrorDomain && $0.code == NSUserCancelledError || $0.domain == NSPOSIXErrorDomain && $0.code == Int(ECANCELED) }) { return false }
        return chain.contains { $0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteNoPermissionError ||
            $0.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains($0.code) }
    }

    static func isOwnedByAnotherUser(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let owner = attributes?[.ownerAccountID] as? NSNumber else { return false }
        return owner.uint32Value != getuid()
    }

    static func explanation(_ error: Error) -> String {
        let chain = errorChain(error)
        if chain.contains(where: { $0.domain == NSCocoaErrorDomain && $0.code == NSUserCancelledError || $0.domain == NSPOSIXErrorDomain && $0.code == Int(ECANCELED) }) {
            return "The move to Trash was cancelled. Check Trash for any items already moved; remaining items were left in place."
        }
        let details = chain.map { "\($0.domain) \($0.code)" }.joined(separator: " → ")
        if isPermissionDenied(error) {
            return "macOS refused the move to Trash. This can be an app-removal restriction, file ownership, or protected-data access; it does not establish that Full Disk Access is off. macOS error: " + details + "."
        }
        return "Could not move this item to Trash: " + error.localizedDescription + " (" + details + ")"
    }

    static func launchDomain(for url: URL) -> String? {
        guard url.pathExtension == "plist" else { return nil }
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        if parent == "/Library/LaunchDaemons" { return "system" }
        if parent == "/Library/LaunchAgents" || parent == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents").path {
            return "gui/\(getuid())"
        }
        return nil
    }

    // RFO2 — Ask launchctl to unload only a selected launch-service plist.
    // Use structured process arguments, never shell interpolation of a user path.
    private static func stopLaunchJob(for url: URL) {
        guard let domain = launchDomain(for: url) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", domain, url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil { process.waitUntilExit() }
    }
}


/// Finder trashes the item with its `delete` command, which moves to Trash and
/// never permanently deletes. (`move ... to trash` fails with AppleScript error
/// -1700 on some systems, a coercion failure on Finder's trash object.)
/// Finder's returned reference is not trusted for the receipt: capturing the
/// move result inside the Finder tell block produced AppleScript error -2753,
/// so the destination is located deterministically in Trash and verified there.
/// Finder owns its authorization UI; Chuckit never requests or handles a password.
/// Paths are Apple Event arguments, never interpolated into executable script.
enum FinderTrashService {
    static let scriptSource = """
    on chuckReviewedItem(itemPath)
        tell application id "com.apple.finder"
            delete (POSIX file itemPath as alias)
        end tell
    end chuckReviewedItem
    """

    // RFO2 — Pass the filename as an Apple Event string argument. Quotes and shell-like
    // characters in a filename cannot become executable AppleScript source.
    static func event(for url: URL) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "chuckrevieweditem"), forKeyword: AEKeyword(keyASSubroutineName))
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: url.path), at: 1)
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    @MainActor static func recycle(_ urls: [URL]) -> DeletionService.TrashReceipt {
        guard let script = NSAppleScript(source: scriptSource) else {
            return .init(destinations: [:], failureMessage: "Finder's Trash operation could not be prepared. No permanent deletion was attempted.")
        }
        var destinations: [URL: URL] = [:]
        for url in urls {
            // Recheck before each Finder operation, including after an authorization delay.
            if let rejection = RemovalPolicy.rejectionReason(for: url) {
                return .init(destinations: destinations, failureMessage: rejection)
            }
            guard !DeletionService.isAbsent(url) else {
                return .init(destinations: destinations, failureMessage: "The reviewed item changed location. Check Trash before retrying.")
            }
            // RFO2 — Capture identity before the move. Finder's result is not trusted,
            // and the name alone cannot prove the receipt when an older same-name
            // item already sits in Trash.
            let identity = DeletionService.FileIdentity.of(url)
            var error: NSDictionary?
            script.executeAppleEvent(event(for: url), error: &error)
            if let error {
                let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
                if code == -128 {
                    return .init(destinations: destinations, failureMessage: "The Finder move was cancelled. Remaining items were left in place.")
                }
                if code == -1743 {
                    return .init(destinations: destinations,
                        failureMessage: "Finder authorization was not granted. Allow Chuckit to control Finder in Privacy & Security → Automation, then quit and reopen Chuckit and retry. Chuckit only uses Finder to move reviewed items to Trash.",
                        permissionDenied: true, permissionHelp: .finderAutomation)
                }
                let message = error[NSAppleScript.errorMessage] as? String ?? "Finder refused the move."
                return .init(destinations: destinations, failureMessage: "Finder could not move the item to Trash: " + message + " (macOS error " + String(code) + ").",
                    permissionDenied: [-54, -5000].contains(code))
            }
            // The move reported success. Finder's result value is not trusted
            // for the receipt, so the item is located in Trash deterministically.
            guard DeletionService.isAbsent(url) else {
                return .init(destinations: destinations, failureMessage: "Finder reported success but the item is still at its original location. Nothing was moved to Trash.")
            }
            guard let destination = locateInTrash(original: url, identity: identity),
                  DeletionService.confirmedTrashMove(from: url, to: destination) else {
                return .init(destinations: destinations, failureMessage: "The item left its original location but Chuckit could not verify it in Trash, so the move is unverified. Check Trash manually before retrying. Nothing was permanently deleted.")
            }
            DeletionService.recordDiagnostic(stage: "finder", urls: [url], receipt: .init(destinations: [url: destination], failureMessage: nil))
            destinations[url] = destination
        }
        return .init(destinations: destinations, failureMessage: nil)
    }

    /// Removal is restricted to the internal startup drive; only its user Trash is searched.
    static func trashDirectory(for source: URL) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    }

    /// Locate a just-moved item in Trash by filesystem identity. Handles Finder's
    /// collision renaming ("Name 2.ext", "Name 3.ext", ...). A pre-existing
    /// same-name item has a different identity and is never returned.
    // RFO2 — Basename matching alone could verify the receipt against an older
    // same-name Trash item. Identity comparison makes the receipt refer to the
    // moved file itself; without a captured identity the move stays unverified.
    static func locateInTrash(original url: URL, identity: DeletionService.FileIdentity?) -> URL? {
        let trash = trashDirectory(for: url)
        guard InternalDrivePolicy.allows(trash), let identity else { return nil }
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
        var candidates = [trash.appendingPathComponent(url.lastPathComponent)]
        for i in 2...99 {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            candidates.append(trash.appendingPathComponent(name))
        }
        return candidates.first { candidate in
            !DeletionService.isAbsent(candidate) && DeletionService.FileIdentity.of(candidate) == identity
        }
    }
}
