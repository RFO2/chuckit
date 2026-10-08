// RFO2 — DeletionConfirmationSheet.swift
// Requires a fresh review acknowledgment for each removal attempt.
// The sheet sends a callback only after acknowledgment and a nonempty selection.
// It owns no filesystem operation and never stores consent as a preference.
// See DEVELOPMENT.md for the full workflow and file map.

import SwiftUI

struct DeletionConfirmationSheet: View {
    let appName: String
    let itemCount: Int
    var onCancel: () -> Void
    var onDelete: () -> Void
    // RFO2 — Use transient State and reset it on appearance. An acknowledgment from a
    // previous operation cannot authorize this selection.
    @State private var reviewedItems = false
    private var itemDescription: String { itemCount == 1 ? "item" : "items" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Review before moving to Trash", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold())

            Text("You're about to move \(itemCount) selected \(itemDescription) for \(appName) to Trash.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Text(DeletionNotice.instructions)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

            Toggle("I have reviewed every selected item and unchecked anything I want to keep.", isOn: $reviewedItems)
                .toggleStyle(.checkbox)
                .fixedSize(horizontal: false, vertical: true)

            Text("Items remain recoverable until Trash is emptied. Chuckit does not empty Trash.")
                .font(.callout.bold())

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                // RFO2 — Check the acknowledgment inside the action as well as disabling the button.
                // The callback is the boundary between reviewing and starting the Trash operation.
                Button("Move \(itemCount) \(itemDescription) to Trash", role: .destructive) {
                    guard reviewedItems, itemCount > 0 else { return }
                    onDelete()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!reviewedItems || itemCount == 0)
            }
        }
        .padding(26)
        .frame(width: 480)
        .background(ChuckItPalette.surround)
        .preferredColorScheme(.light)
        .onAppear { reviewedItems = false }
    }
}
