// RFO2 — MatchEngine.swift
// Produces matching evidence without moving or deleting files.
// A candidate can be suggested without being checked. The scanner applies
// scope and selection rules after receiving this evidence.
// See DEVELOPMENT.md for the full workflow and file map.

import Foundation

enum MatchEngine {
    struct Evidence {
        let reason: String
        let selected: Bool
    }

    /// Extensions an app commonly appends to its own identifier ("com.foo.app.plist").
    static let knownIdentifierSuffixes: Set<String> = ["plist", "savedstate", "binarycookies", "helper", "lockfile", "lock",
        "log", "logs", "db", "sqlite", "sqlite-wal", "sqlite-shm", "wal", "shm", "json", "xml", "txt", "cache", "dat",
        "crash", "ips", "diag", "sfl2", "sfl3", "tmp", "bak", "backup", "list", "settings", "storedata", "cookies", "data"]

    // RFO2 — Accept the exact identifier, or the identifier followed only by known file
    // extensions. A dotted sibling product (com.foo.app.other) is not this app; embedded
    // helpers match only when the bundle lists them explicitly.
    static func identifierMatches(_ name: String, identifier: String) -> Bool {
        let name = name.lowercased(), id = identifier.lowercased()
        if name == id { return true }
        guard name.hasPrefix(id + ".") else { return false }
        let suffixes = name.dropFirst(id.count + 1).split(separator: ".", omittingEmptySubsequences: false)
        return !suffixes.isEmpty && suffixes.allSatisfy { knownIdentifierSuffixes.contains(String($0)) }
    }

    // RFO3 — Embedded helpers from shared frameworks (e.g. Sparkle's updater,
    // org.sparkle-project.*) appear inside many apps, so their files are not this
    // app's alone. Keep only helpers from the same vendor as the main app.
    static func ownedHelperIdentifiers(_ helpers: [String], mainIdentifier: String?) -> [String] {
        guard let main = mainIdentifier?.lowercased() else { return [] }
        let parts = main.split(separator: ".")
        guard parts.count >= 2 else { return helpers.filter { $0.lowercased().hasPrefix(main + ".") } }
        let vendor = parts.prefix(2).joined(separator: ".") + "."
        return helpers.filter { let h = $0.lowercased(); return h.hasPrefix(vendor) && !h.hasPrefix("com.apple.") }
    }

    static func matches(fileName: String, target: AppTarget) -> Bool {
        evidence(fileName: fileName, target: target) != nil
    }

    // RFO2 — Known app/helper IDs get strong evidence; app groups and name-only evidence
    // need review. The scanner can still leave a strong match unchecked by scope.
    static func evidence(fileName: String, target: AppTarget) -> Evidence? {
        let ids = [target.bundleIdentifier].compactMap { $0 } + target.helperBundleIdentifiers
        if ids.contains(where: { !$0.isEmpty && identifierMatches(fileName, identifier: $0) }) {
            return Evidence(reason: "Matches the app or embedded helper identifier", selected: true)
        }
        if target.groupIdentifiers.contains(fileName) {
            return Evidence(reason: "App group; other apps may share this data", selected: false)
        }
        for variant in target.nameVariants where variant.count >= 3 {
            if containsWord(haystack: fileName.lowercased(), needle: variant.lowercased()) {
                return Evidence(reason: "Name match only — review before selecting", selected: false)
            }
        }
        return nil
    }

    // RFO2 — Some launch services and UUID containers are identified by plist metadata
    // rather than a useful filename. Read these only after traversal policy checks.
    static func evidence(at url: URL, target: AppTarget) -> Evidence? {
        if let result = evidence(fileName: url.lastPathComponent, target: target) { return result }
        if ["Containers", "Group Containers"].contains(url.deletingLastPathComponent().lastPathComponent),
           let metadata = plist(at: url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")),
           let id = metadata["MCMMetadataIdentifier"] as? String,
           let result = evidence(fileName: id, target: target) {
            return result
        }
        // launchd labels and executables sometimes do not match the app filename.
        if url.pathExtension == "plist",
           ["LaunchAgents", "LaunchDaemons"].contains(url.deletingLastPathComponent().lastPathComponent),
           let dict = plist(at: url) {
            let program = dict["Program"] as? String ?? (dict["ProgramArguments"] as? [String])?.first
            if let program, RemovalPolicy.contains(URL(fileURLWithPath: program), in: target.url) {
                return Evidence(reason: "Launch service executes code inside this app", selected: true)
            }
            if let label = dict["Label"] as? String, let result = evidence(fileName: label, target: target) { return result }
        }
        return nil
    }

    // RFO2 — Limit metadata reads to one megabyte so a candidate plist cannot trigger
    // an unbounded read during a scan. Invalid or oversized metadata is ignored.
    private static func plist(at url: URL) -> [String: Any]? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue <= 1_048_576, let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    // RFO2 — Word boundaries prevent a short app name from matching inside another word.
    // Punctuation can separate names; letter and number neighbors cannot.
    private static func containsWord(haystack: String, needle: String) -> Bool {
        var start = haystack.startIndex
        while start < haystack.endIndex,
              let range = haystack.range(of: needle, range: start..<haystack.endIndex) {
            let before = range.lowerBound == haystack.startIndex || !haystack[haystack.index(before: range.lowerBound)].isLetter && !haystack[haystack.index(before: range.lowerBound)].isNumber
            let after = range.upperBound == haystack.endIndex || !haystack[range.upperBound].isLetter && !haystack[range.upperBound].isNumber
            if before && after { return true }
            start = range.upperBound
        }
        return false
    }
}
