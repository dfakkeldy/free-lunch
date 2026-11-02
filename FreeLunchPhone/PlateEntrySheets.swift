// SPDX-License-Identifier: GPL-3.0-or-later
// The plate's entry sheets (spec §2): the quantity step after picking a
// food (add-then-weigh: type the scale reading or pick a serving), ad-hoc
// entry with optional "save as food", and editing an item's grams.
import FLCore
import FLPlate
import SwiftUI

struct QuantityStepSheet: View {
    @State var step: QuantityStep
    let onConfirm: (QuantityStep) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if !step.food.servings.isEmpty {
                    Picker("Amount", selection: $step.mode) {
                        Text(step.food.isLiquid ? "Millilitres" : "Grams").tag(QuantityStep.Mode.grams)
                        ForEach(step.food.servings, id: \.self) { serving in
                            Text("\(serving.name) (\(PlateFormat.decimal(serving.grams)) g)")
                                .tag(QuantityStep.Mode.serving(serving))
                        }
                    }
                }
                switch step.mode {
                case .grams:
                    TextField(step.food.isLiquid ? "Reading (ml)" : "Scale reading (g)", text: $step.gramsText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("quantity.grams")
                case .serving:
                    TextField("Servings", text: $step.servingCountText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("quantity.servings")
                }
                if let grams = step.resolvedGrams {
                    Text("\(PlateFormat.decimal(grams.value)) \(step.food.isLiquid ? "ml" : "g")")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(step.food.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onConfirm(step)
                        dismiss()
                    }
                    .disabled(step.resolvedGrams == nil)
                    .accessibilityIdentifier("quantity.add")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct AdHocEntrySheet: View {
    enum Mode: String, Identifiable {
        /// "New food": typed values saved as a custom food by default.
        case newFood
        /// "Ad-hoc entry": typed values on this plate only, unless saved.
        case adHoc

        var id: String { rawValue }
    }

    struct Entry {
        let name: String
        let grams: Grams
        let nutrition: NutritionValues
        let saveAsFood: Bool
    }

    let mode: Mode
    let onAdd: (Entry) -> Void

    @State private var name: String
    @State private var gramsText = "100"
    @State private var kcalText = ""
    @State private var proteinText = ""
    @State private var carbsText = ""
    @State private var fatText = ""
    @State private var saveAsFood: Bool
    @Environment(\.dismiss) private var dismiss

    init(mode: Mode, initialName: String, onAdd: @escaping (Entry) -> Void) {
        self.mode = mode
        self.onAdd = onAdd
        _name = State(initialValue: initialName.trimmingCharacters(in: .whitespacesAndNewlines))
        _saveAsFood = State(initialValue: mode == .newFood)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("adHoc.name")
                    TextField("Portion (g)", text: $gramsText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("adHoc.grams")
                }
                Section("For this portion") {
                    TextField("Energy (kcal)", text: $kcalText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("adHoc.kcal")
                    TextField("Protein (g)", text: $proteinText).keyboardType(.decimalPad)
                    TextField("Carbs (g)", text: $carbsText).keyboardType(.decimalPad)
                    TextField("Fat (g)", text: $fatText).keyboardType(.decimalPad)
                }
                // "New food" always saves a custom food; only an ad-hoc
                // entry offers the choice.
                if mode == .adHoc {
                    Section {
                        Toggle("Save as food", isOn: $saveAsFood)
                    }
                }
            }
            .navigationTitle(mode == .newFood ? "New food" : "Ad-hoc entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let entry {
                            onAdd(entry)
                            dismiss()
                        }
                    }
                    .disabled(entry == nil)
                    .accessibilityIdentifier("adHoc.add")
                }
            }
        }
    }

    /// Nil until the name, a positive portion and a kcal value are given.
    /// Empty macros count as zero; negative or non-numeric values refuse.
    private var entry: Entry? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let grams = PlateFormat.parsePositive(gramsText),
              let kcal = Self.nonNegative(kcalText, emptyIsZero: false),
              let protein = Self.nonNegative(proteinText, emptyIsZero: true),
              let carbs = Self.nonNegative(carbsText, emptyIsZero: true),
              let fat = Self.nonNegative(fatText, emptyIsZero: true)
        else { return nil }
        let nutrition = NutritionValues(
            kcal: Kilocalories(kcal),
            protein: Grams(protein),
            carbs: Grams(carbs),
            fat: Grams(fat)
        )
        return Entry(name: trimmed, grams: Grams(grams), nutrition: nutrition, saveAsFood: mode == .newFood || saveAsFood)
    }

    private static func nonNegative(_ text: String, emptyIsZero: Bool) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return emptyIsZero ? 0 : nil }
        if let positive = PlateFormat.parsePositive(trimmed) { return positive }
        return Double(trimmed.replacingOccurrences(of: ",", with: ".")) == 0 ? 0 : nil
    }
}

/// Editing an item's grams. The store rescales the snapshot; provenance and
/// any AI record link are untouched, so an AI item stays labelled.
struct EditQuantitySheet: View {
    let item: MealItemData
    let name: String
    let onSave: (Grams) -> Void

    @State private var gramsText: String
    @Environment(\.dismiss) private var dismiss

    init(item: MealItemData, name: String, onSave: @escaping (Grams) -> Void) {
        self.item = item
        self.name = name
        self.onSave = onSave
        _gramsText = State(initialValue: PlateFormat.decimal(item.quantityGrams))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Grams", text: $gramsText)
                    .keyboardType(.decimalPad)
                if let glyph = ProvenanceGlyph.forProvenance(item.provenance) {
                    Label(glyph.label, systemImage: glyph.symbolName)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let grams = PlateFormat.parsePositive(gramsText) {
                            onSave(Grams(grams))
                            dismiss()
                        }
                    }
                    .disabled(PlateFormat.parsePositive(gramsText) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
