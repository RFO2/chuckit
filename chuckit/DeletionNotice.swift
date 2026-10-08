// RFO2 — DeletionNotice.swift
// Central wording for the review acknowledgment.
// Keeping this text in one place prevents the confirmation screen from
// drifting away from the actual recoverable Trash behavior.
// See DEVELOPMENT.md for the full workflow and file map.

import SwiftUI

enum DeletionNotice {
    static let instructions = "Review every selected file and folder before moving it to Trash. Uncheck personal information, documents, photos, shared data, and anything you want to keep. If you're unsure an item belongs to the app, leave it unchecked. Chuckit moves items to Trash; you can recover them while they remain there."
}
