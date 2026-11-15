// SPDX-License-Identifier: GPL-3.0-or-later
import FLCore
import SwiftUI
import WidgetKit

private let group = NextDoseComplicationConfiguration.appGroup
private let stateKey = NextDoseComplicationConfiguration.stateKey

struct DoseEntry: TimelineEntry {
    let date: Date
    let status: NextDoseStatus?
}

struct DoseProvider: TimelineProvider {
    func placeholder(in context: Context) -> DoseEntry { DoseEntry(date: .now, status: nil) }
    func getSnapshot(in context: Context, completion: @escaping (DoseEntry) -> Void) {
        completion(entries().first!)
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DoseEntry>) -> Void) {
        let values = entries()
        completion(Timeline(entries: values, policy: .after(values.last!.date.addingTimeInterval(60))))
    }
    private func entries() -> [DoseEntry] {
        let data = UserDefaults(suiteName: group)?.data(forKey: stateKey)
        let state = data.flatMap { try? JSONDecoder().decode(NextDoseComplicationState.self, from: $0) }
        return NextDoseTimeline.entries(dueAt: state?.nextDose?.nextDoseAt, now: .now, calendar: .current)
            .map { DoseEntry(date: $0.date, status: $0.status) }
    }
}

struct DoseView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DoseEntry
    var body: some View {
        Group {
            switch entry.status {
            case .upcoming(let due), .dueToday(let due):
                if family == .accessoryInline {
                    Text("Dose \(due, style: .relative)")
                } else {
                    VStack { Text("Next dose"); Text(due, style: .relative) }
                }
            case .overdue(_, let days):
                Text(NextDoseComplicationLabel.overdue(days: days))
            case nil:
                EmptyView()
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

@main
struct NextDoseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NextDoseComplicationConfiguration.kind, provider: DoseProvider()) { DoseView(entry: $0) }
            .configurationDisplayName("Next dose")
            .description("Shows when the next dose is due.")
            .supportedFamilies([.accessoryCorner, .accessoryInline, .accessoryCircular])
    }
}
