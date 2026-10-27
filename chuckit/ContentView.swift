// RFO2 — ContentView.swift
// RFO2 — Owns the application workflow and screen transitions.
// RFO2 — Views communicate through callbacks; services perform inspection, scanning
// RFO2 — and Trash work. Phase keeps the state needed by the currently visible screen.
// RFO2 — See DEVELOPMENT.md for the full workflow and file map.

// RFO2 — original design notes
// RFO2 — The hallway between the three rooms. chuckit is a tiny state machine:
//
// RFO2 — drop → scanning → review → deleting → done
// RFO2 — ↘ (user goes back) drop
//
// RFO2 — One enum, one switch. Every screen is dumb about the others — DropView
// RFO2 — doesn't know ReviewView exists, and that's why this file is the only
// RFO2 — place allowed to know the whole story.
//

import Combine
import SwiftUI

/// RFO2 — Where the user is in the story.
// RFO2 — Each phase carries only the data its screen needs. Returning to drop creates
// RFO2 — a new investigation; review selections belong to their own result snapshot.
private enum Phase {
    case drop
    case scanning(AppTarget)
    case review(ScanResult)
    case deleting(targetName: String, progress: DeleteProgressBridge)
    case done(targetName: String, trashed: Int, failed: [DeletionService.Failure], trashedBytes: Int64, notices: [String], restorable: [URL: URL])
}

private extension Phase {
    /// RFO2 — Identity for screen transitions.
    var key: Int {
        switch self {
        case .drop: 0
        case .scanning: 1
        case .review: 2
        case .deleting: 3
        case .done: 4
        }
    }
}

/// RFO2 — A tiny bridge so the detached deletion engine can report progress.
/// @MainActor-isolated (and therefore Sendable): the engine can hold it
/// RFO2 — across isolation domains, and every `set` hops home to the UI thread.
@MainActor
final class DeleteProgressBridge: ObservableObject {
    @Published var value: Double = 0

    /// RFO2 — Called from the deletion engine (any thread). The @MainActor
    /// RFO2 — isolation hops it to the main thread, where the @Published
    /// RFO2 — property — and the UI — live.
    func set(_ newValue: Double) {
        value = newValue
    }
}

