// SPDX-License-Identifier: GPL-3.0-or-later
// The post-log surface (spec §2): one dismissible sheet, remaining today
// first, daily totals beneath, nothing chained after it. It lays out
// `PostLogSummary.sections` in the order the summary gives them, so the
// package's text snapshot of the summary is what this sheet shows.
import FLPlate
import SwiftUI

struct PostLogSheet: View {
    let summary: PostLogSummary
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(summary.sections) { section in
                    Section {
                        ForEach(Array(section.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(index == 0 ? .title3.bold() : .body)
                                .monospacedDigit()
                        }
                    } header: {
                        Text(section.title)
                            .accessibilityIdentifier("postLog.section.\(section.kind.rawValue)")
                    }
                }
            }
            .navigationTitle("Logged")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                        .accessibilityIdentifier("postLog.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
