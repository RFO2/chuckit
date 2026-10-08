// RFO2 — Wordmark.swift
// Shared visual branding and palette for the app screens.
// The wordmark is composed from text, so it scales with the requested font
// size and keeps the chuck/it color treatment consistent.
// See DEVELOPMENT.md for the full workflow and file map.

import SwiftUI

enum ChuckItPalette {
    static let titlebar = Color(red: 0.84, green: 0.84, blue: 0.86)
    static let surround = Color(red: 0.94, green: 0.94, blue: 0.95)
    static let dropArea = Color.white
}

struct ChuckItWordmark: View {
    let size: CGFloat
    let weight: Font.Weight

    var body: some View {
        var word = AttributedString("chuckit")
        word.foregroundColor = .black
        if let range = word.range(of: "it") { word[range].foregroundColor = .red }
        return Text(word).font(.system(size: size, weight: weight, design: .rounded))
    }
}
