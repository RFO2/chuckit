// RFO2 — RelatedFileScanner.swift
// RFO2 — Finds candidates and estimates their size off the UI actor.
// RFO2 — This service returns evidence for review; it does not invoke the Trash API.
// RFO2 — Progress text is published on the main actor for the scanning screen.
// RFO2 — See DEVELOPMENT.md for the full workflow and file map.

import Combine
import Foundation

@MainActor
final class RelatedFileScanner: ObservableObject {
    @Published var progress: Double = 0
    @Published var statusMessage = "Getting ready…"
    private var worker: Task<ScanResult, Never>?
    private var scanID = UUID()

    func cancel() { worker?.cancel() }

    // RFO2 — Detached traversal avoids blocking SwiftUI while published progress returns
    // RFO2 — to the main actor. scanID prevents older progress messages overwriting newer ones.
    func scan(target: AppTarget, scope: ScanScope = .appData) async -> ScanResult {
        progress = 0
        statusMessage = scope == .expanded ? "Searching personal folders on the internal drive…" : "Searching app-data folders…"
        let id = UUID()
        scanID = id
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            Self.search(target: target, locations: scope.locations(for: target), onProgress: { [weak self] count, path in
                Task { @MainActor [weak self] in
                    guard let self, self.scanID == id else { return }
                    self.statusMessage = "Checked \(count) items · \(path)"
                }
            })
        }
        worker = task
        let result = await task.value
        guard scanID == id else { return result }
        worker = nil
        progress = 1
        statusMessage = "Done"
        return result
    }

    // RFO2 — Keep discovery separate from removal. The explicit locations parameter lets
    // RFO2 — regression tests scan disposable trees instead of a real application installation.
    nonisolated static func search(target: AppTarget, locations: [ScanLocation]? = nil, onProgress: @escaping @Sendable (Int, String) -> Void = { _, _ in }) -> ScanResult {
        let fm = FileManager.default
        guard InternalDrivePolicy.allows(target.url) else {
            return ScanResult(target: target, files: [], warnings: ["This app is outside the internal startup drive. External drives and network volumes are never searched."])
        }
        var files = [RelatedFile(url: target.url, locationDescription: "Application", sizeBytes: size(of: target.url), requiresAdmin: RemovalPolicy.needsAdmin(target.url), evidence: "Selected application")]
        var seen: Set<String> = [target.url.standardizedFileURL.path]
        let excludedNames: Set<String> = [".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd", ".git", "node_modules", "DerivedData", ".build", "Backups.backupdb"]
        var visited = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .volumeURLKey]
        // RFO2 — Combine evidence with location before choosing the initial checkbox state.
        // RFO2 — Preselection follows the validated scan root, never a path substring: a personal
        // RFO2 — folder can contain "/Library/" without being app data.
        func addCandidate(_ entry: URL, in location: ScanLocation, evidence: MatchEngine.Evidence) -> Bool {
            // RFO2 — The enumerator reports /private/var paths; keep the standard /var form the
            // RFO2 — rest of the app (and Finder) uses so rows compare and display consistently.
            let entry = entry.standardizedFileURL
            guard RemovalPolicy.rejectionReason(for: entry) == nil,
                  seen.insert(entry.standardizedFileURL.path).inserted else { return false }
            // RFO2 — Shared data is decided by the scan root, not a path substring: either a known
            // RFO2 — app-group container root, or an entry sitting directly in a Group Containers folder.
            let groupRoot = location.url.deletingLastPathComponent().lastPathComponent == "Group Containers" && RemovalPolicy.contains(entry, in: location.url)
            let shared = groupRoot || entry.deletingLastPathComponent().lastPathComponent == "Group Containers"
            let appData = location.isAppData
            files.append(RelatedFile(url: entry, locationDescription: appData ? "App data" : "Internal drive search", sizeBytes: size(of: entry), requiresAdmin: RemovalPolicy.needsAdmin(entry), isSelected: evidence.selected && appData && !shared, evidence: shared ? "Shared app group — review before selecting" : evidence.reason))
            return true
        }
        for location in locations ?? ScanLocation.appData(for: target) {
            if Task.isCancelled { break }
            guard !ScanExclusions.contains(location.url), InternalDrivePolicy.allows(location.url),
                  !PrivacyGuard.blocks(location.url) else { continue }
            // RFO2 — App-specific locations often do not exist; that is not an access denial.
            if DeletionService.isAbsent(location.url) || !fm.isReadableFile(atPath: location.url.path) { continue }
            if (try? location.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            if location.includesRootCandidate,
               let evidence = MatchEngine.evidence(at: location.url, target: target),
               addCandidate(location.url, in: location, evidence: evidence) { continue }
            guard let iterator = fm.enumerator(at: location.url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in
                // RFO2 — Access failures are expected in a broad scan; skip silently.
                return true
            }) else { continue }
            // RFO2 — Normal scans look only a couple of levels into broad drawers (Application
            // RFO2 — Support, Caches, Logs…). App-specific container roots are walked fully.
            let maxDepth = location.isAppData && !location.includesRootCandidate ? 2 : Int.max
            for case let entry as URL in iterator {
                if Task.isCancelled { break }
                if iterator.level > maxDepth {
                    iterator.skipDescendants()
                    continue
                }
                if ScanExclusions.contains(entry) || PrivacyGuard.blocks(entry) {
                    iterator.skipDescendants()
                    continue
                }
                guard let v = try? entry.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
                guard InternalDrivePolicy.allowsEnumeratedEntry(entry) else {
                    iterator.skipDescendants()
                    continue
                }
                if v.isDirectory == true && !fm.isReadableFile(atPath: entry.path) {
                    iterator.skipDescendants()
                    continue
                }
                visited += 1
                if visited % 500 == 0 { onProgress(visited, entry.deletingLastPathComponent().path) }
                if excludedNames.contains(entry.lastPathComponent) || RemovalPolicy.contains(entry, in: target.url) {
                    iterator.skipDescendants(); continue
                }
                if let evidence = MatchEngine.evidence(at: entry, target: target), addCandidate(entry, in: location, evidence: evidence) {
                    if v.isDirectory == true { iterator.skipDescendants() }
                } else if entry.pathExtension == "app" || (try? entry.resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
                    iterator.skipDescendants()
                }
            }
        }
        // RFO2 — A selected directory includes its children; avoid double counting and
        // RFO2 — conflicting checkboxes. Keep nested candidates beneath unchecked parents.
        // RFO2 — A selected parent already includes its descendants. Remove redundant selected
        // RFO2 — rows so totals and later operations do not count the same subtree twice.
        let selectedParents = files.filter { $0.isSelected }.map(\.url)
        files.removeAll { f in selectedParents.contains { $0 != f.url && RemovalPolicy.contains(f.url, in: $0) } }
        files.sort { a, b in
            if a.url == target.url { return true }
            if b.url == target.url { return false }
            return a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending
        }
        var warnings: [String] = []
        if Task.isCancelled { warnings.append("Scan cancelled; these results are incomplete.") }
        return ScanResult(target: target, files: files, warnings: warnings)
    }

    // RFO2 — Sizes are estimates gathered during discovery, not a promise of freed space.
    // RFO2 — Use the same volume boundary during sizing as during candidate traversal.
    // RFO2 — Finder-style on-disk size: allocated bytes, each hard-linked file counted once.
    nonisolated static func allocatedSize(_ v: URLResourceValues) -> Int64 {
        Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
    }

    nonisolated static func size(of url: URL) -> Int64 {
        guard !ScanExclusions.contains(url), InternalDrivePolicy.allows(url) else { return 0 }
        let fm = FileManager.default
        let sizeKeys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey, .volumeURLKey, .linkCountKey]
        if let v = try? url.resourceValues(forKeys: sizeKeys), v.isDirectory != true || v.isSymbolicLink == true { return allocatedSize(v) }
        var total: Int64 = 0
        var seenLinked = Set<DeletionService.FileIdentity>()
        if let iterator = fm.enumerator(at: url, includingPropertiesForKeys: Array(sizeKeys), options: []) {
            for case let child as URL in iterator {
                if Task.isCancelled { break }
                if ScanExclusions.contains(child) {
                    iterator.skipDescendants()
                    continue
                }
                guard let v = try? child.resourceValues(forKeys: sizeKeys), v.isSymbolicLink != true else { continue }
                guard InternalDrivePolicy.allowsEnumeratedEntry(child) else {
                    iterator.skipDescendants()
                    continue
                }
                guard v.isDirectory != true else { continue }
                if (v.linkCount ?? 1) > 1, let identity = DeletionService.FileIdentity.of(child) {
                    guard seenLinked.insert(identity).inserted else { continue }
                }
                total += allocatedSize(v)
            }
        }
        return total
    }
}