struct ContentView: View {
    @State private var phase: Phase = .drop
    @State private var invalidAppMessage: String?
    @State private var investigation: Task<Void, Never>?
    @State private var showingAccessFromMenu = false
    @StateObject private var scanner = RelatedFileScanner()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var screenTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985))
    }

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
        .transition(screenTransition)
        .animation(reduceMotion ? ChuckMotion.fade : ChuckMotion.screen, value: phase.key)
        .frame(minWidth: 520, minHeight: 640)
        .background(ChuckItPalette.surround)
        .preferredColorScheme(.light)
        .alert("Cannot uninstall this item", isPresented: Binding(get: { invalidAppMessage != nil }, set: { if !$0 { invalidAppMessage = nil } })) {
            Button("OK") { invalidAppMessage = nil }
        } message: { Text(invalidAppMessage ?? "") }
        // RFO2 — The wordmark rides in the title bar: black chuck, red it,
        // RFO2 — centered like a proper Mac app.
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChuckItWordmark(size: 15, weight: .bold)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarBackground(ChuckItPalette.titlebar, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        // RFO2 — Remove the system title item at the SwiftUI level so transitions
        // RFO2 — cannot restore a second label beside the custom wordmark.
        .toolbar(removing: .title)
        .sheet(isPresented: $showingAccessFromMenu) {
            FullDiskAccessOnboarding { _ in showingAccessFromMenu = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: FullDiskAccess.showNotification)) { _ in
            showingAccessFromMenu = true
        }
    }

    // MARK: - The story beats

    /// RFO2 — An app was dropped. Identify the suspect, then start the scan.
    // RFO2 — Validate and inspect the bundle before starting asynchronous scanning.
    // RFO2 — Cancellation is checked before presenting a result. DropView admits one app per
    // RFO2 — drop and only exists in the drop phase, so investigations cannot overlap.
    private func investigate(_ appURL: URL, scope: ScanScope) {
        guard let target = BundleInspector.inspect(appURL: appURL) else {
            invalidAppMessage = RemovalPolicy.rejectionReason(for: appURL)
                ?? Bundle(url: appURL).flatMap { ProtectedLocations.appRefusal(bundleIdentifier: $0.bundleIdentifier, url: appURL) }
                ?? "Select a valid .app bundle with an executable or bundle identifier."
            return
        }
        FullDiskAccess.prepareScan()
        let limited = PrivacyGuard.isActive
        phase = .scanning(target)
        investigation = Task { @MainActor in
            var result = await scanner.scan(target: target, scope: scope)
            if limited {
                result.warnings.insert("Full Disk Access is off, so protected folders were skipped. Choose Grant Full Disk Access… in the chuckit menu to search everywhere.", at: 0)
            }
            guard !Task.isCancelled else { return }
            phase = .review(result)
        }
    }

    /// RFO2 — The user reviewed the evidence and pulled the trigger.
    /// RFO2 — We move to the deleting room first so there's a progress bar to
    /// RFO2 — watch — then the engine reports back when it's done.
    // RFO2 — The confirmed selection becomes the deletion service input. Report only the
    // RFO2 — bytes associated with confirmed Trash moves, never reclaimed disk capacity.
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
                    // RFO2 — The app ignored a polite quit (often an unsaved-changes dialog).
                    let alert = NSAlert()
                    alert.messageText = "\(names.joined(separator: ", ")) is still running."
                    alert.informativeText = "It didn't quit within 10 seconds. Force quitting discards any unsaved changes."
                    alert.addButton(withTitle: "Force Quit")
                    alert.addButton(withTitle: "Cancel")
                    return alert.runModal() == .alertFirstButtonReturn
                }
            )
            // RFO2 — Report only confirmed moves. Trashed bytes have not been freed.
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

/// RFO2 — The in-between screen: the can, a progress bar, and an honest account
/// RFO2 — of which drawer we're currently opening. A frozen UI during a scan
/// RFO2 — feels broken; a narrated one feels fast.
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

/// RFO2 — Items are moved to Trash while the user watches progress.
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

