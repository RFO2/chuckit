// RFO2 — ChuckGlass.swift
// Shared surface treatment: native material cards, a spacing scale and a
// quiet row hover. Presentation only; palette and fonts are unchanged.

import SwiftUI

/// One spacing scale for every screen.
enum ChuckSpace {
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let radius: CGFloat = 14
}

private struct GlassCard: ViewModifier {
    var padding: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ChuckSpace.radius, style: .continuous)
        content
            .padding(padding)
            .background(.regularMaterial, in: shape)
            .overlay { shape.strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.07), radius: 14, y: 5)
            .shadow(color: .black.opacity(0.04), radius: 1, y: 0.5)
    }
}

private struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.05 : 0))
                    .padding(.horizontal, -6)
            }
            .onHover { inside in
                withAnimation(reduceMotion ? nil : .spring(duration: 0.2, bounce: 0)) { hovering = inside }
            }
    }
}

extension View {
    /// Frosted native-material card with a hairline edge and soft ambient shadow.
    func glassCard(padding: CGFloat = ChuckSpace.m) -> some View { modifier(GlassCard(padding: padding)) }
    /// Subtle native-list hover wash.
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}

/// Hero freed-space figure that rolls up to its value.
struct RollingBytes: View, Animatable {
    var bytes: Double
    var animatableData: Double {
        get { bytes }
        set { bytes = newValue }
    }
    var body: some View {
        Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
            .font(.system(size: 44, weight: .bold).monospacedDigit())
            .contentTransition(.numericText())
    }
}
