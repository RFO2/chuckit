// RFO2 — ChuckItApp.swift
// RFO2 — The SwiftUI application entry point.
// RFO2 — Creates the main window, sets its bundled icon and accepts the widget open URL.
// RFO2 — All investigation and removal coordination lives in ContentView.
// RFO2 — See DEVELOPMENT.md for the full workflow and file map.

// RFO2 — original design notes
// RFO2 — The front door. Not much lives here on purpose — the app is three
// RFO2 — rooms (drop, review, done) and this file just opens the building.
//

import AppKit
import SwiftUI

@main
struct ChuckItApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 520, minHeight: 640)
                .onAppear {
                    // RFO2 — Reassert the bundled icon when macOS retains an older Dock tile.
                    if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                       let icon = NSImage(contentsOf: iconURL) {
                        NSApplication.shared.applicationIconImage = icon
                    }
                }
                // RFO2 — The widget sends chuckit://open only to bring the app forward.
                // RFO2 — A deep link never selects files or triggers an uninstall.
                .onOpenURL { url in
                    guard url.scheme == "chuckit", url.host == "open" else { return }
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        // RFO2 — A standard window with its classic grey title bar — the retro
        // RFO2 — look the design calls for. (An early version hid the title bar
        // RFO2 — entirely; the grey chrome is friendlier and more Mac-like.)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Grant Full Disk Access…") {
                    NotificationCenter.default.post(name: FullDiskAccess.showNotification, object: nil)
                }
                LidSoundToggle()
            }
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified)
    }
}

/// RFO2 — App menu › Lid Sound. On by default; stored in UserDefaults.
private struct LidSoundToggle: View {
    @AppStorage(ChuckMotion.soundDefaultsKey) private var enabled = true
    var body: some View { Toggle("Lid Sound", isOn: $enabled) }
}
