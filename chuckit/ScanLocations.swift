// RFO2 — ScanLocations.swift
// Defines where each scan mode starts.
// Normal mode uses app-data drawers and known containers. Wider mode adds
// internal-drive roots. Choosing a scope does not authorize a removal.
// See DEVELOPMENT.md for the full workflow and file map.

import Foundation

// RFO2 — The user chooses the search scope before an investigation starts.
// Keeping root selection here makes scope behavior independent of the views.
enum ScanScope: Equatable, Sendable {
    case appData
    case expanded

    func locations(for target: AppTarget) -> [ScanLocation] {
        switch self {
        case .appData: return ScanLocation.appData(for: target)
        case .expanded: return ScanLocation.all
        }
    }
}

/// Known system-service trees never contribute uninstall candidates.
/// Match whole path components, including the APFS Data alias.
enum ScanExclusions {
    static let systemTrees = [
        "/Library/Application Support/Apple/AssetCache",
        "/Library/Application Support/Apple/ParentalControls/Users",
        "/Library/Application Support/ApplePushService",
        "/Library/Application Support/com.apple.TCC",
        "/Library/Caches/Desktop Pictures",
        "/Library/Caches/com.apple.amsengagementd.classicdatavault",
        "/Library/Caches/com.apple.aned",
        "/Library/Caches/com.apple.aneuserd"
    ]

    static func contains(_ url: URL) -> Bool {
        var path = url.standardizedFileURL.path
        let dataPrefix = "/System/Volumes/Data"
        if path.hasPrefix(dataPrefix + "/") { path.removeFirst(dataPrefix.count) }
        return systemTrees.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

struct ScanLocation {
    let description: String
    let url: URL
    var includesRootCandidate = false
    // RFO2 — True for the validated app-data drawers and containers. Review
    // preselection follows this flag, never a "/Library/" substring in the path.
    var isAppData = false

    // RFO2 — Only known app/helper/group containers are added as root candidates.
    // Avoid walking every container just because a Library directory is nearby.
    static func appData(for target: AppTarget,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        systemLibrary: URL = URL(fileURLWithPath: "/Library"),
                        temporary: URL? = FileManager.default.temporaryDirectory) -> [ScanLocation] {
        // Do not enumerate the whole home, Library, other users, or volumes.
        // Container searches are restricted to identifiers supplied by this app.
        let drawers = ["Application Support", "Preferences", "Caches", "Logs", "Saved Application State", "LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools"]
        var roots = drawers.flatMap { drawer in
            [home.appendingPathComponent("Library/" + drawer), systemLibrary.appendingPathComponent(drawer)]
        }
        if let temporary { roots.append(temporary.resolvingSymlinksInPath()) }
        var locations = roots.filter { !ScanExclusions.contains($0) && InternalDrivePolicy.allows($0) && FileManager.default.fileExists(atPath: $0.path) }
            .map { ScanLocation(description: "App data", url: $0, isAppData: true) }
        let identifiers = Set([target.bundleIdentifier].compactMap { $0 } + target.helperBundleIdentifiers)
            .filter { !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." }
        let groups = Set(target.groupIdentifiers)
            .filter { !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." }
        let library = home.appendingPathComponent("Library")
        let candidates = identifiers.flatMap { identifier in
            ["Containers", "HTTPStorages", "WebKit"].map {
                library.appendingPathComponent($0).appendingPathComponent(identifier)
            }
        } + groups.map { library.appendingPathComponent("Group Containers").appendingPathComponent($0) }
        locations += candidates.filter { !ScanExclusions.contains($0) && InternalDrivePolicy.allows($0) && FileManager.default.fileExists(atPath: $0.path) }
            .map { ScanLocation(description: "App data", url: $0, includesRootCandidate: true, isAppData: true) }
        return locations
    }

    // RFO2 — Every candidate root must pass the startup-volume policy.
    // Traversal also checks each entry, because a mount can exist below an allowed root.
    static var all: [ScanLocation] {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        // Search only the internal startup drive, including readable user folders.
        // External, network and additional mounted volumes are never added.
        var roots = [home, URL(fileURLWithPath: "/Library"), URL(fileURLWithPath: "/Applications"),
                     URL(fileURLWithPath: "/Users/Shared"), URL(fileURLWithPath: "/usr/local"),
                     URL(fileURLWithPath: "/opt"), URL(fileURLWithPath: "/private/var/folders")]
        if InternalDrivePolicy.allows(URL(fileURLWithPath: "/Users")),
           let users = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Users"), includingPropertiesForKeys: [.isDirectoryKey]) {
            roots += users.filter { $0 != home && $0.lastPathComponent != "Shared" }
        }
        return roots.filter { !ScanExclusions.contains($0) && InternalDrivePolicy.allows($0) && fm.fileExists(atPath: $0.path) }.map { ScanLocation(description: $0.path, url: $0) }
    }
}
