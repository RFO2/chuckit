// RFO2 — ChuckCanMotion.swift
// RFO2 — Motion for the ChuckCan artwork: a lid split from the same image, shared
// RFO2 — spring timings, the lid sound, haptics, dust puffs and the rolling total.
// RFO2 — Pure presentation. No colors, fonts or layout styling are introduced here.

import AppKit
import SwiftUI

/// RFO2 — One vocabulary of springs so every screen moves with the same physics.
enum ChuckMotion {
    static let lidOpen = Animation.spring(duration: 0.30, bounce: 0.18)
    static let lidSnap = Animation.spring(duration: 0.38, bounce: 0.42)
    static let hover = Animation.spring(duration: 0.34, bounce: 0.22)
    static let fall = Animation.spring(duration: 0.42, bounce: 0.0)
    static let screen = Animation.spring(duration: 0.42, bounce: 0.0)
    static let roll = Animation.spring(duration: 1.0, bounce: 0.0)
    static let fade = Animation.spring(duration: 0.25, bounce: 0.0)

    static let soundDefaultsKey = "lidSoundEnabled"

    /// RFO2 — A soft system thunk on lid close, quiet and optional.
    static func thunk() {
        let enabled = UserDefaults.standard.object(forKey: soundDefaultsKey) as? Bool ?? true
        guard enabled, let sound = NSSound(named: "Pop")?.copy() as? NSSound else { return }
        sound.volume = 0.22
        sound.play()
    }

    /// RFO2 — Trackpad tap where supported; silently nothing elsewhere.
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}

/// RFO2 — The ChuckCan image drawn as a body plus a hinged lid cut from the same art,
/// RFO2 — so it stays pixel-identical at rest. lidOpen 0...1, tilt in degrees.
struct ChuckCanFigure: View {
    var width: CGFloat
    var lidOpen: Double = 0
    var tilt: Double = 0

    /// RFO2 — Fraction of the artwork height occupied by the lid and rim.
    private let lidFraction: CGFloat = 0.345
    private var height: CGFloat { width * 534 / 400 }

    var body: some View {
        ZStack(alignment: .top) {
            art
                .mask(alignment: .bottom) {
                    Rectangle().frame(height: height * (1 - lidFraction) + 1)
                }
            art
                .mask(alignment: .top) {
                    Rectangle().frame(height: height * lidFraction)
                }
                // RFO2 — The shadow deepens as the lid lifts away from the rim.
                .shadow(color: .black.opacity(0.22 * lidOpen), radius: 6 * lidOpen, y: 3 * lidOpen)
                .rotationEffect(.degrees(-30 * lidOpen),
                                anchor: UnitPoint(x: 0.93, y: lidFraction))
                .offset(y: -4 * lidOpen)
        }
        .frame(width: width, height: height)
        .compositingGroup()
        .rotationEffect(.degrees(tilt), anchor: .bottom)
        .accessibilityHidden(true)
    }

    private var art: some View {
        Image("ChuckCan")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(width: width, height: height)
    }
}

/// RFO2 — A few soft puffs that drift up and out of the can's mouth, then vanish.
struct DustPuffs: View {
    var trigger: Int
    @State private var spread = false
    @State private var visible = false
    private let puffs: [(x: CGFloat, y: CGFloat, size: CGFloat)] = [
        (-26, -14, 10), (-12, -24, 8), (2, -28, 11), (16, -22, 8), (28, -12, 9)
    ]

    var body: some View {
        ZStack {
            ForEach(puffs.indices, id: \.self) { i in
                let p = puffs[i]
                Circle()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: p.size, height: p.size)
                    .blur(radius: spread ? 2.5 : 0.5)
                    .scaleEffect(spread ? 1.5 : 0.4)
                    .offset(x: spread ? p.x : p.x * 0.2, y: spread ? p.y : 0)
                    .opacity(visible ? (spread ? 0 : 1) : 0)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) {
            spread = false
            visible = true
            withAnimation(.spring(duration: 0.7, bounce: 0)) { spread = true }
        }
    }
}

/// RFO2 — The receipt line with its byte total rolling up instead of popping in.
struct RollingTrashSummary: View, Animatable {
    var count: Int
    var bytes: Double
    var animatableData: Double {
        get { bytes }
        set { bytes = newValue }
    }

    var body: some View {
        Text("\(count) items moved to Trash · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) in Trash")
    }
}

/// RFO2 — An app icon that floats over the can during a drop or an undo.
struct FlyingAppIcon: View {
    let image: NSImage
    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: 64, height: 64)
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
