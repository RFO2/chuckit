// RFO2 — RemovalPolicy.swift
// RFO2 — Shared path and volume checks for discovery and removal.
// RFO2 — The same rules are rechecked when removal starts, because the filesystem
// RFO2 — may have changed since the review screen was shown.
// RFO2 — See DEVELOPMENT.md for the full workflow and file map.

import Foundation

/// RFO2 — Only the internal startup volume and its APFS Data volume are eligible.
/// RFO2 — Volume identity also rejects mounts placed inside an otherwise allowed folder.
enum InternalDrivePolicy {
    private static let startupPaths: Set<String> = ["/", "/System/Volumes/Data"]
    // RFO2 — Approve the startup volume and its APFS Data counterpart only when macOS
    // RFO2 — reports both internal storage and a local volume. A readable mount is not enough.
    private static let approvedVolumes: Set<String> = Set(startupPaths.filter { path in
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey]) else { return false }
        return values.volumeIsInternal == true && values.volumeIsLocal == true
    })

    // RFO2 — Check the supplied path and its resolved location. For missing candidates,
    // RFO2 — use the nearest existing parent only to classify the volume, not to scan it.
    static func allows(_ url: URL) -> Bool {
        guard url.isFileURL, pathIsEligible(url) else { return false }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard pathIsEligible(resolved) else { return false }
        // RFO2 — Missing app-data paths are classified by their closest existing parent.
        // RFO2 — The scanner still skips missing paths rather than enumerating the parent.
        var existing = resolved
        let fm = FileManager.default
        while !fm.fileExists(atPath: existing.path) {
            // RFO2 — Foundation leaves dangling links unresolved. Never treat one as
            // RFO2 — an internal missing path: its destination may be an offline drive.
            if (try? fm.attributesOfItem(atPath: existing.path)[.type]) as? FileAttributeType == .typeSymbolicLink { return false }
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { return false }
            existing = parent
        }
        guard let volume = try? existing.resourceValues(forKeys: [.volumeURLKey]).volume else { return false }
        return approvedVolumes.contains(volume.standardizedFileURL.path)
    }

    /// RFO2 — Enumeration supplies real entries below a validated root and skips links.
    /// RFO2 — Check their volume without repeatedly resolving every ancestor path.
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

/// RFO2 — Shared by discovery and deletion; never move a broad shared directory to Trash.
enum RemovalPolicy {
    static func contains(_ child: URL, in parent: URL) -> Bool {
        let c = child.standardizedFileURL.path
        let p = parent.standardizedFileURL.path
        return c == p || c.hasPrefix(p == "/" ? "/" : p + "/")
    }

