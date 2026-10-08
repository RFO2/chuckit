// RFO2 — BundleInspector.swift
// Reads bundle metadata and its local code signature.
// Inspection produces identity, embedded-helper and app-group metadata.
// The selected application is never launched just to identify it.
// See DEVELOPMENT.md for the full workflow and file map.

// RFO2 — original design notes
//  Step one of every investigation: identify the suspect. A Mac app is a
//  folder wearing a trench coat — inside is Info.plist, and inside that
//  are the fingerprints we need. This file lifts both of them without
//  ever launching the app (we don't wake suspects).
//

import AppKit
import Foundation
import Security

/// Reads an app bundle and produces the AppTarget the rest of the
/// investigation works from. Pure detective work: read, don't touch.
enum BundleInspector {

    /// Build an AppTarget from a dropped .app bundle. Returns nil when the
    /// URL isn't an app bundle at all — the drop zone already filters for
    /// .app, but we never trust the UI layer alone. Defense in depth.
    static func inspect(appURL: URL) -> AppTarget? {
        guard appURL.pathExtension.lowercased() == "app",
              RemovalPolicy.rejectionReason(for: appURL) == nil,
              let bundle = Bundle(url: appURL) else { return nil }
        // A bundle with neither an executable nor a bundle ID isn't an app.
        // Could be a framework or a plugin someone dragged in by accident —
        // we bail politely instead of investigating the wrong suspect.
        guard bundle.executableURL != nil || bundle.bundleIdentifier != nil else {
            return nil
        }

        // CFBundleName is the display name ("Spotify"). Fall back to the
        // folder name minus ".app" — it's usually right.
        let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        let name = bundleName ?? appURL.deletingPathExtension().lastPathComponent

        return AppTarget(
            url: appURL,
            name: name,
            bundleIdentifier: bundle.bundleIdentifier,
            teamIdentifier: teamIdentifier(for: appURL),
            groupIdentifiers: appGroups(for: appURL),
            helperBundleIdentifiers: helperIDs(in: appURL)
        )
    }

    // RFO2 — Application groups come from signed entitlements. They may be shared by
    // several apps, so finding a group is not exclusive ownership evidence.
    private static func appGroups(for url: URL) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    // RFO2 — Collect identifiers from embedded app and XPC bundles without executing them.
    // Do not follow symlinks or continue into a different volume.
    private static func helperIDs(in url: URL) -> [String] {
        guard let iterator = FileManager.default.enumerator(at: url,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .volumeURLKey], options: [.skipsHiddenFiles]) else { return [] }
        var ids = Set<String>()
        for case let item as URL in iterator {
            if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            guard InternalDrivePolicy.allowsEnumeratedEntry(item) else {
                iterator.skipDescendants()
                continue
            }
            if ["app", "xpc"].contains(item.pathExtension.lowercased()),
               let id = Bundle(url: item)?.bundleIdentifier, !id.hasPrefix("com.apple.") {
                ids.insert(id)
            }
        }
        return Array(ids)
    }

    /// Ask the Security framework who signed this app. This never touches
    /// the network and never launches anything — it just reads the code
    /// signature already stapled to the bundle. Ad-hoc signatures and
    /// unsigned apps return nil, and that's fine: the bundle ID alone
    /// still catches most of their droppings.
    // RFO2 — The signing team is metadata carried in AppTarget. The current MatchEngine
    // does not use a common team ID as sufficient evidence for removing a file.
    static func teamIdentifier(for appURL: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Is the suspect still alive? You can't fully delete a running app —
    /// it'll just respawn its helpers and re-create its caches. We check
    /// first so the UI can offer to quit it before the scan.
    static func isRunning(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleIdentifier
        }
    }

    /// Politely ask the running app to quit. We use terminate(), not
    /// forceTerminate() — a force-quit can corrupt the very preferences
    /// we're about to delete, and corrupt files sometimes fail to delete.
    /// Manners are a strategy here, not just politeness.
    static func quitIfRunning(bundleIdentifier: String?) {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return }
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == bundleIdentifier {
            app.terminate()
        }
    }

    /// The icon for the review screen, straight from the system. No
    /// asset catalog needed — the app brings its own face.
    static func icon(for appURL: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: appURL.path)
    }
}
