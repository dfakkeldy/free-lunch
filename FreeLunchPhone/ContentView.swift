// SPDX-License-Identifier: GPL-3.0-or-later
// The phone's root: three tabs — Timeline, Insights, Library — in that
// order, Timeline selected at launch. Timeline is the timeline stand-in,
// which owns the way into the plate screen (spec §2). Settings is a sheet
// behind each tab's gear, never a tab.
import SwiftUI

struct ContentView: View {
    /// The tabs, in the order the tab bar shows them.
    enum PhoneTab: Hashable {
        case timeline
        case insights
        case library
    }

    @State private var model = PhoneAppModel()
    @State private var selection: PhoneTab = .timeline

    var body: some View {
        TabView(selection: $selection) {
            Tab("Timeline", systemImage: "fork.knife", value: PhoneTab.timeline) {
                TimelineStubView(model: model)
            }
            Tab("Insights", systemImage: "chart.bar", value: PhoneTab.insights) {
                InsightsStubView()
            }
            Tab("Library", systemImage: "books.vertical", value: PhoneTab.library) {
                LibraryView()
            }
        }
    }
}
