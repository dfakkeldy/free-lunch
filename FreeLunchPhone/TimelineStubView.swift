// SPDX-License-Identifier: GPL-3.0-or-later
// Timeline feed and plate navigation.
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
                    // The plate keeps the whole screen, as before the tabs:
                    // no tab bar over its list.
                    PlateScreen(model: model, mealID: mealID)
                        .toolbarVisibility(.hidden, for: .tabBar)
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

    private var content: some View {
        ScrollViewReader { proxy in
            List {
                if model.nextDose != nil || !model.timeline.upcoming.isEmpty {
                    Section("Upcoming") {
                        if let status = model.nextDose {
                            NextDoseRow(status: status)
                        }
                        ForEach(model.timeline.upcoming) { item in
                            TimelineCard(model: model, item: item)
                        }
                    }
                    .accessibilityIdentifier("timeline.upcoming")
                }
                Section {
                    if model.timeline.today.items.isEmpty && model.meals.isEmpty {
                        EmptyTimelineView(model: model)
                    }
                    ForEach(model.timeline.today.items) { item in
                        TimelineCard(model: model, item: item)
                    }
                } header: {
                    TimelineDayHeader(model: model, day: model.timeline.today.day, isToday: true)
                        .id("timeline.today")
                }
                ForEach(model.timeline.past) { day in
                    Section {
                        ForEach(day.items) { item in
                            TimelineCard(model: model, item: item)
                        }
                    } header: {
                        TimelineDayHeader(model: model, day: day.day, isToday: false)
                    }
                }
            }
            .onChange(of: model.flow.postLog != nil) { _, shown in
                if shown {
                    DispatchQueue.main.async { proxy.scrollTo("timeline.today", anchor: .top) }
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

struct MealSummaryRow: View {
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
        let names = model.rows(for: meal).prefix(3).map(\.name)
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
