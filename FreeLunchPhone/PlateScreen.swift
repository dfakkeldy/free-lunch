// SPDX-License-Identifier: GPL-3.0-or-later
// The plate screen (spec §2 "Plate screen"): the running plate total with
// its macro bar and today's remaining always visible, the item list with
// provenance glyphs, the typeahead add row, the optional hunger control and
// the single deliberate Log action.
//
// No AI capture button yet: the capture core has no live provider, so a
// camera button would lead nowhere. Barcode scanning is out of v1 (spec §2).
import FLCore
import FLPlate
import SwiftUI

struct PlateScreen: View {
    @Bindable var model: PhoneAppModel
    let mealID: UUID

    @State private var query = ""
    @State private var quantityStep: QuantityStep?
    @State private var adHocMode: AdHocEntrySheet.Mode?
    @State private var editingItem: MealItemData?
    @State private var scaleReading: ScaleReadingRequest?
    @State private var loggedAtSheet: LoggedAtSheet.Purpose?
    /// A time chosen in the Log-earlier sheet, logged once that sheet has
    /// gone, so the plate pops and the post-log sheet presents only after
    /// this screen's own sheet is dismissed.
    @State private var pendingLogAt: Date?

    var body: some View {
        if let meal = model.meal(id: mealID) {
            plate(meal)
        } else {
            ContentUnavailableView("Plate not found", systemImage: "fork.knife")
        }
    }

