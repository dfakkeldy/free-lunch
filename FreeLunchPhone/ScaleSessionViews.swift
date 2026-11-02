// SPDX-License-Identifier: GPL-3.0-or-later
// Weigh-as-you-go (spec §2 "Weighing flows"): the plate's scale-session
// controls and the reading sheet a food tap opens while a session runs.
// Tared: tare before each item and enter the reading. Cumulative: never
// tare; each item is the increase since the last reading. A refused
// reading keeps the sheet open, says why and asks again.
import FLCore
import FLPlate
import SwiftUI

/// The plate's "Weigh as you go" section: start either kind of session, or
/// see the running one and end it.
struct ScaleSessionSection: View {
    let session: PlateScaleSession?
    let onStart: (ScaleSessionMode) -> Void
    let onEnd: () -> Void

    var body: some View {
        Section {
            if let session {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        "\(ScaleSessionText.modeName(session.mode)) scale session",
                        systemImage: "scalemass"
                    )
                    .font(.headline)
                    Text(ScaleSessionText.status(session))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("plate.scale.status")
                }
                Button("End scale session", systemImage: "stop.circle") { onEnd() }
                    .accessibilityLabel("End scale session")
                    .accessibilityHint("Foods you pick go back to the quantity step.")
                    .accessibilityIdentifier("plate.scale.end")
            } else {
                startButton(.tared, identifier: "plate.scale.startTared")
                startButton(.cumulative, identifier: "plate.scale.startCumulative")
            }
        } header: {
            Text("Weigh as you go")
        } footer: {
            if session != nil {
                Text("Pick each food below as it goes on the scale.")
            }
        }
    }

    private func startButton(_ mode: ScaleSessionMode, identifier: String) -> some View {
        Button {
            onStart(mode)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Start \(ScaleSessionText.modeName(mode).lowercased()) session")
                Text(ScaleSessionText.modeExplanation(mode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityLabel("Start \(ScaleSessionText.modeName(mode).lowercased()) scale session")
        .accessibilityHint(ScaleSessionText.modeExplanation(mode))
        .accessibilityIdentifier(identifier)
    }
}

/// The food a reading is for, carried into the sheet.
struct ScaleReadingRequest: Identifiable, Hashable {
    let foodID: UUID
    let foodName: String

    var id: UUID { foodID }
}

/// One scale reading for one food. `onAdd` returns nil once the item is on
/// the plate, or the prompt to show when the reading is refused.
struct ScaleReadingSheet: View {
    let request: ScaleReadingRequest
    let session: PlateScaleSession
    let onAdd: (Double) -> String?

    @State private var readingText = ""
    @State private var prompt: String?
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // The label sits above the field, not beside it, so at
                    // the largest text sizes it wraps instead of truncating
                    // and the field keeps the full row width.
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ScaleSessionText.readingFieldLabel(session.mode))
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityHidden(true)
                        TextField("0", text: $readingText)
                            .keyboardType(.decimalPad)
                            .font(.title2.monospacedDigit())
                            .focused($fieldFocused)
                            .accessibilityLabel(ScaleSessionText.readingFieldLabel(session.mode))
                            .accessibilityIdentifier("scale.reading")
                    }
                    if let preview {
                        Text(preview)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("scale.preview")
                    }
                } footer: {
                    Text(ScaleSessionText.status(session))
                }

                if let prompt {
                    Section {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .accessibilityHidden(true)
                            Text(prompt)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("scale.prompt")
                        }
                        .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(request.foodName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("scale.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(reading == nil)
                        .accessibilityLabel("Add \(request.foodName) from this reading")
                        .accessibilityIdentifier("scale.add")
                }
            }
            .onAppear { fieldFocused = true }
            // The prompt answers the refused reading; once a new one is
            // being typed it no longer applies.
            .onChange(of: readingText) { _, text in
                if !text.isEmpty { prompt = nil }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var reading: Double? {
        PlateFormat.parsePositive(readingText)
    }

    /// "Adds 162.5 g" while the typed reading would be accepted.
    private var preview: String? {
        guard let reading, let grams = try? session.grams(forReading: reading) else { return nil }
        return ScaleSessionText.preview(grams)
    }

    private func add() {
        guard let reading else { return }
        if let refusal = onAdd(reading) {
            // Ask again: clear the field and keep the sheet open.
            prompt = refusal
            readingText = ""
            fieldFocused = true
            AccessibilityNotification.Announcement(refusal).post()
        } else {
            dismiss()
        }
    }
}
