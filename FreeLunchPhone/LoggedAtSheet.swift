// SPDX-License-Identifier: GPL-3.0-or-later
// Late logging (spec §2 "Log": `loggedAt` defaults to now and is editable).
// One sheet serves both moments: logging a draft at an earlier time, and
// changing when a logged plate was eaten. The picker stops at now (a plate
// is never logged in the future), a one-tap "Same time yesterday" covers
// the common case, and the footer says which day the choice counts toward
// before anything is committed.
import FLCore
import FLPlate
import SwiftUI

struct LoggedAtSheet: View {
    enum Purpose: Hashable, Identifiable {
        /// Log a draft at an earlier time.
        case log
        /// Change a logged plate's time.
        case move(current: Date)

        var id: Self { self }
    }

    let purpose: Purpose
    let model: PhoneAppModel
    let onCommit: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var now: Date
    @State private var selection: Date

    init(purpose: Purpose, model: PhoneAppModel, onCommit: @escaping (Date) -> Void) {
        self.purpose = purpose
        self.model = model
        self.onCommit = onCommit
        let now = Date()
        let current: Date? = if case let .move(date) = purpose { date } else { nil }
        _now = State(initialValue: now)
        _selection = State(initialValue: LateLogTime.initialSelection(current: current, now: now))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "Eaten at",
                        selection: $selection,
                        in: ...LoggedAtRule.latestAllowed(now: now),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .accessibilityIdentifier("loggedAt.picker")
                    .accessibilityHint("Choose when this plate was eaten. Times after now aren't available.")

                    Button("Same time yesterday", systemImage: "arrow.uturn.backward.circle") {
                        selection = model.sameTimeYesterday(now: now)
                    }
                    .accessibilityIdentifier("loggedAt.yesterday")
                    .accessibilityHint("Sets the time to this time yesterday")
                } footer: {
                    Text(model.loggedDay(for: selection, now: now).countsTowardText)
                        .accessibilityIdentifier("loggedAt.day")
                }
            }
            .navigationTitle(purpose == .log ? "Log earlier" : "Change time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("loggedAt.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(purpose == .log ? "Log" : "Save") {
                        onCommit(selection)
                        dismiss()
                    }
                    .accessibilityIdentifier("loggedAt.confirm")
                    .accessibilityLabel(purpose == .log ? "Log plate at this time" : "Save the new time")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
