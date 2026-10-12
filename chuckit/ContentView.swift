// RFO2 — ContentView.swift
// Owns the application workflow and screen transitions.
// Views communicate through callbacks; services perform inspection, scanning
// and Trash work. Phase keeps the state needed by the currently visible screen.
// See DEVELOPMENT.md for the full workflow and file map.

// RFO2 — original design notes
//  The hallway between the three rooms. chuckit is a tiny state machine:
//
//      drop → scanning → review → deleting → done
//                          ↘ (user goes back) drop
//
//  One enum, one switch. Every screen is dumb about the others — DropView
//  doesn't know ReviewView exists, and that's why this file is the only
//  place allowed to know the whole story.
//

import Combine
import SwiftUI

/// Where the user is in the story.
// RFO2 — Each phase carries only the data its screen needs. Returning to drop creates
// a new investigation; review selections belong to their own result snapshot.
private enum Phase {
    case drop
    case scanning(AppTarget)
    case review(ScanResult)
    case deleting(targetName: String, progress: DeleteProgressBridge)
    case done(targetName: String, trashed: Int, failed: [DeletionService.Failure], trashedBytes: Int64, notices: [String], restorable: [URL: URL])
}

/// A tiny bridge so the detached deletion engine can report progress.
/// @MainActor-isolated (and therefore Sendable): the engine can hold it
/// across isolation domains, and every `set` hops home to the UI thread.
@MainActor
final class DeleteProgressBridge: ObservableObject {
    @Published var value: Double = 0

    /// Called from the deletion engine (any thread). The @MainActor
    /// isolation hops it to the main thread, where the @Published
    /// property — and the UI — live.
    func set(_ newValue: Double) {
        value = newValue
    }
}

struct ContentView: View {
    @State private var phase: Phase = .drop
    @State private var invalidAppMessage: String?
    @State private var investigation: Task<Void, Never>?
    @StateObject private var scanner = RelatedFileScanner()

    var body: some View {
        Group {
            switch phase {
            case .drop:
                DropView { appURL, scope in
                    investigate(appURL, scope: scope)
                }

            case .scanning(let target):
                VStack {
                    ScanProgressView(target: target, scanner: scanner)
                    Button("Cancel scan") {
                        scanner.cancel()
                        investigation?.cancel()
                        phase = .drop
                    }.padding(.bottom, 20)
                }

            case .review(let result):
                ReviewView(
                    result: result,
                    onChuck: { selected in chuck(result: result, selected: selected) },
                    onBack: { phase = .drop }
                )

            case .deleting(let name, let bridge):
                DeleteProgressView(targetName: name, bridge: bridge)

            case .done(let name, let trashed, let failed, let movedBytes, let notices, let restorable):
                DoneView(
                    targetName: name,
                    trashedCount: trashed,
                    failed: failed,
                    trashedBytes: movedBytes,
                    notices: notices,
                    restorable: restorable,
                    onAgain: { phase = .drop }
                )
            }
        }
        .frame(minWidth: 520, minHeight: 640)
        .background(ChuckItPalette.surround)
        .preferredColorScheme(.light)
        .alert("Cannot uninstall this item", isPresented: Binding(get: { invalidAppMessage != nil }, set: { if !$0 { invalidAppMessage = nil } })) {
            Button("OK") { invalidAppMessage = nil }
        } message: { Text(invalidAppMessage ?? "") }
        // The wordmark rides in the title bar: black chuck, red it,
        // centered like a proper Mac app.
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChuckItWordmark(size: 15, weight: .bold)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarBackground(ChuckItPalette.titlebar, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        // Remove the system title item at the SwiftUI level so transitions
        // cannot restore a second label beside the custom wordmark.
        .toolbar(removing: .title)
    }

    // MARK: - The story beats

    /// An app was dropped. Identify the suspect, then start the scan.
    // RFO2 — Validate and inspect the bundle before starting asynchronous scanning.
    // Cancellation is checked before presenting a result. DropView admits one app per
    // drop and only exists in the drop phase, so investigations cannot overlap.
    private func investigate(_ appURL: URL, scope: ScanScope) {
        guard let target = BundleInspector.inspect(appURL: appURL) else {
            invalidAppMessage = RemovalPolicy.rejectionReason(for: appURL) ?? "Select a valid .app bundle with an executable or bundle identifier."
            return
        }
        phase = .scanning(target)
        investigation = Task { @MainActor in
            let result = await scanner.scan(target: target, scope: scope)
            guard !Task.isCancelled else { return }
            phase = .review(result)
        }
    }

    /// The user reviewed the evidence and pulled the trigger.
    /// We move to the deleting room first so there's a progress bar to
    /// watch — then the engine reports back when it's done.
    // RFO2 — The confirmed selection becomes the deletion service input. Report only the
    // bytes associated with confirmed Trash moves, never reclaimed disk capacity.
    private func chuck(result: ScanResult, selected: [RelatedFile]) {
        let name = result.target.name
        let bridge = DeleteProgressBridge()
        phase = .deleting(targetName: name, progress: bridge)
        Task {
            let outcome = await DeletionService.chuck(
                selected,
                target: result.target,
                progress: { value in
                    Task { await bridge.set(value) }
                },
                confirmForceQuit: { names in
                    // The app ignored a polite quit (often an unsaved-changes dialog).
                    let alert = NSAlert()
                    alert.messageText = "\(names.joined(separator: ", ")) is still running."
                    alert.informativeText = "It didn't quit within 10 seconds. Force quitting discards any unsaved changes."
                    alert.addButton(withTitle: "Force Quit")
                    alert.addButton(withTitle: "Cancel")
                    return alert.runModal() == .alertFirstButtonReturn
                }
            )
            // Report only confirmed moves. Trashed bytes have not been freed.
            let movedBytes = outcome.trashed.reduce(0) { $0 + $1.sizeBytes }
            await MainActor.run {
                phase = .done(
                    targetName: name,
                    trashed: outcome.trashed.count,
                    failed: outcome.failed,
                    trashedBytes: movedBytes,
                    notices: outcome.notices,
                    restorable: outcome.restorable
                )
            }
        }
    }
}

// MARK: - The scanning room

/// The in-between screen: the can, a progress bar, and an honest account
/// of which drawer we're currently opening. A frozen UI during a scan
/// feels broken; a narrated one feels fast.
private struct ScanProgressView: View {
    let target: AppTarget
    @ObservedObject var scanner: RelatedFileScanner

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ChuckItSearchingCan()
            Text("Investigating \(target.name)…")
                .font(.headline)
            ProgressView()
                .frame(width: 280)
            Text(scanner.statusMessage)
                .lineLimit(2).truncationMode(.middle)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(40)
    }
}

