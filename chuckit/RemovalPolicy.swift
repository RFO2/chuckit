// RFO2 — RemovalPolicy.swift
// Shared path and volume checks for discovery and removal.
// The same rules are rechecked when removal starts, because the filesystem
// may have changed since the review screen was shown.
// See DEVELOPMENT.md for the full workflow and file map.

import Foundation

/// Only the internal startup volume and its APFS Data volume are eligible.
/// Volume identity also rejects mounts placed inside an otherwise allowed folder.
enum InternalDrivePolicy {
    private static let startupPaths: Set<String> = ["/", "/System/Volumes/Data"]
    // RFO2 — Approve the startup volume and its APFS Data counterpart only when macOS
    // reports both internal storage and a local volume. A readable mount is not enough.
    private static let approvedVolumes: Set<String> = Set(startupPaths.filter { path in
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey]) else { return false }
        return values.volumeIsInternal == true && values.volumeIsLocal == true
    })

    // RFO2 — Check the supplied path and its resolved location. For missing candidates,
    // use the nearest existing parent only to classify the volume, not to scan it.
    static func allows(_ url: URL) -> Bool {
        guard url.isFileURL, pathIsEligible(url) else { return false }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard pathIsEligible(resolved) else { return false }
        // Missing app-data paths are classified by their closest existing parent.
        // The scanner still skips missing paths rather than enumerating the parent.
        var existing = resolved
        let fm = FileManager.default
        while !fm.fileExists(atPath: existing.path) {
            // Foundation leaves dangling links unresolved. Never treat one as
            // an internal missing path: its destination may be an offline drive.
            if (try? fm.attributesOfItem(atPath: existing.path)[.type]) as? FileAttributeType == .typeSymbolicLink { return false }
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { return false }
            existing = parent
        }
        guard let volume = try? existing.resourceValues(forKeys: [.volumeURLKey]).volume else { return false }
        return approvedVolumes.contains(volume.standardizedFileURL.path)
    }

    /// Enumeration supplies real entries below a validated root and skips links.
    /// Check their volume without repeatedly resolving every ancestor path.
    static func allowsEnumeratedEntry(_ url: URL) -> Bool {
        guard url.isFileURL, pathIsEligible(url),
              let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else { return false }
        return approvedVolumes.contains(volume.standardizedFileURL.path)
    }

    private static func pathIsEligible(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let excluded = ["/Volumes", "/Network", "/System/Volumes/Data/Volumes", "/System/Volumes/Data/Network"]
        return !excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

/// Shared by discovery and deletion; never move a broad shared directory to Trash.
enum RemovalPolicy {
    static func contains(_ child: URL, in parent: URL) -> Bool {
        let c = child.standardizedFileURL.path
        let p = parent.standardizedFileURL.path
        return c == p || c.hasPrefix(p == "/" ? "/" : p + "/")
    }

    // RFO2 — Discovery hints are not a removal authorization. Reject broad shared roots,
    // self-removal and redirected ancestor paths again at the point of use.
    static func rejectionReason(for url: URL) -> String? {
        guard url.isFileURL else { return "Only local files can be removed." }
        guard InternalDrivePolicy.allows(url) else {
            return "Chuckit only works with apps and files on this Mac's internal startup drive. External drives and network volumes are excluded."
        }
        let path = url.standardizedFileURL.path
        guard !url.standardizedFileURL.pathComponents.contains(".Trash"), !url.standardizedFileURL.pathComponents.contains(".Trashes") else {
            return "This item is already in Trash and cannot be chucked again."
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let protected = ["/System", "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/private/etc", "/private/var/db"]
        for p in protected where path == p || path.hasPrefix(p + "/") || resolved == p || resolved.hasPrefix(p + "/") {
            return "macOS system files are protected and cannot be uninstalled."
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = ["/", "/Applications", "/Library", "/Users", "/Volumes", "/private", "/private/var", "/private/var/folders", "/usr", "/usr/local", "/opt", home]
        let drawers = ["Library", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Applications"]
        let shared = ["Application Support", "Preferences", "Caches", "Containers", "Group Containers", "LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools", "Logs", "HTTPStorages", "Cookies", "Saved Application State"]
        let forbidden = Set(roots + drawers.map { home + "/" + $0 } + shared.flatMap { [home + "/Library/" + $0, "/Library/" + $0] })
        guard !forbidden.contains(path), !forbidden.contains(resolved) else {
            return "A shared folder cannot be removed as an app's leftover."
        }
        let own = Bundle.main.bundleURL
        if own.pathExtension == "app", contains(url, in: own) || contains(own, in: url) {
            return "Chuckit cannot remove itself or its containing folder."
        }
        // An ancestor link could redirect a removal operation after review.
        if url.deletingLastPathComponent().standardizedFileURL.path != url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path {
            // /var and /tmp are standard macOS links; normalize those at discovery.
            return "This path passes through a symbolic link. Select its real location instead."
        }
        return nil
    }

    // RFO2 — This is a writability hint for the UI. The actual move and any required
    // authorization are decided by macOS or Finder, not by this Boolean.
    static func needsAdmin(_ url: URL) -> Bool {
        !FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }
}
