// SPDX-License-Identifier: GPL-3.0-or-later
// A stand-in for the timeline: the entry point to the plate screen until
// the timeline section (spec §7) is frozen. It carries the primary Log
// action and the settings gear, lists drafts (visually pending, with the
// >24 h nudge) and today's logged plates, and hosts the post-log sheet so
// that dismissing the sheet lands here in one gesture (spec §2 acceptance
// #7).
import FLCore
import FLPlate
import SwiftUI

struct TimelineStubView: View {
    @Bindable var model: PhoneAppModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Today")
                .settingsGear()
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Log", systemImage: "plus") { model.startPlate() }
                            .accessibilityIdentifier("timeline.log")
                    }
                }
                .navigationDestination(item: openPlateBinding) { mealID in
                    PlateScreen(model: model, mealID: mealID)
                }
        }
        .sheet(isPresented: postLogBinding) {
            if let summary = model.flow.postLog {
                PostLogSheet(summary: summary) { model.dismissPostLog() }
            }
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.drafts.isEmpty && model.loggedTodayMeals.isEmpty {
            EmptyTimelineView(model: model)
        } else {
            List {
                if !model.drafts.isEmpty {
                    Section("Drafts") {
                        ForEach(model.drafts) { meal in
                            Button { model.open(meal) } label: {
                                MealSummaryRow(model: model, meal: meal)
                            }
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("timeline.draftRow")
                        }
                    }
                }
                if !model.loggedTodayMeals.isEmpty {
                    Section("Logged today") {
                        ForEach(model.loggedTodayMeals) { meal in
                            Button { model.open(meal) } label: {
                                MealSummaryRow(model: model, meal: meal)
                            }
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("timeline.loggedRow")
                        }
                    }
                }
            }
        }
    }

    private var openPlateBinding: Binding<UUID?> {
        Binding(
            get: { model.flow.openPlateID },
            set: { newValue in
                if newValue == nil { model.closePlate() }
            }
        )
    }

    private var postLogBinding: Binding<Bool> {
        Binding(
            get: { model.flow.postLog != nil },
            set: { isPresented in
                if !isPresented { model.dismissPostLog() }
            }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}

/// Shown when nothing is logged or drafted. The heading's identifier and
/// text are what the app-shell smoke test reads.
private struct EmptyTimelineView: View {
    let model: PhoneAppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "fork.knife")
                .font(.largeTitle)
                .accessibilityHidden(true)

            Text("Nothing logged yet")
                .font(.title3)
                .accessibilityIdentifier("phone.emptyState.heading")

            Text("Your plate will show up here.")
                .foregroundStyle(.secondary)

            Button("Start a plate") { model.startPlate() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct MealSummaryRow: View {
    let model: PhoneAppModel
    let meal: MealEntryData

    var body: some View {
        let header = model.header(for: meal)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(meal.state == .draft ? .secondary : .primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(header.plateTotalText)
                .monospacedDigit()
        }
    }

    private var title: String {
        let names = model.rows(for: meal).map(\.name)
        if names.isEmpty { return "Empty plate" }
        return names.joined(separator: ", ")
    }

    private var subtitle: String {
        switch meal.state {
        case .draft:
            let time = meal.createdAt.formatted(date: .omitted, time: .shortened)
            return model.isStale(meal) ? "Draft from \(meal.createdAt.formatted(date: .abbreviated, time: .shortened)) · still open" : "Draft · \(time)"
        case .logged:
            return (meal.loggedAt ?? meal.createdAt).formatted(date: .omitted, time: .shortened)
        }
    }
}