    // RFO2 — Discovery hints are not a removal authorization. Reject broad shared roots,
    // RFO2 — self-removal and redirected ancestor paths again at the point of use.
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
        // RFO2 — RFO3 — Personal files, iCloud data, credentials and other users' homes are
        // RFO2 — never leftovers, and anything else must sit in a known app-data location.
        if let reason = ProtectedLocations.reason(for: url.standardizedFileURL) ?? ProtectedLocations.reason(for: url.resolvingSymlinksInPath().standardizedFileURL) {
            return reason
        }
        // RFO2 — An ancestor link could redirect a removal operation after review.
        // RFO2 — /var, /tmp and /etc are standard macOS links into /private; Foundation drops the
        // RFO2 — /private prefix inconsistently, so compare both sides without it.
        let parent = url.deletingLastPathComponent()
        if withoutPrivatePrefix(parent.standardizedFileURL.path) != withoutPrivatePrefix(parent.resolvingSymlinksInPath().standardizedFileURL.path) {
            return "This path passes through a symbolic link. Select its real location instead."
        }
        return nil
    }

    /// RFO2 — Maps /private/var, /private/tmp and /private/etc onto their standard /var, /tmp, /etc links.
    static func withoutPrivatePrefix(_ path: String) -> String {
        for link in ["/var", "/tmp", "/etc"] where path == "/private" + link || path.hasPrefix("/private" + link + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    // RFO2 — This is a writability hint for the UI. The actual move and any required
    // RFO2 — authorization are decided by macOS or Finder, not by this Boolean.
    static func needsAdmin(_ url: URL) -> Bool {
        !FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }
}

// RFO2 — RFO3 — File-safety rules shared by scanning and removal.
// RFO2 — Leftovers may only come from places where apps keep their own data. A user's
// RFO2 — documents, iCloud Drive, keychains, mail and other people's home folders are
// RFO2 — refused outright, even if a name looks like the app. A dropped .app bundle is
// RFO2 — the one thing allowed outside app-data folders (e.g. an app on the Desktop).
enum ProtectedLocations {
    /// RFO2 — Personal folders: only an .app bundle sitting there may be chucked.
    static let personalFolders = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public"]
    /// RFO2 — Never touched at all, including everything inside.
    static let sensitiveFolders = ["Library/Mobile Documents", "Library/CloudStorage", "Library/Keychains",
        "Library/Mail", "Library/Messages", "Library/Photos", "Library/Safari", "Library/Calendars",
        "Library/Reminders", "Library/Accounts", "Library/Cookies", "Library/HomeKit", "Library/Notes",
        "Library/Application Support/AddressBook", "Library/Application Support/MobileSync",
        "Library/Application Support/CallHistoryDB", "Library/Application Support/com.apple.TCC",
        "Library/Application Support/iCloud", "Library/Containers/com.apple.Notes",
        "Library/Group Containers/group.com.apple.notes",
        ".ssh", ".gnupg", ".aws", ".kube", ".docker", ".config", ".local", ".Trash"]
    /// RFO2 — Where an app's own leftovers can legitimately live.
    static func allowedRoots(home: String) -> [String] {
        ["/Applications", "/Library", "/Users/Shared", "/usr/local", "/opt", "/private/var/folders", "/var/folders",
         "/private/tmp", "/tmp", home + "/Library", home + "/Applications"]
    }

    static func reason(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let path = url.path
        let homePath = home.standardizedFileURL.path
        let isApp = url.pathExtension.lowercased() == "app"
        func under(_ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        for folder in sensitiveFolders where under(homePath + "/" + folder) {
            // RFO2 — ~/.config itself is protected; a single app's folder inside it may go.
            if folder == ".config" || folder == ".local", path != homePath + "/" + folder { continue }
            return "Personal data, iCloud and credential folders are protected. Chuckit never removes them."
        }
        for folder in personalFolders where under(homePath + "/" + folder) {
            if isApp && path != homePath + "/" + folder { return nil }
            return "Your personal files (Desktop, Documents, Downloads, Pictures, Movies, Music) are protected. Only an app itself can be chucked from there."
        }
        // RFO2 — Other people's home folders are off limits.
        for usersRoot in ["/Users", "/System/Volumes/Data/Users"] where path.hasPrefix(usersRoot + "/") {
            let owner = path.dropFirst(usersRoot.count + 1).split(separator: "/").first.map(String.init) ?? ""
            if owner != "Shared" && usersRoot + "/" + owner != homePath && !homePath.hasPrefix(usersRoot + "/" + owner + "/") && homePath != usersRoot + "/" + owner {
                return "Files in another person's home folder are protected."
            }
        }
        if isApp { return nil }
        // RFO2 — Apple's own data under a Library folder stays put.
        if path.contains("/Library/"), url.lastPathComponent.lowercased().hasPrefix("com.apple.") {
            return "Apple system data is protected."
        }
        // RFO2 — Hidden per-app folders directly in the home folder (~/.someapp) are allowed.
        if path.hasPrefix(homePath + "/.") {
            let first = path.dropFirst(homePath.count + 1).split(separator: "/").first.map(String.init) ?? ""
            if first.hasPrefix(".") && first.count > 1 { return nil }
        }
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().standardizedFileURL.path
        if (allowedRoots(home: homePath) + [temp]).contains(where: under) { return nil }
        return "Chuckit only removes leftovers from app-data folders such as ~/Library. This item is somewhere personal files may live, so it was left alone."
    }

    // RFO2 — RFO3 — Apple's own apps (and chuckit) are never chuckable.
    static func appRefusal(bundleIdentifier: String?, url: URL, ownBundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String? {
        let id = bundleIdentifier?.lowercased() ?? ""
        if id.hasPrefix("com.apple.") { return "This is an Apple app that is part of macOS. Chuckit leaves Apple's apps alone." }
        if let own = ownBundleIdentifier?.lowercased(), !own.isEmpty, id == own || id.hasPrefix(own + ".") {
            return "Chuckit can't chuck itself."
        }
        return nil
    }
}
