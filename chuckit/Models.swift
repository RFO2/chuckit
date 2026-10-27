// RFO2 — Models.swift
// RFO2 — Shared data passed between the app screens and services.
// RFO2 — AppTarget describes the chosen bundle; RelatedFile records a candidate and
// RFO2 — its evidence; ScanResult holds the reviewable investigation result.
// RFO2 — See DEVELOPMENT.md for the full workflow and file map.

// RFO2 — original design notes
// RFO2 — Every uninstaller is really a detective story. An app gets dragged onto
// RFO2 — the can, and we have to answer three questions: who was this app, what
// RFO2 — did it leave behind, and what is safe to move to Trash?
//
// RFO2 — These three types are the entire vocabulary of that investigation:
// RFO2 — the suspect (AppTarget), the evidence (RelatedFile), and the closed
// RFO2 — case file (ScanResult). Everything else in the app just moves these
// RFO2 — three around.
//

import Foundation

/// RFO2 — The app the user wants gone. We never trust the folder name on the
/// RFO2 — .app bundle — names lie ("My Cool App.app" tells you nothing), but
/// RFO2 — bundle IDs don't. So we carry the human name for display and two
/// RFO2 — identity fields. Matching uses bundle/helper identifiers; the signing
/// RFO2 — team is recorded as metadata rather than an ownership decision.
// RFO2 — Identity is read from the selected bundle; display names are weaker evidence.
// RFO2 — Helper and group identifiers are explicit metadata rather than guessed company names.
struct AppTarget: Identifiable, Hashable {
    let id = UUID()
    /// RFO2 — Where the .app bundle lives (usually /Applications).
    let url: URL
    /// RFO2 — "Spotify" — for showing in the UI.
    let name: String
    /// RFO2 — "com.spotify.client" — the primary fingerprint. Most leftover
    /// RFO2 — files are named after this.
    let bundleIdentifier: String?
    /// RFO2 — The Apple Developer Team ID from the code signature. Helpers and
    /// RFO2 — updaters often don't share the bundle ID, but they almost always
    /// share the team that signed them. RFO2 — this metadata is recorded,
    /// RFO2 — but the current matcher does not select files on team identity alone.
    let teamIdentifier: String?

    var groupIdentifiers: [String] = []
    var helperBundleIdentifiers: [String] = []

    /// RFO2 — The names this app might have used while scattering files.
    /// RFO2 — the set removes identical strings. MatchEngine compares
    /// RFO2 — name evidence without case sensitivity when it evaluates candidates.
    var nameVariants: [String] {
        let variants = [name, url.deletingPathExtension().lastPathComponent]
        // RFO2 — Some apps file things under their company name too, but we
        // RFO2 — deliberately do NOT guess those — guessing is how you delete
        // RFO2 — the wrong thing. The match engine only uses what we know.
        return Array(Set(variants))
    }
}

/// RFO2 — One file or folder we believe belongs to the target app. Belief, not
/// RFO2 — certainty — that's why the review screen exists. Every RelatedFile
/// RFO2 — carries its evidence (where we found it, how big it is) so the user
/// RFO2 — can judge before anything is moved to Trash.
// RFO2 — Selection is mutable UI state, not proof of ownership.
// RFO2 — sizeBytes is the scan-time estimate; moving the item to Trash does not free it.
struct RelatedFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    /// RFO2 — "Preferences", "Application Support", "Caches"… — the human name
    /// RFO2 — of where we found it. The review screen reads like a story,
    /// RFO2 — not a path dump, because stories get read and path dumps get ignored.
    let locationDescription: String
    let sizeBytes: Int64
    /// RFO2 — discovery-time writability hint for the review UI. This does
    /// RFO2 — not establish that an administrator password will be needed; macOS
    /// RFO2 — and Finder decide what authorization the actual move requires.
    let requiresAdmin: Bool
    /// RFO2 — the scanner supplies the initial selection from evidence
    /// RFO2 — and scope. The user can change it before any move is attempted.
    var isSelected: Bool = true
    var evidence: String = "App-specific file"

    var displayName: String { url.lastPathComponent }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// RFO2 — the investigation result: the selected app, candidate files and
/// RFO2 — selected byte estimate. Moving to Trash does not reclaim this disk space.
// RFO2 — Totals summarize the currently selected rows.
// RFO2 — The selected application is identified by URL so it can be handled last.
struct ScanResult {
    let target: AppTarget
    let files: [RelatedFile]
    var warnings: [String] = []

    var selectedFiles: [RelatedFile] { files.filter(\.isSelected) }

    var totalSelectedBytes: Int64 {
        selectedFiles.reduce(0) { $0 + $1.sizeBytes }
    }

    var formattedTotalSelected: String {
        ByteCountFormatter.string(fromByteCount: totalSelectedBytes, countStyle: .file)
    }

    /// RFO2 — The .app bundle itself is always evidence item #1 — it's the body.
    /// RFO2 — Everything else is just where it hid the accomplices.
    var appFile: RelatedFile? {
        files.first { $0.url == target.url }
    }
}
