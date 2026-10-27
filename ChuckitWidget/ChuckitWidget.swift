// RFO2 — ChuckitWidget.swift
// RFO2 — A separate WidgetKit target displays its own mascot resource and opens the app.
// RFO2 — No file investigation or removal happens inside the widget extension.
// RFO2 — See DEVELOPMENT.md for target boundaries and URL routing.

import SwiftUI
import WidgetKit

struct ChuckitWidgetEntry: TimelineEntry {
    let date: Date
}

// RFO2 — the content is static. A never-refresh timeline avoids background
// RFO2 — refresh work for a widget whose only action is opening the application.
struct ChuckitWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ChuckitWidgetEntry { .init(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (ChuckitWidgetEntry) -> Void) {
        completion(.init(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ChuckitWidgetEntry>) -> Void) {
        completion(Timeline(entries: [.init(date: .now)], policy: .never))
    }
}

struct ChuckitWidgetView: View {
    var body: some View {
        Image("ChuckWidgetMascot")
            .resizable()
            .widgetAccentedRenderingMode(.fullColor)
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Open Chuckit")
            // RFO2 — macOS routes this URL using the main app's ChuckitInfo.plist.
            // RFO2 — ChuckItApp accepts the open route and activates its window.
            .widgetURL(URL(string: "chuckit://open"))
            .containerBackground(for: .widget) {
                Color(red: 0.90, green: 0.90, blue: 0.90)
            }
    }
}

@main
struct ChuckitDesktopWidget: Widget {
    let kind = "ChuckitDesktopWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ChuckitWidgetProvider()) { _ in
            ChuckitWidgetView()
        }
        .configurationDisplayName("Chuckit")
        .description("Open Chuckit to review an app and move selected leftovers to Trash.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
        .containerBackgroundRemovable(false)
    }
}
