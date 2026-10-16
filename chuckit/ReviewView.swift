// RFO2 — ReviewView.swift
// Keeps an editable copy of the scan results for the checkboxes.
// The user sees the candidate path, size and matching evidence before a
// snapshot of the selected rows is passed through the confirmation sheet.
// See DEVELOPMENT.md for the full workflow and file map.

// RFO2 — original design notes
//  Room two: the evidence board. This screen is the entire moral center
//  of chuckit — everything before it was investigation, everything after
//  it goes to Trash. So this screen has one job: make sure the user actually
//  sees what they're about to move to recoverable Trash.
//
//  That's why every row shows the what (filename), the where (which
//  drawer we found it in), and the how-much (size). And that's why every
//  row has a checkbox. Trust, but verify — then chuck.
//

import AppKit
import SwiftUI

/// Shows the case file and waits for the verdict. Nothing here deletes
/// anything — it just reports back which files the user kept checked.
struct ReviewView: View {
    let result: ScanResult
    /// Called with the checked files when the user pulls the trigger.
    var onChuck: ([RelatedFile]) -> Void
    var onBack: () -> Void

    @State private var files: [RelatedFile]
    @State private var pendingDeletion: DeletionSelection?
    @State private var showingFullDiskAccessSetup = false

    // RFO2 — Copy the candidate array into local State. Editing a checkbox should not
    // mutate the scan service or a result used by another screen.
    init(result: ScanResult, onChuck: @escaping ([RelatedFile]) -> Void, onBack: @escaping () -> Void) {
        self.result = result
        self.onChuck = onChuck
        self.onBack = onBack
        // Local mutable copy: the checkboxes live here, the original
        // case file stays pristine.
        _files = State(initialValue: result.files)
    }

    // RFO2 — Derive the selected rows and totals from one local array so the confirmation
    // count and submitted files agree with what the user currently sees.
    private var selected: [RelatedFile] { files.filter(\.isSelected) }
    private var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.sizeBytes } }

    var body: some View {
        VStack(spacing: 0) {
            // The suspect, front and center.
            HStack(spacing: 14) {
                Image(nsImage: BundleInspector.icon(for: result.target.url))
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.target.name)
                        .font(.title2).bold()
                    Text("\(files.count) related files found · \(ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.sizeBytes }, countStyle: .file))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("← Back") { onBack() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, ChuckSpace.l)
            .padding(.top, ChuckSpace.l)
            .padding(.bottom, ChuckSpace.m)

            if !result.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(result.warnings[0]).font(.caption).foregroundColor(.orange)
                    DisclosureGroup("Locations not searched") {
                        ForEach(Array(result.warnings.dropFirst()), id: \.self) { Text($0).font(.caption2).textSelection(.enabled) }
                    }
                    Button("Open Full Disk Access Settings") {
                        showingFullDiskAccessSetup = true
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(padding: ChuckSpace.s)
                .padding(.horizontal, ChuckSpace.l).padding(.bottom, ChuckSpace.s)
            }

            Text("Identifier matches are selected. Name matches and shared data need your review.")
                .font(.caption).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ChuckSpace.l)

            // Select all / none — because unchecking 47 boxes one by one
            // is how you get users to stop reading the list.
            HStack {
                Spacer()
                Button("Select all") { setAll(true) }
                    .buttonStyle(.link)
                Button("Select none") { setAll(false) }
                    .buttonStyle(.link)
            }
            .font(.caption)
            .padding(.horizontal, ChuckSpace.l)
            .padding(.vertical, ChuckSpace.xs)

            // The evidence board itself.
            List {
                ForEach($files) { $file in
                    // $file is the binding (for the checkbox); file is the
                    // plain value (for everything we just display).
                    let file = $file.wrappedValue
                    HStack(alignment: .center, spacing: ChuckSpace.s) {
                        Toggle("", isOn: $file.isSelected)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 24, height: 24)
                            .opacity(file.isSelected ? 1 : 0.45)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.displayName)
                                .font(.body)
                                // Unchecked files fade — the eye should go
                                // to what's about to die.
                                .opacity(file.isSelected ? 1 : 0.45)
                            Text(file.evidence).font(.caption2).foregroundColor(.secondary)
                            Text("\(file.locationDescription) · \(file.url.deletingLastPathComponent().path)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: ChuckSpace.s)
                        // The little lock warns: this one needs your
                        // admin password at chuck time.
                        if file.requiresAdmin {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .help("macOS may require authorization to move this item to Trash")
                        }
                        Text(file.formattedSize)
                            .font(.body.monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(minWidth: 72, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .hoverHighlight()
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Color.primary.opacity(0.08))
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .glassCard(padding: ChuckSpace.xs)
            .padding(.horizontal, ChuckSpace.l)

            // The trigger.
            HStack {
                Text("\(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file)) in \(selected.count) files")
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    guard !selected.isEmpty else { return }
                    pendingDeletion = DeletionSelection(files: selected)
                }) {
                    HStack(spacing: 0) {
                        Text("chuck").foregroundColor(.white)
                        Text("it").foregroundColor(.white.opacity(0.85))
                    }
                    .font(.headline)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .background(Color.red)
                .cornerRadius(999)
                .disabled(selected.isEmpty)
                .opacity(selected.isEmpty ? 0.4 : 1)
                // The button stays dead until at least one box is checked.
                // Chucking nothing should be impossible, not just pointless.
            }
            .padding(.horizontal, ChuckSpace.l)
            .padding(.vertical, ChuckSpace.m)
        }
        .sheet(isPresented: $showingFullDiskAccessSetup) {
            FullDiskAccessOnboarding { _ in showingFullDiskAccessSetup = false }
        }
        .sheet(item: $pendingDeletion) { selection in
            DeletionConfirmationSheet(
                appName: result.target.name,
                itemCount: selection.files.count,
                onCancel: { pendingDeletion = nil },
                onDelete: {
                    guard !selection.files.isEmpty else { return }
                    pendingDeletion = nil
                    onChuck(selection.files)
                }
            )
        }
    }

    private func setAll(_ value: Bool) {
        for i in files.indices { files[i].isSelected = value }
    }
}

private struct DeletionSelection: Identifiable {
    let id = UUID()
    let files: [RelatedFile]
}
