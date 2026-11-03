// SPDX-License-Identifier: GPL-3.0-or-later
// The Insights tab's stand-in until its cards are built (spec §7). Nothing
// is logged or composed here.
import SwiftUI

struct InsightsStubView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Insights are coming",
                systemImage: "chart.bar",
                description: Text("Trends and energy balance will show up here.")
            )
            .navigationTitle("Insights")
            .settingsGear()
        }
    }
}
