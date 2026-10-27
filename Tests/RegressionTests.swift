// RFO2 — RegressionTests.swift
// RFO2 — Standalone checks use disposable fixture trees and an injected recycler.
// RFO2 — They exercise selection, scope and recoverable moves without uninstalling
// RFO2 — real applications. Native Finder authorization remains an integration check.

import AppKit
import Foundation
import Carbon

@main
struct RegressionTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func main() async throws {
        // RFO2 — Fixture scans must not inherit the app's persisted limited-access mode.
        // RFO2 — The volatile argument domain affects this process only; restore it on exit.
        let defaults = UserDefaults.standard
        let previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var testArguments = previousArguments
        testArguments[PrivacyGuard.defaultsKey] = false
        defaults.setVolatileDomain(testArguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
        let fm = FileManager.default
        // RFO2 — each run receives a unique fixture root and cleans it on exit.
        // RFO2 — Test paths and fake applications stay separate from installed software.
        // RFO2 — Use temporary storage: Desktop/Documents are intentionally protected by removal policy.
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("chuckit-fixture-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func file(_ relative: String) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
            return url
        }
        let app = root.appendingPathComponent("Fixture.app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let target = AppTarget(url: app, name: "Fixture", bundleIdentifier: "com.example.fixture", teamIdentifier: nil, groupIdentifiers: ["group.com.example.fixture"], helperBundleIdentifiers: ["com.example.fixture.agent"])
        check(MatchEngine.matches(fileName: "com.example.fixture.plist", target: target), "Bundle preference not matched")
        check(!MatchEngine.matches(fileName: "com.example.fixtureOther.plist", target: target), "Identifier collision")
        check(!MatchEngine.identifierMatches("com.example.fixture.otherproduct", identifier: "com.example.fixture") && MatchEngine.evidence(fileName: "com.example.fixture.otherproduct", target: target)?.selected != true, "Sibling bundle identifier matched")
        check(MatchEngine.evidence(fileName: "com.example.fixture.otherproduct.plist", target: target)?.selected != true, "Sibling bundle preference matched")
        check(MatchEngine.matches(fileName: "com.example.fixture.savedState", target: target), "Saved state not matched")
        check(MatchEngine.matches(fileName: "com.example.fixture.agent.plist", target: target), "Embedded helper preference not matched")
        check(!MatchEngine.matches(fileName: "NotFixture", target: target), "Name collision")
        check(MatchEngine.evidence(fileName: "Fixture Notes", target: target)?.selected == false, "Weak matches must need review")
        check(MatchEngine.evidence(fileName: "group.com.example.fixture", target: target)?.selected == false, "Shared group must need review")
        check(RemovalPolicy.rejectionReason(for: URL(fileURLWithPath: "/Library")) != nil, "Shared library removable")
        check(RemovalPolicy.rejectionReason(for: URL(fileURLWithPath: "/System/Applications/Mail.app")) != nil, "Protected app removable")
        check(!RemovalPolicy.contains(URL(fileURLWithPath: "/Applications/Foo.app2"), in: URL(fileURLWithPath: "/Applications/Foo.app")), "Path prefix collision")
        check(InternalDrivePolicy.allows(root), "Internal fixture root excluded")
        let externalApp = URL(fileURLWithPath: "/Volumes/Chuckit Excluded Volume/External.app")
        let networkApp = URL(fileURLWithPath: "/Network/Chuckit Excluded Share/Network.app")
        check(!InternalDrivePolicy.allows(externalApp), "External app accepted")
        check(!InternalDrivePolicy.allows(networkApp), "Network app accepted")
        check(!InternalDrivePolicy.allows(URL(fileURLWithPath: "/System/Volumes/Data/Volumes/External/App.app")), "APFS alias of an excluded volume accepted")
        check(RemovalPolicy.rejectionReason(for: externalApp)?.contains("internal startup drive") == true, "External removal not rejected with clear guidance")
        check(ScanLocation.all.allSatisfy { InternalDrivePolicy.allows($0.url) }, "Expanded scan includes an excluded volume")
        let excludedLocations = ScanLocation.appData(for: target, home: URL(fileURLWithPath: "/Volumes/Excluded Home"), systemLibrary: URL(fileURLWithPath: "/Network/Excluded Library"), temporary: externalApp.deletingLastPathComponent())
        check(excludedLocations.isEmpty, "Normal scan includes excluded home or temporary roots")
        let excludedTarget = AppTarget(url: externalApp, name: "External", bundleIdentifier: "com.example.fixture", teamIdentifier: nil, groupIdentifiers: [], helperBundleIdentifiers: [])
        let externalScan = RelatedFileScanner.search(target: excludedTarget, locations: [ScanLocation(description: "Internal fixture", url: root)])
        check(externalScan.files.isEmpty && externalScan.warnings.first?.contains("never searched") == true, "External app reached the scanner")
        let excludedRootScan = RelatedFileScanner.search(target: target, locations: [ScanLocation(description: "Excluded fixture", url: externalApp.deletingLastPathComponent(), includesRootCandidate: true)])
        check(excludedRootScan.files.count == 1 && excludedRootScan.files[0].url == target.url, "Excluded root produced candidates")
        check(RelatedFileScanner.size(of: externalApp) == 0, "Excluded app was inspected for size")
        let mountLink = root.appendingPathComponent("linked-external-volume")
        try fm.createSymbolicLink(at: mountLink, withDestinationURL: externalApp.deletingLastPathComponent())
        check(!InternalDrivePolicy.allows(mountLink), "Link to external volume accepted")
        for path in ScanExclusions.systemTrees {
            let excluded = URL(fileURLWithPath: path)
            check(ScanExclusions.contains(excluded), "Protected system root not excluded")
            check(ScanExclusions.contains(excluded.appendingPathComponent("com.example.fixture.plist")), "Protected descendant not excluded")
            check(ScanExclusions.contains(URL(fileURLWithPath: "/System/Volumes/Data" + path)), "APFS alias not excluded")
            check(!ScanExclusions.contains(URL(fileURLWithPath: path + "-other")), "Exclusion matched an unrelated path prefix")
            let skipped = RelatedFileScanner.search(target: target, locations: [ScanLocation(description: "Excluded system tree", url: excluded, includesRootCandidate: true)])
            check(skipped.files.count == 1 && skipped.warnings.isEmpty, "Excluded tree produced candidates or a warning")
            check(RelatedFileScanner.size(of: excluded) == 0, "Excluded tree inspected for size")
        }
        let hidden = try file("Library/Caches/.hidden/com.example.fixture.plist")
        let other = try file("Library/Caches/com.example.fixtureOther.plist")
        let document = try file("Documents/Fixture Notes.txt")
        let shared = try file("Library/Group Containers/group.com.example.fixture/data")
        let launch = root.appendingPathComponent("Library/LaunchAgents/arbitrary-service.plist")
        try fm.createDirectory(at: launch.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["Label": "arbitrary-service", "ProgramArguments": [app.appendingPathComponent("Contents/MacOS/Fixture").path]], format: .xml, options: 0).write(to: launch)
        let container = root.appendingPathComponent("Library/Containers/01234567-89AB-CDEF")
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": "com.example.fixture"], format: .binary, options: 0).write(to: container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        let ownedContainerFile = try file("Library/Containers/com.example.fixture/Data/cache.dat")
        let otherContainerFile = try file("Library/Containers/com.example.other/Data/keep.dat")
        let personalMatches = try ["Desktop", "Documents", "Downloads"].map {
            try file($0 + "/com.example.fixture.plist")
        }
        // RFO2 — normal scope must find app data without entering personal folders
        // RFO2 — or an unrelated app's container. Keep those files as preservation sentinels.
        let normalLocations = ScanLocation.appData(for: target, home: root,
            systemLibrary: root.appendingPathComponent("SystemLibrary"), temporary: nil)
        check(!normalLocations.contains { $0.url == root || $0.url == root.appendingPathComponent("Library") }, "Normal scan enumerates a broad home or Library root")
        let absentScan = RelatedFileScanner.search(target: target, locations: [ScanLocation(description: "Absent fixture", url: root.appendingPathComponent("does-not-exist"))])
        check(absentScan.warnings.isEmpty, "Missing app-data location reported as a permission denial")
        let normalScan = RelatedFileScanner.search(target: target, locations: normalLocations)
        check(normalScan.files.contains { $0.url == hidden && $0.isSelected }, "Normal scan missed app cache")
        check(normalScan.files.contains { $0.url == ownedContainerFile.deletingLastPathComponent().deletingLastPathComponent() && $0.isSelected }, "Normal scan missed the app-specific container root")
        check(normalScan.files.contains { $0.url == shared.deletingLastPathComponent() && !$0.isSelected }, "Normal scan missed the known shared app group or selected it automatically")
        check(!normalScan.files.contains { personalMatches.contains($0.url) || $0.url == document }, "Normal scan entered personal folders")
        check(!normalLocations.contains { RemovalPolicy.contains(otherContainerFile, in: $0.url) }, "Normal scan visits unrelated containers")
        check(personalMatches.allSatisfy { fm.fileExists(atPath: $0.path) } && fm.fileExists(atPath: otherContainerFile.path), "Scope checking changed unrelated files")
        let link = root.appendingPathComponent("Library/linked")
        try fm.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("Documents"))
        check(RemovalPolicy.rejectionReason(for: link.appendingPathComponent("Fixture Notes.txt")) != nil, "Ancestor symlink accepted")
        let privateHidden = URL(fileURLWithPath: hidden.resolvingSymlinksInPath().path)
        check(RemovalPolicy.rejectionReason(for: privateHidden) == nil && RemovalPolicy.rejectionReason(for: hidden) == nil, "/private/var and /var treated as a symlink difference")
        check(RemovalPolicy.rejectionReason(for: URL(fileURLWithPath: "/private" + link.appendingPathComponent("Fixture Notes.txt").path)) != nil, "Ancestor symlink accepted under /private")
        let scan = RelatedFileScanner.search(target: target, locations: [ScanLocation(description: "Fixtures", url: root)])
        check(scan.files.contains { $0.url == hidden && !$0.isSelected }, "Hidden app data missed or preselected outside app-data scope")
        check(!scan.files.contains { $0.url == other }, "Other app selected")
        check(scan.files.contains { $0.url == document && !$0.isSelected }, "User document should require review")
        check(scan.files.contains { $0.url == shared.deletingLastPathComponent() && !$0.isSelected }, "Shared container automatically selected")
        check(scan.files.contains { $0.url == launch }, "launchd executable association missed")
        check(scan.files.contains { $0.url.path == container.path }, "UUID-named app container missed")
        let parent = try file("nested/child").deletingLastPathComponent()
        let f1 = RelatedFile(url: parent, locationDescription: "Fixture", sizeBytes: 0, requiresAdmin: false)
        let f2 = RelatedFile(url: parent.appendingPathComponent("child"), locationDescription: "Fixture", sizeBytes: 0, requiresAdmin: false)
        check(DeletionService.deduplicated([f1,f2,f1]).count == 1, "Nested deletion counted twice")
        let trash = root.appendingPathComponent(".Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        // RFO2 — A filesystem-backed recycler keeps fixtures recoverable and injects
        // RFO2 — failures without authorization prompts or touching real user data.
        let fixtureRecycler: DeletionService.Recycler = { urls in
            var destinations: [URL: URL] = [:]
            for url in urls {
                do {
                    let destination = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                    try FileManager.default.moveItem(at: url, to: destination)
                    destinations[url] = destination
                } catch { return .init(destinations: destinations, failureMessage: error.localizedDescription) }
            }
            return .init(destinations: destinations, failureMessage: nil)
        }
        func related(_ url: URL) -> RelatedFile {
            RelatedFile(url: url, locationDescription: "Fixture", sizeBytes: 7, requiresAdmin: false)
        }
        let mustNotRecycle: DeletionService.Recycler = { _ in fatalError("External item reached a recycler") }
        let excludedRemoval = await DeletionService.chuck([related(externalApp)], target: target, progress: { _ in }, recycler: mustNotRecycle)
        check(excludedRemoval.trashed.isEmpty && excludedRemoval.failed.count == 1, "External deletion not blocked")
        check(!DeletionService.confirmedTrashMove(from: externalApp, to: URL(fileURLWithPath: "/Volumes/Excluded/.Trashes/501/App.app")), "External Trash receipt accepted")
        let moved = await DeletionService.chuck([related(hidden)], target: target, progress: { _ in }, recycler: fixtureRecycler)
        check(moved.trashed.count == 1 && moved.failed.isEmpty, "Fixture was not trashed")
        check(DeletionService.isAbsent(hidden), "Trashed fixture remains at its source")
        let recovered = try fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil).first!
        let recoveredData = try Data(contentsOf: recovered)
        check(recoveredData == Data("fixture".utf8), "Trashed contents changed")
        try fm.moveItem(at: recovered, to: hidden)
        check(fm.fileExists(atPath: hidden.path), "Trashed fixture could not be restored")
        check(fm.fileExists(atPath: other.path) && fm.fileExists(atPath: document.path), "Unrelated data moved")
        let missing = root.appendingPathComponent("vanished.txt")
        let vanished = await DeletionService.chuck([related(missing)], target: target, progress: { _ in }, recycler: fixtureRecycler)
        check(vanished.trashed.isEmpty && vanished.failed.count == 1, "Missing item claimed as trashed")
        let unusual = try ["quote's.txt", "double\"quote.txt", "back\\slash.txt", "line\nbreak.txt", "$(echo unsafe).txt", "unicode-é.txt", "space name.txt"].map { try file("quoting/" + $0) }
        let sentinel = try file("quoting/keep.txt")
        let quoted = await DeletionService.chuck(unusual.map(related), target: target, progress: { _ in }, recycler: fixtureRecycler)
        check(quoted.trashed.count == unusual.count && quoted.failed.isEmpty, "Unusual filenames failed")
        check(fm.fileExists(atPath: sentinel.path), "Unrelated sentinel moved")
        for original in unusual {
            let destination = try fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasSuffix("-" + original.lastPathComponent) }!
            let destinationData = try Data(contentsOf: destination)
            check(destinationData == Data("fixture".utf8), "Unusual filename contents were not preserved")
        }
        let sameNames = try [file("collision-a/same.txt"), file("collision-b/same.txt")]
        let collisions = await DeletionService.chuck(sameNames.map(related), target: target, progress: { _ in }, recycler: fixtureRecycler)
        check(collisions.trashed.count == 2 && collisions.failed.isEmpty, "Duplicate basenames did not both survive in Trash")
        let first = try file("partial/first.txt"), blocked = try file("partial/blocked.txt")
        let blockedRecycler: DeletionService.Recycler = { urls in
            let successes = await fixtureRecycler(urls.filter { $0 != blocked })
            return .init(destinations: successes.destinations, failureMessage: "Fixture permission denied")
        }
        let partialMove = await DeletionService.chuck([related(first), related(blocked), related(app)], target: target, progress: { _ in }, recycler: blockedRecycler)
        check(partialMove.trashed.count == 1 && partialMove.failed.count == 2, "Partial failure reported incorrectly")
        check(fm.fileExists(atPath: app.path) && fm.fileExists(atPath: blocked.path), "App or failed item moved after partial failure")
        let emptyReceipt: DeletionService.Recycler = { _ in .init(destinations: [:], failureMessage: "Fixture cancellation") }
        let cancelled = await DeletionService.chuck([related(blocked), related(app)], target: target, progress: { _ in }, recycler: emptyReceipt)
        check(cancelled.trashed.isEmpty && cancelled.failed.count == 2, "Cancellation claimed success")
        check(fm.fileExists(atPath: blocked.path) && fm.fileExists(atPath: app.path), "Cancellation changed files")
        let falseReceipt: DeletionService.Recycler = { urls in
            .init(destinations: Dictionary(uniqueKeysWithValues: urls.map { ($0, trash.appendingPathComponent("nonexistent")) }), failureMessage: nil)
        }
        let unverified = await DeletionService.chuck([related(blocked)], target: target, progress: { _ in }, recycler: falseReceipt)
        check(unverified.trashed.isEmpty && unverified.failed.count == 1, "Unverified move claimed success")
        let forbidden = await DeletionService.chuck([related(URL(fileURLWithPath: "/Library"))], target: target, progress: { _ in }, recycler: fixtureRecycler)
        check(forbidden.trashed.isEmpty && forbidden.failed.count == 1, "Protected shared folder reached recycler")
        let success = await DeletionService.chuck([related(blocked), related(app)], target: target, progress: { _ in }, recycler: fixtureRecycler)
        check(success.trashed.count == 2 && success.failed.isEmpty, "App was not moved after all leftovers succeeded")
        check(DeletionService.isAbsent(app), "Successful app remains at source")
        check(!DeletionService.confirmedTrashMove(from: missing, to: other), "Non-Trash destination accepted")
        check(!DeletionService.confirmedTrashMove(from: other, to: other), "Unchanged source accepted")
        let denied = root.appendingPathComponent("denied")
        try fm.createDirectory(at: denied, withIntermediateDirectories: true)
        let unreadableMatch = try file("denied/com.example.fixture.plist")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        let partial = RelatedFileScanner.search(target: target, locations: [ScanLocation(description: "Denied fixture", url: denied)])
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path)
        check(partial.warnings.isEmpty && !partial.files.contains { $0.url == unreadableMatch }, "Unreadable root produced a warning or candidate")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        let skippedDescendant = RelatedFileScanner.search(target: target, locations: [ScanLocation(description: "Parent of denied fixture", url: root)])
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path)
        check(skippedDescendant.warnings.isEmpty && !skippedDescendant.files.contains { $0.url == unreadableMatch }, "Unreadable descendant produced a warning or candidate")
        check(fm.fileExists(atPath: unreadableMatch.path), "Skipped unreadable file was modified")
        // RFO2 — a denied move does not identify which macOS permission is missing.
        // RFO2 — Wrapped errors and user cancellation must retain their distinct meanings.
        let eperm = NSError(domain: NSPOSIXErrorDomain, code: 1)
        check(DeletionService.isPermissionDenied(eperm), "Permission failure not recognized")
        check(DeletionService.explanation(eperm).contains("does not establish that Full Disk Access is off"), "Permission failure falsely asserts missing FDA")
        check(DeletionService.explanation(eperm).contains("NSPOSIXErrorDomain 1"), "Original error code lost")
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [NSUnderlyingErrorKey: eperm])
        check(DeletionService.isPermissionDenied(wrapped), "Wrapped denial not recognized")
        check(!DeletionService.isPermissionDenied(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: [NSUnderlyingErrorKey: eperm])), "Cancellation turned into a permission prompt")
        let permissionRecycler: DeletionService.Recycler = { _ in .init(destinations: [:], failureMessage: DeletionService.explanation(wrapped), permissionDenied: true) }
        let appDenied = root.appendingPathComponent("Blocked.app")
        try fm.createDirectory(at: appDenied, withIntermediateDirectories: true)
        let permissionOutcome = await DeletionService.chuck([related(appDenied)], target: target, progress: { _ in }, recycler: permissionRecycler)
        check(permissionOutcome.failed.first?.permissionHelp == .application, "App denial routed to FDA instead of removal permissions")
        let dataDenied = await DeletionService.chuck([related(other)], target: target, progress: { _ in }, recycler: permissionRecycler)
        check(dataDenied.failed.first?.permissionHelp == .appData, "Data denial classified as an app")
        check(DeletionService.explanation(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)).contains("cancelled"), "Cancellation lacks clear guidance")
        // RFO2 — Finder execution is verified in the signed native app; this sandbox cannot resolve Finder's scripting dictionary.
        for url in unusual {
            let argument = FinderTrashService.event(for: url).paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.atIndex(1)?.stringValue
            check(argument == url.path, "Finder path argument was altered or escaped as executable text")
        }
        let fallbackFile = try file("fallback/refused.txt")
        let initial = DeletionService.TrashReceipt(destinations: [:], failureMessage: "permission", permissionDenied: true)
        let fallbackResult = await DeletionService.completeReceipt(for: [fallbackFile], initial: initial, fallback: fixtureRecycler)
        check(fallbackResult.destinations[fallbackFile] != nil && fallbackResult.failureMessage == nil, "Denied item did not reach recoverable fallback")
        let noRetry: DeletionService.Recycler = { _ in fatalError("Cancelled or successful items reached fallback") }
        _ = await DeletionService.completeReceipt(for: [other], initial: .init(destinations: [:], failureMessage: "cancelled"), fallback: noRetry)
        _ = await DeletionService.completeReceipt(for: [fallbackFile], initial: fallbackResult, fallback: noRetry)
        let protectedFallback = await DeletionService.completeReceipt(for: [URL(fileURLWithPath: "/Library")], initial: initial, fallback: noRetry)
        check(protectedFallback.destinations.isEmpty, "Protected folder reached Finder fallback")
        // RFO2 — RFO3 — file-safety rules: personal folders, iCloud, credentials, other users,
        // RFO2 — Apple apps, chuckit itself, the app-data allowlist and shared helper frameworks.
        let home = URL(fileURLWithPath: "/Users/fixtureuser")
        func refused(_ p: String) -> Bool { ProtectedLocations.reason(for: URL(fileURLWithPath: p), home: home) != nil }
        for p in ["/Users/fixtureuser/Documents/Taxes.pdf", "/Users/fixtureuser/Desktop/com.example.fixture.plist", "/Users/fixtureuser/Downloads/Fixture",
                  "/Users/fixtureuser/Pictures/Fixture", "/Users/fixtureuser/Desktop", "/Users/fixtureuser/Desktop/Fake.app/../Notes.txt",
                  "/Users/fixtureuser/Library/Mobile Documents/com~apple~CloudDocs/Fixture", "/Users/fixtureuser/Library/CloudStorage/Dropbox/Fixture",
                  "/Users/fixtureuser/Library/Keychains/login.keychain-db", "/Users/fixtureuser/Library/Mail/V10", "/Users/fixtureuser/.ssh/id_ed25519",
                  "/Users/fixtureuser/.config", "/Users/someoneelse/Library/Caches/com.example.fixture", "/Users/fixtureuser/Library/Preferences/com.apple.finder.plist",
                  "/Users/fixtureuser/Fixture Notes.txt", "/Users/fixtureuser/Projects/fixture", "/etc/fixture"] {
            check(refused(URL(fileURLWithPath: p).standardizedFileURL.path), "Protected location allowed: " + p)
        }
        for p in ["/Users/fixtureuser/Library/Caches/com.example.fixture", "/Users/fixtureuser/Library/Application Support/Fixture",
                  "/Users/fixtureuser/Desktop/Fixture.app", "/Users/fixtureuser/Downloads/Fixture.app", "/Applications/Fixture.app",
                  "/Library/LaunchDaemons/com.example.fixture.plist", "/Users/fixtureuser/.fixture", "/Users/fixtureuser/.config/fixture",
                  "/Users/Shared/Fixture"] {
            check(!refused(p), "Legitimate app-data location refused: " + p)
        }
        check(RemovalPolicy.rejectionReason(for: root.appendingPathComponent("Library/Caches/x")) == nil, "Temporary fixture root refused")
        check(ProtectedLocations.appRefusal(bundleIdentifier: "com.apple.Safari", url: URL(fileURLWithPath: "/Applications/Safari.app")) != nil, "Apple app accepted")
        check(ProtectedLocations.appRefusal(bundleIdentifier: "toolebag.chuckit", url: URL(fileURLWithPath: "/Applications/chuckit.app"), ownBundleIdentifier: "toolebag.chuckit") != nil, "Chuckit accepted itself")
        check(ProtectedLocations.appRefusal(bundleIdentifier: "com.example.fixture", url: app, ownBundleIdentifier: "toolebag.chuckit") == nil, "Ordinary app refused")
        let appleTarget = AppTarget(url: app, name: "Fixture", bundleIdentifier: "com.apple.fixture", teamIdentifier: nil, groupIdentifiers: [], helperBundleIdentifiers: [])
        let appleRefused = await DeletionService.chuck([related(app)], target: appleTarget, progress: { _ in }, recycler: mustNotRecycle)
        check(appleRefused.trashed.isEmpty && appleRefused.failed.count == 1, "Apple app reached the recycler")
        let helpers = MatchEngine.ownedHelperIdentifiers(["com.example.fixture.agent", "org.sparkle-project.Sparkle.Autoupdate", "com.apple.helper", "com.examplex.other"], mainIdentifier: "com.example.fixture")
        check(helpers == ["com.example.fixture.agent"], "Shared framework helper treated as owned")
        check(!MatchEngine.matches(fileName: "Fix", target: AppTarget(url: app, name: "Fx", bundleIdentifier: nil, teamIdentifier: nil, groupIdentifiers: [], helperBundleIdentifiers: [])), "Short name matched loosely")
        let historyLog = root.appendingPathComponent("logs/history.log")
        ChuckHistory.record(action: "chucked Fixture", moves: [hidden: trash.appendingPathComponent("x")], failures: [(other, "kept")], to: historyLog)
        ChuckHistory.record(action: "undo", moves: [:], failures: [], to: historyLog)
        let historyText = (try? String(contentsOf: historyLog, encoding: .utf8)) ?? ""
        check(historyText.contains("moved  " + hidden.path) && historyText.contains("kept   " + other.path) && historyText.contains("undo"), "History log missing entries")
        print("PASS: silent protected/unreadable scan exclusions; internal-drive-only selection, roots, symlinks, sizing, removal and receipts; scan scope, unrelated-file preservation, protected paths, deduplication, recoverable moves and restoration, same-name collisions, seven unusual filenames, missing items, partial failures, cancellation, false receipts, app-last ordering, personal/iCloud/credential protection, app-data allowlist, Apple-app and self refusal, shared-helper exclusion and history log. No real apps were removed.")
    }
}