    private func plate(_ meal: MealEntryData) -> some View {
        let header = model.header(for: meal)
        return List {
            if let loggedAtText = model.loggedAtText(for: meal), let loggedAt = meal.loggedAt {
                Section("Logged") {
                    if model.canChangeLoggedAt(of: meal) {
                        Button {
                            loggedAtSheet = .move(current: loggedAt)
                        } label: {
                            LabeledContent("Eaten", value: loggedAtText)
                        }
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Logged time")
                        .accessibilityValue(loggedAtText)
                        .accessibilityHint("Change when this plate was eaten")
                        .accessibilityIdentifier("plate.loggedAt")
                    } else {
                        // An imported plate can't be edited; its time is
                        // shown, not offered as a control.
                        LabeledContent("Eaten", value: loggedAtText)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Logged time")
                            .accessibilityValue(loggedAtText)
                            .accessibilityIdentifier("plate.loggedAt")
                    }
                }
            }

            // After a time change: both days' totals as they now stand
            // (spec §2 acceptance #8). The day the plate left comes first.
            if let move = model.moveSummary(for: meal.id) {
                Section(move.title) {
                    if !move.isSameDay {
                        Text(move.previous.text)
                            .monospacedDigit()
                            .accessibilityIdentifier("plate.moved.previous")
                    }
                    Text(move.current.text)
                        .monospacedDigit()
                        .accessibilityIdentifier("plate.moved.current")
                }
            }

            Section("On the plate") {
                let rows = model.rows(for: meal)
                if rows.isEmpty {
                    Text("Nothing on the plate yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    Button {
                        editingItem = meal.items.first { $0.id == row.id }
                    } label: {
                        PlateItemRowView(row: row)
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        Button("Remove", role: .destructive) { model.removeItem(id: row.id) }
                    }
                }
            }

            ScaleSessionSection(
                session: model.scaleSession(for: meal.id),
                onStart: { model.startScaleSession($0, on: meal.id) },
                onEnd: { model.endScaleSession(on: meal.id) }
            )

            Section("Add") {
                TextField("Search foods", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("plate.search")
                ForEach(Array(model.typeaheadRows(query: query).enumerated()), id: \.offset) { _, row in
                    typeaheadButton(row)
                }
            }

            Section("Hunger before eating") {
                HungerControlView(selection: meal.hunger) { value in
                    model.tapHunger(value, on: meal)
                }
            }
        }
        .navigationTitle(meal.state == .draft ? "Plate" : "Logged plate")
        .navigationBarTitleDisplayMode(.inline)
        // Pinned above the list, not a list section, so the running total,
        // macro bar and remaining never scroll away (spec §2 "always visible").
        .safeAreaInset(edge: .top, spacing: 0) {
            PlateHeaderView(header: header)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
        }
        .safeAreaInset(edge: .bottom) {
            if meal.state == .draft {
                HStack(spacing: 12) {
                    // One tap logs at now: the unchanged default.
                    Button {
                        model.log(mealID: meal.id)
                    } label: {
                        // One line at every text size, so sharing the row
                        // with the clock button never makes the bar taller
                        // and hides more of the plate.
                        Text("Log plate")
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("plate.log")

                    // Late logging: pick an earlier date and time first.
                    Button {
                        loggedAtSheet = .log
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Log at an earlier time")
                    .accessibilityHint("Choose an earlier date and time before logging")
                    .accessibilityIdentifier("plate.logEarlier")
                }
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
        }
        .sheet(item: $loggedAtSheet, onDismiss: {
            guard let date = pendingLogAt else { return }
            pendingLogAt = nil
            model.log(mealID: meal.id, at: date)
        }) { purpose in
            LoggedAtSheet(purpose: purpose, model: model) { date in
                switch purpose {
                case .log: pendingLogAt = date
                case .move: model.moveLoggedMeal(meal.id, to: date)
                }
            }
        }
        .sheet(item: $quantityStep) { step in
            QuantityStepSheet(step: step) { confirmed in
                model.addCatalogItem(confirmed, to: meal.id)
                query = ""
            }
        }
        .sheet(item: $adHocMode) { mode in
            AdHocEntrySheet(mode: mode, initialName: query) { entry in
                model.addAdHocItem(
                    name: entry.name,
                    grams: entry.grams,
                    nutrition: entry.nutrition,
                    saveAsFood: entry.saveAsFood,
                    to: meal.id
                )
                query = ""
            }
        }
        .sheet(item: $scaleReading) { request in
            if let session = model.scaleSession(for: meal.id) {
                ScaleReadingSheet(request: request, session: session) { reading in
                    let refusal = model.addScaleReading(reading, foodID: request.foodID, to: meal.id)
                    if refusal == nil { query = "" }
                    return refusal
                }
            }
        }
        .sheet(item: $editingItem) { item in
            EditQuantitySheet(item: item, name: model.rows(for: meal).first { $0.id == item.id }?.name ?? "") { grams in
                model.setQuantity(grams, itemID: item.id)
            }
        }
    }

    @ViewBuilder
    private func typeaheadButton(_ row: TypeaheadRow) -> some View {
        switch row {
        case let .food(food, _, prefill):
            Button {
                let info = model.foodInfo(id: food.id) ?? PlateFoodInfo(name: food.name)
                // While a scale session runs, a food takes the next reading
                // (weigh-as-you-go); otherwise the quantity step
                // (add-then-weigh).
                if model.scaleSession(for: mealID) != nil {
                    scaleReading = ScaleReadingRequest(foodID: food.id, foodName: info.name)
                } else {
                    quantityStep = QuantityStep(foodID: food.id, food: info, prefillGrams: prefill)
                }
            } label: {
                HStack {
                    Text(food.name)
                    if let brand = food.brand {
                        Text(brand).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let prefill {
                        Text("\(PlateFormat.decimal(prefill)) g")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .foregroundStyle(.primary)
            .accessibilityIdentifier("plate.typeahead.food")
        case .tail(.newFood):
            Button("New food", systemImage: "plus.circle") { adHocMode = .newFood }
                .accessibilityIdentifier("plate.typeahead.newFood")
        case .tail(.adHocEntry):
            Button("Ad-hoc entry", systemImage: "square.and.pencil") { adHocMode = .adHoc }
                .accessibilityIdentifier("plate.typeahead.adHoc")
        }
    }
}

private struct PlateHeaderView: View {
    let header: PlateHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(header.plateTotalText)
                    .font(.title2.bold())
                    .monospacedDigit()
                    .accessibilityIdentifier("plate.total")
                Spacer()
                Text(header.plateMacrosText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            MacroBar(fractions: header.macroBar)
            Text(header.remainingText)
                .font(.headline)
                .accessibilityIdentifier("plate.remaining")
        }
        .padding(.vertical, 4)
    }
}

/// Protein, carbs and fat as shares of the plate's energy.
private struct MacroBar: View {
    let fractions: MacroBarFractions

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Rectangle().fill(.blue).frame(width: geometry.size.width * fractions.protein)
                Rectangle().fill(.orange).frame(width: geometry.size.width * fractions.carbs)
                Rectangle().fill(.pink).frame(width: geometry.size.width * fractions.fat)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 6)
        .background(Color.secondary.opacity(0.2))
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

private struct PlateItemRowView: View {
    let row: PlateItemRow

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                HStack(spacing: 6) {
                    Text(row.quantityText)
                    if let glyph = row.glyph {
                        Label(glyph.label, systemImage: glyph.symbolName)
                            .labelStyle(.titleAndIcon)
                            .accessibilityIdentifier("plate.item.provenance")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(row.kcalText)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// One optional 1–5 control. Untouched is unknown; tapping the chosen value
/// again clears it. Never a prompt (spec §2 "Hunger").
private struct HungerControlView: View {
    let selection: Int?
    let onTap: (Int) -> Void

    var body: some View {
        HStack {
            ForEach(HungerControl.values, id: \.self) { value in
                Button {
                    onTap(value)
                } label: {
                    Text("\(value)")
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(value == selection ? Color.accentColor : Color.secondary.opacity(0.15))
                        )
                        .foregroundStyle(value == selection ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hunger \(value) of 5")
                .accessibilityAddTraits(value == selection ? .isSelected : [])
            }
        }
    }
}
