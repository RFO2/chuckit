// RFO2 — FullDiskAccess.swift
// One-time Full Disk Access onboarding. Detection only probes files that are
// readable with Full Disk Access and silently denied without it, so checking
// never raises a macOS prompt. Only the user can grant access in Settings.

import AppKit
import Combine
import SwiftUI

enum FullDiskAccess {
    static let skippedKey = "fullDiskAccessOnboardingSkipped"
    /// Set when chuckit relaunched itself to pick up a fresh grant, so it never loops.
    static let relaunchedKey = "fullDiskAccessRelaunched"
    static let showNotification = Notification.Name("chuckitShowFullDiskAccess")
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// True when protected stores are readable. Uses open(), which fails quietly
    /// with EPERM when access is off; these locations never show a prompt.
    static var isGranted: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tcc = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        if let handle = FileHandle(forReadingAtPath: tcc) {
            try? handle.close()
            return true
        }
        let safari = home.appendingPathComponent("Library/Safari").path
        return (try? FileManager.default.contentsOfDirectory(atPath: safari)) != nil
    }

    /// Onboarding is due before a scan when access is off and the user hasn't chosen "Not now".
    static var needsOnboarding: Bool {
        !isGranted && !UserDefaults.standard.bool(forKey: skippedKey)
    }

    /// Record the scan mode: without access, prompt-prone folders are skipped.
    static func prepareScan() {
        UserDefaults.standard.set(!isGranted, forKey: PrivacyGuard.defaultsKey)
    }

    /// macOS often applies a new grant only to a fresh process.
    static func relaunch() {
        UserDefaults.standard.set(true, forKey: relaunchedKey)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// The one-time ask: why, one primary button, and a quiet way out.
struct FullDiskAccessOnboarding: View {
    /// Called with true when access is confirmed, false for "Not now".
    var onResolved: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var openedSettings = false
    @State private var granted = FullDiskAccess.isGranted
    @State private var lidOpen: Double = 0
    @State private var checkShown = false
    @State private var resolved = false
    @State private var relaunching = false
    /// After a self-relaunch that still found no access, offer help instead of relaunching again.
    @State private var alreadyRelaunched = UserDefaults.standard.bool(forKey: FullDiskAccess.relaunchedKey)
    private let poll = Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: ChuckSpace.l) {
            ZStack {
                ChuckCanFigure(width: 64, lidOpen: lidOpen)
                    .opacity(checkShown ? 0.25 : 1)
                if checkShown {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.green)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(height: 92)

            VStack(spacing: ChuckSpace.xs) {
                Text(checkShown ? "You're all set." : relaunching ? "Reopening chuckit…" : alreadyRelaunched ? "Still not switched on." : "Allow once. No more prompts.")
                    .font(.title2).bold()
                    .contentTransition(.opacity)
                Text(relaunching ? "macOS applies Full Disk Access when an app reopens. One moment." : alreadyRelaunched ? "chuckit reopened but macOS hasn't given it access yet. Make sure chuckit is switched on in the list, then come back here." : "Leftovers hide in protected places like other apps' containers and your Documents. Full Disk Access lets chuckit look there without macOS asking you to Allow each folder. It only reads; nothing moves until you review it.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if relaunching {
                ProgressView().controlSize(.small)
            } else if !checkShown {
                HStack(spacing: ChuckSpace.m) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 40, height: 40)
                        .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                        .help("Drag into the Full Disk Access list")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Turn on chuckit in the list.").font(.callout).bold()
                        Text("Not listed? Drag this icon into the list, or click +.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .glassCard(padding: ChuckSpace.s)
                .transition(.opacity)

                VStack(spacing: ChuckSpace.s) {
                    Button {
                        openedSettings = NSWorkspace.shared.open(FullDiskAccess.settingsURL)
                    } label: {
                        Text("Allow Everything").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)

                    if openedSettings {
                        // Switched on but still not detected: the grant applies after a relaunch.
                        Button("Already turned it on? Relaunch chuckit") { FullDiskAccess.relaunch() }
                            .buttonStyle(.link)
                            .font(.caption)
                            .transition(.opacity)
                    }
                    Button("Not now") {
                        UserDefaults.standard.set(true, forKey: FullDiskAccess.skippedKey)
                        UserDefaults.standard.set(false, forKey: FullDiskAccess.relaunchedKey)
                        finish(false)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .keyboardShortcut(.cancelAction)
                    Text("Without it, chuckit skips protected folders. Grant it later from the chuckit menu.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(ChuckSpace.l * 1.5)
        .frame(width: 440)
        .background(ChuckItPalette.surround)
        .animation(reduceMotion ? ChuckMotion.fade : ChuckMotion.screen, value: openedSettings)
        .onReceive(poll) { _ in recheck() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recheck()
            // Back from Settings and still not detected: the switch usually needs a fresh
            // process. Relaunch once, automatically, with a short note. Never loop.
            guard openedSettings, !resolved, !alreadyRelaunched, !FullDiskAccess.isGranted else { return }
            withAnimation(ChuckMotion.fade) { relaunching = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { FullDiskAccess.relaunch() }
        }
        .onAppear {
            if granted { celebrate() }
        }
    }

    private func recheck() {
        guard !resolved, FullDiskAccess.isGranted else { return }
        granted = true
        celebrate()
    }

    /// Lid pops, check springs in, then the sheet steps aside.
    private func celebrate() {
        guard !resolved else { return }
        resolved = true
        UserDefaults.standard.set(false, forKey: FullDiskAccess.skippedKey)
        UserDefaults.standard.set(false, forKey: FullDiskAccess.relaunchedKey)
        ChuckMotion.tap()
        if reduceMotion {
            withAnimation(ChuckMotion.fade) { checkShown = true }
        } else {
            withAnimation(ChuckMotion.lidOpen) { lidOpen = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(ChuckMotion.lidSnap) { lidOpen = 0; checkShown = true }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { onResolved(true) }
    }

    private func finish(_ value: Bool) {
        guard !resolved else { return }
        resolved = true
        onResolved(value)
    }
}
