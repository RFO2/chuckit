// RFO2 — FullDiskAccessSetup.swift
// RFO2 — Explains macOS access and removal permissions to the user.
// RFO2 — These views open settings or provide instructions; they do not grant access
// RFO2 — or collect an administrator password on behalf of the operating system.
// RFO2 — See DEVELOPMENT.md for the full workflow and file map.

import AppKit
import SwiftUI

/// RFO2 — Explain the permission before opening Settings. Only the user can enable it.
// RFO2 — Show the actual running app location so the user can choose the right copy
// RFO2 — in Settings when several development builds exist.
struct FullDiskAccessSetup: View {
    var retryAppName: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var openedSettings = false
    @State private var settingsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ChuckItWordmark(size: 24, weight: .bold)
            Text(retryAppName == nil ? "Find the leftovers, too." : "macOS blocked access.")
                .font(.title2).bold()
            Text(retryAppName == nil
                 ? "Full Disk Access lets Chuckit search protected app data for leftover files. Want to open Settings to enable it?"
                 : "Chuckit couldn't remove some protected app data. Check Full Disk Access in Settings, then try again.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                step("1", "Click Open Settings below to go to Full Disk Access.")
                step("2", "Turn on Chuckit. If it isn't listed, click + and add this copy of Chuckit.")
                step("3", "Approve any macOS prompt. Quit and reopen Chuckit, then scan the app again.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()

            Button("Show this app in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            }
            .buttonStyle(.link)
            Text(retryAppName == nil
                 ? "You can skip this and enable it later. Some protected files may be missed."
                 : "If Chuckit is already on but access is still blocked, remove its entry and use + to add this copy again.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settingsError {
                Text("Open System Settings → Privacy & Security → Full Disk Access.")
                    .font(.caption).foregroundColor(.red)
            }
            HStack {
                Button(openedSettings ? "Close Instructions" : "Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(openedSettings ? "Open Settings Again" : "Open Settings") {
                    let destination = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                    openedSettings = NSWorkspace.shared.open(destination)
                    settingsError = !openedSettings
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 460)
        .background(ChuckItPalette.surround)
    }

    private func step(_ number: String, _ instruction: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.body.bold()).foregroundColor(.red)
                .frame(width: 16)
            Text(instruction).fixedSize(horizontal: false, vertical: true)
        }
    }
}


/// RFO2 — A failed Trash operation does not reveal which privacy switch is disabled.
// RFO2 — Access to read app data and permission to move an application are different
// RFO2 — decisions. The instructions distinguish app management from Finder automation.
struct RemovalPermissionSetup: View {
    let forApplication: Bool
    var forFinder = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ChuckItWordmark(size: 24, weight: .bold)
            Text("Check removal permissions").font(.title2).bold()
            Text("Full Disk Access can be on while macOS still blocks a move to Trash.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                if forFinder {
                    Text("1. Open System Settings → Privacy & Security → Automation. Expand Chuckit and enable Finder.")
                    Text("2. Finder can then move only the items you selected and reviewed in Chuckit to Trash. If macOS needs an administrator password, enter it directly in the macOS prompt.")
                } else if forApplication {
                    Text("1. Open System Settings → Privacy & Security → App Management. Add this copy of Chuckit with + and enable it.")
                    Text("2. If the app belongs to another Mac user or requires an administrator, use Show item in Finder on the results screen. Move it to Trash in Finder and approve the administrator prompt yourself.")
                } else {
                    Text("1. Check System Settings → Privacy & Security → Full Disk Access for this copy of Chuckit.")
                    Text("2. A locked item or an item owned by another user can also be blocked. Use Show item in Finder to inspect it.")
                }
                Text("3. Quit and reopen Chuckit after changing a permission, then scan again. Protected macOS system files cannot be removed.")
            }
            .fixedSize(horizontal: false, vertical: true)
            .glassCard()
            Button("Show this copy of Chuckit in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            }.buttonStyle(.link)
            Text("If you rebuilt or replaced a local test build after granting access, the old grant may no longer match. Add the current copy again. Current app: " + Bundle.main.bundleURL.path)
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 480).background(ChuckItPalette.surround)
    }
}
