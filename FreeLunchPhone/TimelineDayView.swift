// SPDX-License-Identifier: GPL-3.0-or-later
import FLCore
import FLPlate
import SwiftUI

struct TimelineDayHeader: View {
    let model: PhoneAppModel
    let day: Date
    let isToday: Bool

    var body: some View {
        HStack {
            Text(isToday ? "Today" : model.loggedDay(for: day, now: Date()).name)
                .accessibilityIdentifier(isToday ? "timeline.today.header" : "timeline.day.\(Int(day.timeIntervalSince1970))")
            if !isToday {
                let glyph = model.glyph(for: day)
                Image(systemName: glyph.symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(glyph.accessibilityLabel)
            }
            Spacer()
            Menu {
                Button(model.markedDays.contains(day) ? "Undo didn't track" : "Didn't track today") {
                    model.toggleDidNotTrack(day: day)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Day options")
        }
    }
}

struct NextDoseRow: View {
    let status: NextDoseStatus
    var body: some View {
        let due: Date = switch status {
        case .upcoming(let date), .dueToday(let date), .overdue(let date, _): date
        }
        VStack(alignment: .leading) {
            Text("Next dose")
            Text(due.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            if case .overdue = status { Text("Overdue").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct TimelineCard: View {
    let model: PhoneAppModel
    let item: TimelineItem
    var body: some View {
        switch item {
        case .meal(let meal):
            Button { model.open(meal) } label: { MealSummaryRow(model: model, meal: meal) }
                .foregroundStyle(.primary)
                .accessibilityIdentifier(meal.state == .draft ? "timeline.draftRow" : "timeline.loggedRow")
        case .shot(let shot):
            Label {
                VStack(alignment: .leading) {
                    Text("Shot · \(shot.doseMg.formatted()) mg")
                    if let site = shot.site { Text(site.rawValue).font(.caption).foregroundStyle(.secondary) }
                }
            } icon: { Image(systemName: "syringe") }
        case .weight(let weight):
            VStack(alignment: .leading) {
                Text("Weigh-in · \(weight.weightKg.formatted()) kg")
                if let trend = model.trendPoints.last(where: { $0.measuredAt == weight.measuredAt })?.trendKg {
                    Text("Trend · \(trend.formatted()) kg").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .sideEffect(let effect):
            VStack(alignment: .leading) {
                Text("Side effect · \(effectName(effect.type))")
                Text("Severity \(effect.severity)").font(.caption).foregroundStyle(.secondary)
                if let note = effect.note { Text(note) }
            }
        case .journal(let entry):
            Label(entry.text.isEmpty ? "Journal entry" : entry.text, systemImage: "book")
        case .plannedShot(let plan):
            Label("Planned shot\(plan.doseMg.map { " · \($0.formatted()) mg" } ?? "") · \(plan.plannedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar")
        case .plannedMeal(let plan):
            Label("\(plan.name) · \(plan.plannedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar")
        }
    }

    private func effectName(_ type: SideEffectType) -> String {
        switch type {
        case .nausea: "Nausea"
        case .vomiting: "Vomiting"
        case .constipation: "Constipation"
        case .diarrhea: "Diarrhea"
        case .fatigue: "Fatigue"
        case .appetiteLoss: "Appetite loss"
        case .injectionSite: "Injection site"
        case .other(let name): name
        }
    }
}
