// RFO2 — SearchingCan.swift
// Plays the numbered ChuckActivity image frames during work.
// Frame durations determine the pose from elapsed time, so an interrupted
// render does not need to advance a mutable frame counter.
// See DEVELOPMENT.md for the full workflow and file map.

import SwiftUI

/// Shared by searching and deletion; a fixed pose honors Reduce Motion.
struct ChuckItSearchingCan: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    // One full binocular sweep, eat from the right, sweep again, eat from
    // the left. The binoculars are put away during both eating phases.
    // RFO2 — The duration at index N belongs to ChuckActivityN in the app asset catalog.
    // Keep the frame count and order aligned when replacing the artwork.
    private let durations: [TimeInterval] = [
        0.40, 0.16, 0.22, 0.16, 0.40, 0.16, 0.22, 0.16,
        0.22, 0.32, 0.26,
        0.40, 0.16, 0.22, 0.16, 0.40, 0.16, 0.22, 0.16,
        0.22, 0.32, 0.26
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: reduceMotion)) { context in
            Image("ChuckActivity\(reduceMotion ? 2 : pose(at: context.date))")
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)
        }
        .accessibilityHidden(true)
    }

    // RFO2 — Wrap elapsed time by the complete cycle and locate its duration interval.
    // Reduce Motion uses a fixed pose and pauses the animation timeline.
    private func pose(at date: Date) -> Int {
        let cycle = durations.reduce(0, +)
        var position = max(0, date.timeIntervalSince(startedAt)).truncatingRemainder(dividingBy: cycle)
        for (index, duration) in durations.enumerated() {
            if position < duration { return index }
            position -= duration
        }
        return 0
    }
}
