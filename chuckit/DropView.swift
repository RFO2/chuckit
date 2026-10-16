// RFO2 — DropView.swift
// Accepts an application through drag-and-drop or the browse panel.
// Both entry paths reach requestInvestigation. The wider-search choice is
// confirmed before the URL and scope are handed to ContentView.
// See DEVELOPMENT.md for the full workflow and file map.

// RFO2 — original design notes
//  Room one: the can. This is the whole pitch of the app in a single
//  screen — a bin, a dare, and a button. Drag any app onto the can and
//  the investigation begins.
//
//  The can art is the user's own image, added to the asset catalog as
//  "ChuckCan". If it's ever missing, the screen still works — the bin
//  is the soul of the app, but the drop zone is the body.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The front door. Handles the drop, validates it's actually an app,
/// and hands the URL up to ContentView, which runs the investigation.
struct DropView: View {
    /// Called with the dropped .app URL when everything checks out.
    var onAppDropped: (URL, ScanScope) -> Void

    @State private var isTargeted = false
    @State private var errorMessage: String?
    @State private var showingFullDiskAccessSetup = false
    @State private var showingOnboarding = false
    @State private var awaitingAccess: URL?
    @State private var expandedSearch = false
    @State private var pendingExpandedApp: URL?
    @State private var confirmingExpandedSearch = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lidOpen: Double = 0
    @State private var dropIcon: NSImage?
    @State private var iconFallen = false
    @State private var isChucking = false
    @AppStorage("hasSeenFullDiskAccessSetup") private var hasSeenFullDiskAccessSetup = false
    // RFO2 — Keep the dotted outline's top and side insets at 70% of its
    // bottom inset: 98 points above and beside it, and 140 points below it.
    private let bottomOutlineInset: CGFloat = 140
    private var topAndSideOutlineInset: CGFloat { bottomOutlineInset * 0.70 }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isTargeted ? Color(red: 1, green: 0.94, blue: 0.94) : ChuckItPalette.dropArea)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [10, 6]))
                    }
                    .animation(ChuckMotion.hover, value: isTargeted)

                VStack(spacing: 10) {
                    // Hover: the lid cracks open and the can leans toward the drag.
                    ChuckCanFigure(width: 120,
                                   lidOpen: lidOpen,
                                   tilt: (isTargeted && !reduceMotion && !isChucking) ? -4 : 0)
                        .scaleEffect(isTargeted && !reduceMotion ? 1.04 : 1.0)
                        .animation(ChuckMotion.hover, value: isTargeted)
                        .overlay(alignment: .top) {
                            if let dropIcon {
                                FlyingAppIcon(image: dropIcon)
                                    .scaleEffect(iconFallen ? 0.18 : 1)
                                    .offset(y: iconFallen ? 18 : -64)
                                    .opacity(iconFallen ? 0 : 1)
                            }
                        }
                        .onChange(of: isTargeted) { _, targeted in
                            guard !isChucking, !reduceMotion else { return }
                            withAnimation(ChuckMotion.hover) { lidOpen = targeted ? 0.35 : 0 }
                        }

                    // The wordmark, tucked right under the can like a logo
                    // lockup: one word, black chuck, red it. Always.
                    ChuckItWordmark(size: 30, weight: .black)

                    Text("Drag an app onto the can to find its related app data.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Toggle("Include personal folders on the internal drive", isOn: $expandedSearch)
                        .toggleStyle(.checkbox)
                        .font(.caption)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(28)
            }
            .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
            .padding(.horizontal, topAndSideOutlineInset)
            .padding(.top, topAndSideOutlineInset)
            .padding(.bottom, bottomOutlineInset)

            VStack(spacing: 14) {
                Button("Browse Applications…") { browse() }

                Button("Enable Full Disk Access…") {
                    showingFullDiskAccessSetup = true
                }
                Text("throw the baby out with the bath water")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingFullDiskAccessSetup) {
            FullDiskAccessOnboarding { _ in showingFullDiskAccessSetup = false }
        }
        // One-time ask before the first scan; the dropped app waits, untouched.
        .sheet(isPresented: $showingOnboarding, onDismiss: resumeAfterOnboarding) {
            FullDiskAccessOnboarding { _ in showingOnboarding = false }
        }
        .alert("Search personal folders on the internal drive?", isPresented: $confirmingExpandedSearch) {
            Button("Cancel", role: .cancel) { pendingExpandedApp = nil }
            Button("Set Up Full Disk Access…") {
                pendingExpandedApp = nil
                showingFullDiskAccessSetup = true
            }
            Button("Continue Wider Search") {
                guard let url = pendingExpandedApp else { return }
                pendingExpandedApp = nil
                onAppDropped(url, .expanded)
            }
        } message: {
            Text("This includes Desktop, Documents, Downloads and readable user folders on this Mac's internal startup drive only. External drives and network volumes are never searched. macOS may ask for access to protected locations. Enable Full Disk Access for this copy of Chuckit, then quit and reopen it before searching. Review every match and uncheck any personal files you want to keep.")
        }
        .task {
            let relaunched = UserDefaults.standard.bool(forKey: FullDiskAccess.relaunchedKey)
            if !hasSeenFullDiskAccessSetup || relaunched {
                hasSeenFullDiskAccessSetup = true
                if FullDiskAccess.isGranted {
                    UserDefaults.standard.set(false, forKey: FullDiskAccess.relaunchedKey)
                } else if FullDiskAccess.needsOnboarding {
                    showingOnboarding = true
                }
            }
        }
    }

    // MARK: - The drop

    /// A drop is just a promise of a file URL. We unwrap it, check it's
    /// really an app bundle, and either start the investigation or explain
    /// why not. Never silently ignore a drop — that's how users learn to
    /// distrust a drop zone.
    // RFO2 — Item providers load URLs asynchronously. Resolve an eligible alias before
    // handing the application to the workflow. One investigation at a time: a multi-item
    // drop is rejected outright, because letting several providers each start an
    // investigation lets a stale scan overwrite a newer review. The browse panel
    // already allows only a single selection.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        errorMessage = nil
        guard !providers.isEmpty, !isChucking else { return false }
        // One app at a time: load every dropped URL, then keep only the first
        // .app in drop order. Everything else in a multi-item drop is ignored.
        var urls = [URL?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                DispatchQueue.main.async {
                    urls[index] = url
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            // Resolve aliases first — a user might drop an alias from the Dock.
            let resolved = urls.compactMap { $0 }.map { (try? URL(resolvingAliasFileAt: $0)) ?? $0 }
            guard let app = resolved.first(where: { $0.pathExtension.lowercased() == "app" }) else {
                withAnimation(ChuckMotion.hover) { lidOpen = 0 }
                errorMessage = "That's not an app — drop a .app bundle."
                return
            }
            if providers.count > 1 {
                errorMessage = "One app at a time — only \(app.deletingPathExtension().lastPathComponent) was taken."
            }
            requestInvestigation(app, animated: true)
        }
        return true
    }

    /// Lid flips open, the icon drops in, the lid snaps shut, then the scan starts.
    private func playChuck(_ url: URL, then proceed: @escaping () -> Void) {
        ChuckMotion.tap()
        if reduceMotion {
            withAnimation(ChuckMotion.fade) { lidOpen = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: proceed)
            return
        }
        isChucking = true
        iconFallen = false
        dropIcon = NSWorkspace.shared.icon(forFile: url.path)
        withAnimation(ChuckMotion.lidOpen) { lidOpen = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            withAnimation(ChuckMotion.fall) { iconFallen = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) {
            withAnimation(ChuckMotion.lidSnap) { lidOpen = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { ChuckMotion.thunk() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.86) {
            dropIcon = nil
            isChucking = false
            proceed()
        }
    }

    /// The "I don't drag things" escape hatch. Opens /Applications in a
    /// panel that only allows app bundles — same validation as the drop,
    /// so both doors lead to the same room.
    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Investigate"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            requestInvestigation(url)
        }
    }

    private func resumeAfterOnboarding() {
        guard let url = awaitingAccess else { return }
        awaitingAccess = nil
        if !FullDiskAccess.needsOnboarding { requestInvestigation(url, animated: true) }
    }

    // RFO2 — Both input methods pass through the drive gate and scope decision.
    // The confirmation chooses a wider scan; it does not bypass the later file review.
    private func requestInvestigation(_ url: URL, animated: Bool = false) {
        guard InternalDrivePolicy.allows(url) else {
            withAnimation(ChuckMotion.hover) { lidOpen = 0 }
            errorMessage = "Choose an app on this Mac's internal startup drive. External drives and network volumes are excluded."
            return
        }
        if FullDiskAccess.needsOnboarding {
            withAnimation(ChuckMotion.hover) { lidOpen = 0 }
            awaitingAccess = url
            showingOnboarding = true
            return
        }
        if animated {
            playChuck(url) { requestInvestigation(url) }
            return
        }
        if expandedSearch {
            pendingExpandedApp = url
            confirmingExpandedSearch = true
        } else {
            onAppDropped(url, .appData)
        }
    }
}