/// RFO2 — The deed is done. We report exactly what happened — how many files,
/// RFO2 — how much space, and anything that survived, WITH the reason. "Couldn't
/// RFO2 — delete" without a why is a shrug; a reason is accountability. Honesty
/// RFO2 — here is what earns the next launch.
// RFO2 — The final screen reports both successful moves and per-item failures.
// RFO2 — It is an operation receipt, not a claim that every possible leftover was found.
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownBytes: Double = 0
    @State private var wobble = 0
    @State private var puff = 0
    @State private var lidOpen: Double = 0
    @State private var undoIcon: NSImage?
    @State private var iconOut = false

    /// RFO2 — The chucked app's Trash location, for the undo fly-out icon.
    private var trashedAppURL: URL? {
        restorable.first { $0.key.pathExtension.lowercased() == "app" }?.value
    }

    private var can: some View {
        ChuckCanFigure(width: 64, lidOpen: lidOpen)
            .keyframeAnimator(initialValue: 0.0, trigger: wobble) { content, angle in
                content.rotationEffect(.degrees(angle), anchor: .bottom)
            } keyframes: { _ in
                SpringKeyframe(-6, duration: 0.12, spring: .snappy)
                SpringKeyframe(4.5, duration: 0.14, spring: .snappy)
                SpringKeyframe(-2.5, duration: 0.14, spring: .snappy)
                SpringKeyframe(0, duration: 0.3, spring: .smooth)
            }
            .overlay(alignment: .top) { DustPuffs(trigger: puff).offset(y: 6) }
            .overlay(alignment: .top) {
                if let undoIcon {
                    FlyingAppIcon(image: undoIcon)
                        .scaleEffect(iconOut ? 0.75 : 0.2)
                        .offset(y: iconOut ? -58 : 14)
                        .opacity(iconOut ? 1 : 0)
                }
            }
            .padding(.top, 8)
    }

    /// RFO2 — Reverse of the drop: lid opens and the app flies back out.
    private func undo() {
        undoIcon = trashedAppURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        let result = DeletionService.restore(restorable)
        let finish = {
            undoFailures = result.failed
            undoMessage = "\(result.restored.count) of \(restorable.count) items restored to their original locations." + (result.failed.isEmpty ? "" : " These couldn't be restored:")
        }
        guard !reduceMotion else { withAnimation(ChuckMotion.fade, finish); undoIcon = nil; return }
        ChuckMotion.tap()
        withAnimation(ChuckMotion.lidOpen) { lidOpen = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(duration: 0.5, bounce: 0.28)) { iconOut = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(ChuckMotion.lidSnap) { lidOpen = 0 }
            ChuckMotion.thunk()
            withAnimation(ChuckMotion.screen, finish)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(ChuckMotion.fade) { iconOut = false }
        }
    }

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
        VStack(spacing: ChuckSpace.m) {
            Spacer()
            can
            // RFO2 — One hero: the size now sitting in Trash.
            VStack(spacing: 4) {
                RollingBytes(bytes: shownBytes)
                Text("in Trash")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: ChuckSpace.xs) {
                Image(systemName: failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(failed.isEmpty ? .green : .orange)
                Text(failed.isEmpty ? "Selected items moved to Trash." : "\(targetName) didn't go quietly.")
                    .bold()
            }
            .font(.title3)
            VStack(spacing: 4) {
                Text("\(trashedCount) items moved to Trash")
                Text("Open Trash in the Dock to recover items. Moving items to Trash does not free disk space.")
                    .multilineTextAlignment(.center)
            }
            .font(.caption)
            .foregroundColor(.secondary)
            if needsPermissionHelp {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Check removal permissions").font(.headline)
                    Text(needsFinderAuthorization ? "Allow Chuckit to control Finder so Finder can move your reviewed items to Trash and handle administrator prompts." : hasBlockedApplication ? "Removing apps may require App Management permission or an administrator. Full Disk Access alone does not resolve every restriction." : "macOS denied a move. Check file permissions and access to the selected app data.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Show Permission Instructions…") { showingPermissionHelp = true }
                        .buttonStyle(.borderedProminent).tint(.red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()
            }
            if !failed.isEmpty {
                // RFO2 — Every survivor gets named WITH its reason. No shrugs.
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
                .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 220).glassCard(padding: ChuckSpace.s)
            }
            if !notices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(notices, id: \.self) { notice in
                        Text("• " + notice).font(.caption2).foregroundColor(.secondary).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(padding: ChuckSpace.s)
            }
            if let undoMessage {
                Text(undoMessage).font(.caption).foregroundColor(.secondary)
                ForEach(undoFailures, id: \.url) { failure in
                    Text("• \(failure.url.path): \(failure.reason)").font(.caption2).foregroundColor(.secondary).textSelection(.enabled)
                }
            } else if !restorable.isEmpty {
                // RFO2 — One-click undo for this chuck only; items go back to where they were.
                Button("Undo last chuck", action: undo).buttonStyle(.link)
            }
            Button("Chuck another app", action: onAgain)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.top, ChuckSpace.s)
            Spacer()
        }
        .padding(.horizontal, ChuckSpace.l * 1.5)
        .padding(.vertical, ChuckSpace.l)
        .onAppear {
            guard !reduceMotion else { shownBytes = Double(trashedBytes); return }
            withAnimation(ChuckMotion.roll.delay(0.15)) { shownBytes = Double(trashedBytes) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard trashedCount > 0 else { return }
                wobble += 1
                puff += 1
            }
        }
        .sheet(isPresented: $showingPermissionHelp) {
            RemovalPermissionSetup(forApplication: hasBlockedApplication, forFinder: needsFinderAuthorization)
        }
    }
}