// MARK: - Moving to Trash

/// Items are moved to Trash while the user watches progress.
private struct DeleteProgressView: View {
    let targetName: String
    @ObservedObject var bridge: DeleteProgressBridge

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ChuckItSearchingCan()
            Text("Moving \(targetName) to Trash…")
                .font(.headline)
            ProgressView(value: bridge.value)
                .frame(width: 280)
            Text("macOS may ask for an administrator password.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(40)
    }
}

// MARK: - The aftermath

/// The deed is done. We report exactly what happened — how many files,
/// how much space, and anything that survived, WITH the reason. "Couldn't
/// delete" without a why is a shrug; a reason is accountability. Honesty
/// here is what earns the next launch.
// RFO2 — The final screen reports both successful moves and per-item failures.
// It is an operation receipt, not a claim that every possible leftover was found.
private struct DoneView: View {
    let targetName: String
    let trashedCount: Int
    let failed: [DeletionService.Failure]
    let trashedBytes: Int64
    let notices: [String]
    let restorable: [URL: URL]
    let onAgain: () -> Void
    @State private var showingPermissionHelp = false
    @State private var undoMessage: String?
    @State private var undoFailures: [(url: URL, reason: String)] = []

    private var needsPermissionHelp: Bool {
        failed.contains { $0.permissionHelp != nil }
    }
    private var needsFinderAuthorization: Bool {
        failed.contains { $0.permissionHelp == .finderAutomation }
    }
    private var hasBlockedApplication: Bool {
        failed.contains { $0.permissionHelp == .application }
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            if failed.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.green)
                Text("Selected items moved to Trash.")
                    .font(.title2).bold()
            } else {
                // Survivors means the headline can't claim total victory.
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.orange)
                Text("\(targetName) didn't go quietly.")
                    .font(.title2).bold()
            }
            Text("\(trashedCount) items moved to Trash · \(ByteCountFormatter.string(fromByteCount: trashedBytes, countStyle: .file)) in Trash")
                .foregroundColor(.secondary)
            Text("Open Trash in the Dock to recover items. Moving items to Trash does not free disk space.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if needsPermissionHelp {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Check removal permissions").font(.headline)
                    Text(needsFinderAuthorization ? "Allow Chuckit to control Finder so Finder can move your reviewed items to Trash and handle administrator prompts." : hasBlockedApplication ? "Removing apps may require App Management permission or an administrator. Full Disk Access alone does not resolve every restriction." : "macOS denied a move. Check file permissions and access to the selected app data.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Show Permission Instructions…") { showingPermissionHelp = true }
                        .buttonStyle(.borderedProminent).tint(.red)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
            }
            if !failed.isEmpty {
                // Every survivor gets named WITH its reason. No shrugs.
                ScrollView { VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn't move to Trash:")
                        .font(.caption).bold()
                    ForEach(failed, id: \.file.id) { failure in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("• \(failure.file.displayName)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(failure.file.url.path).font(.caption2).textSelection(.enabled)
                            Text(failure.reason)
                                .textSelection(.enabled)
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.8))
                            Button("Show item in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([failure.file.url])
                            }.buttonStyle(.link).font(.caption)
                        }
                    }
                }
                }.frame(maxHeight: 220).padding(.top, 8)
            }
            if !notices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(notices, id: \.self) { notice in
                        Text("• " + notice).font(.caption2).foregroundColor(.secondary).textSelection(.enabled)
                    }
                }
            }
            if let undoMessage {
                Text(undoMessage).font(.caption).foregroundColor(.secondary)
                ForEach(undoFailures, id: \.url) { failure in
                    Text("• \(failure.url.path): \(failure.reason)").font(.caption2).foregroundColor(.secondary).textSelection(.enabled)
                }
            } else if !restorable.isEmpty {
                // One-click undo for this chuck only; items go back to where they were.
                Button("Undo last chuck") {
                    let result = DeletionService.restore(restorable)
                    undoFailures = result.failed
                    undoMessage = "\(result.restored.count) of \(restorable.count) items restored to their original locations." + (result.failed.isEmpty ? "" : " These couldn't be restored:")
                }.buttonStyle(.link)
            }
            Button("Chuck another app", action: onAgain)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.top, 12)
            Spacer()
        }
        .padding(40)
        .sheet(isPresented: $showingPermissionHelp) {
            RemovalPermissionSetup(forApplication: hasBlockedApplication, forFinder: needsFinderAuthorization)
        }
    }
}
