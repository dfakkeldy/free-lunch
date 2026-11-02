// SPDX-License-Identifier: GPL-3.0-or-later
// Presentation values for the plate screen (spec §2 "Plate screen",
// "Hunger", "Typeahead"): item rows with provenance glyphs, the running
// plate total and macro bar, today's remaining against the adopted target,
// the quantity step and the hunger control.
//
// Everything here is pure and locale-independent so the SwiftUI layer only
// lays out strings and fractions it is handed, and tests can predict every
// character. FLPlate cannot see FLEnergyCore, so the adopted target arrives
// as plain numbers (`DailyTarget`); the app maps the energy core's macro
// breakdown into it.
import FLCore
import Foundation

// MARK: - Amounts and targets

/// kcal and the three macros, in canonical units. Used for totals, targets
/// and what remains.
public struct MacroAmounts: Sendable, Hashable {
    public let kcal: Double
    public let proteinG: Double
    public let carbsG: Double
    public let fatG: Double

    public static let zero = MacroAmounts(kcal: 0, proteinG: 0, carbsG: 0, fatG: 0)

    public init(kcal: Double, proteinG: Double, carbsG: Double, fatG: Double) {
        self.kcal = kcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
    }

    public init(_ totals: NutritionTotals) {
        self.init(kcal: totals.kcal, proteinG: totals.proteinG, carbsG: totals.carbsG, fatG: totals.fatG)
    }

    public static func + (lhs: MacroAmounts, rhs: MacroAmounts) -> MacroAmounts {
        MacroAmounts(
            kcal: lhs.kcal + rhs.kcal,
            proteinG: lhs.proteinG + rhs.proteinG,
            carbsG: lhs.carbsG + rhs.carbsG,
            fatG: lhs.fatG + rhs.fatG
        )
    }

    public static func - (lhs: MacroAmounts, rhs: MacroAmounts) -> MacroAmounts {
        MacroAmounts(
            kcal: lhs.kcal - rhs.kcal,
            proteinG: lhs.proteinG - rhs.proteinG,
            carbsG: lhs.carbsG - rhs.carbsG,
            fatG: lhs.fatG - rhs.fatG
        )
    }
}

/// The adopted target for one day (spec §3), as plain numbers: kcal,
/// protein, carbs (the remainder) and the fat floor, all per day.
public struct DailyTarget: Sendable, Hashable {
    public let amounts: MacroAmounts

    public init(kcal: Double, proteinG: Double, carbsG: Double, fatFloorG: Double) {
        amounts = MacroAmounts(kcal: kcal, proteinG: proteinG, carbsG: carbsG, fatG: fatFloorG)
    }
}

/// Today's remaining against the adopted target, or the explicit "no
/// target adopted" state (spec §2 "Post-log surface"). Never imputed.
public enum RemainingToday: Sendable, Hashable {
    case noTargetAdopted
    /// `remaining` is `target − consumed` per field; negative means over.
    case vsTarget(target: DailyTarget, remaining: MacroAmounts)

    public init(target: DailyTarget?, consumed: MacroAmounts) {
        guard let target else {
            self = .noTargetAdopted
            return
        }
        self = .vsTarget(target: target, remaining: target.amounts - consumed)
    }
}

// MARK: - Provenance glyph

/// The per-item honesty glyph (spec §2 "Plate screen"): how an item's
/// numbers were obtained. Plain typed items carry none.
public struct ProvenanceGlyph: Sendable, Hashable {
    /// SF Symbol name.
    public let symbolName: String
    /// Visible label; also the accessibility label.
    public let label: String

    public init(symbolName: String, label: String) {
        self.symbolName = symbolName
        self.label = label
    }

    /// AI items say "AI estimate" permanently, edits included: the glyph is
    /// derived from the stored provenance, which edits never change.
    public static func forProvenance(_ provenance: ItemProvenance) -> ProvenanceGlyph? {
        switch provenance {
        case .typed: nil
        case .aiEstimate: ProvenanceGlyph(symbolName: "sparkles", label: "AI estimate")
        case .labelOCR: ProvenanceGlyph(symbolName: "text.viewfinder", label: "Label")
        case .scaleWeighed: ProvenanceGlyph(symbolName: "scalemass", label: "Scale")
        case .imported: ProvenanceGlyph(symbolName: "square.and.arrow.down", label: "Imported")
        }
    }
}

// MARK: - Item rows

/// What the plate list needs to know about a catalog food to name an item.
public struct PlateFoodInfo: Sendable, Hashable {
    public let name: String
    public let isLiquid: Bool
    public let servings: [ServingDef]

    public init(name: String, isLiquid: Bool = false, servings: [ServingDef] = []) {
        self.name = name
        self.isLiquid = isLiquid
        self.servings = servings
    }
}

/// One row of the plate's item list: name, grams (or serving), kcal and
/// the provenance glyph.
public struct PlateItemRow: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let quantityText: String
    public let kcalText: String
    public let glyph: ProvenanceGlyph?

    public static let unknownFoodName = "Unknown food"

    public init(item: MealItemData, food: PlateFoodInfo?) {
        id = item.id
        name = item.adHocName ?? food?.name ?? Self.unknownFoodName
        quantityText = PlateFormat.quantity(
            grams: item.quantityGrams,
            isLiquid: food?.isLiquid ?? false,
            servings: food?.servings ?? []
        )
        kcalText = "\(PlateFormat.whole(item.nutrition.kcal)) kcal"
        glyph = ProvenanceGlyph.forProvenance(item.provenance)
    }
}

// MARK: - Plate header

/// Share of the plate's energy from each macro (Atwater 4/4/9), for the
/// macro bar. All zero for an empty plate.
public struct MacroBarFractions: Sendable, Hashable {
    public static let proteinKcalPerG: Double = 4
    public static let carbsKcalPerG: Double = 4
    public static let fatKcalPerG: Double = 9

    public let protein: Double
    public let carbs: Double
    public let fat: Double

    public init(_ amounts: MacroAmounts) {
        let protein = amounts.proteinG * Self.proteinKcalPerG
        let carbs = amounts.carbsG * Self.carbsKcalPerG
        let fat = amounts.fatG * Self.fatKcalPerG
        let sum = protein + carbs + fat
        guard sum > 0, sum.isFinite else {
            self.protein = 0
            self.carbs = 0
            self.fat = 0
            return
        }
        self.protein = protein / sum
        self.carbs = carbs / sum
        self.fat = fat / sum
    }
}

/// The always-visible plate header (spec §2): the running plate total with
/// its macro bar, and today's remaining against the adopted target.
///
/// Remaining on the plate counts this plate as if it were logged now: a
/// draft's items are added to what is already logged today, so the number
/// is "what's left after this plate" and equals the post-log sheet's number
/// once the plate is logged today. A logged plate is already inside
/// `loggedToday` and is not added twice.
public struct PlateHeader: Sendable, Hashable {
    public let plateTotal: MacroAmounts
    public let macroBar: MacroBarFractions
    public let remaining: RemainingToday

    public init(plate: MealEntryData, loggedToday: NutritionTotals, target: DailyTarget?) {
        let plateTotal = MacroAmounts(plate.totals)
        let consumed = plate.state == .draft
            ? MacroAmounts(loggedToday) + plateTotal
            : MacroAmounts(loggedToday)
        self.plateTotal = plateTotal
        macroBar = MacroBarFractions(plateTotal)
        remaining = RemainingToday(target: target, consumed: consumed)
    }

    public var plateTotalText: String {
        "\(PlateFormat.whole(plateTotal.kcal)) kcal"
    }

    public var plateMacrosText: String {
        PlateFormat.macroLine(plateTotal)
    }

    /// One line for the plate: "640 kcal left today", "120 kcal over today"
    /// or "No target adopted".
    public var remainingText: String {
        switch remaining {
        case .noTargetAdopted:
            PostLogSummary.noTargetLine
        case .vsTarget(_, let remaining):
            "\(PlateFormat.leftOrOver(remaining.kcal, unit: "kcal")) today"
        }
    }
}

// MARK: - Hunger

/// The optional 1–5 hunger control (spec §2 "Hunger"). Untouched means
/// unknown (nil). Tapping the selected value again clears it back to
/// unknown; an out-of-range tap changes nothing.
public enum HungerControl {
    public static let values: [Int] = Array(DomainScale.hunger)

    public static func tapped(_ value: Int, current: Int?) -> Int? {
        guard DomainScale.hunger.contains(value) else { return current }
        return value == current ? nil : value
    }
}

// MARK: - Quantity step

/// The quantity step after picking a food (spec §2 "Typeahead", "Weighing
/// flows" add-then-weigh): type the scale reading in grams, prefilled with
/// the food's last portion, or pick a ServingDef and a count.
public struct QuantityStep: Sendable, Hashable, Identifiable {
    public enum Mode: Sendable, Hashable {
        case grams
        case serving(ServingDef)
    }

    public let foodID: UUID
    public let food: PlateFoodInfo
    public var mode: Mode

    public var id: UUID { foodID }
    /// The typed reading. Prefilled from `lastPortionGrams`, empty when the
    /// food has never been logged.
    public var gramsText: String
    /// Typed count of servings; "1" by default.
    public var servingCountText: String

    public init(foodID: UUID, food: PlateFoodInfo, prefillGrams: Double?) {
        self.foodID = foodID
        self.food = food
        mode = .grams
        gramsText = prefillGrams.map(PlateFormat.decimal) ?? ""
        servingCountText = "1"
    }

    /// The canonical grams to add, or nil while the input is not a finite
    /// positive number.
    public var resolvedGrams: Grams? {
        switch mode {
        case .grams:
            guard let grams = PlateFormat.parsePositive(gramsText) else { return nil }
            return Grams(grams)
        case .serving(let serving):
            guard let count = PlateFormat.parsePositive(servingCountText) else { return nil }
            let grams = serving.grams * count
            guard grams > 0, grams.isFinite else { return nil }
            return Grams(grams)
        }
    }
}

// MARK: - Formatting

/// Locale-independent number formatting shared by the plate surfaces, so a
/// snapshot is the same on every device and test host.
public enum PlateFormat {
    /// Nearest whole number, halves away from zero; never "-0".
    public static func whole(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        let rounded = value.rounded()
        return rounded == 0 ? "0" : String(Int(rounded))
    }

    /// One decimal at most, trailing ".0" dropped: 118 → "118",
    /// 37.5 → "37.5", 12.34 → "12.3".
    public static func decimal(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        let tenths = Int((value * 10).rounded())
        if tenths == 0 { return "0" }
        let sign = tenths < 0 ? "-" : ""
        let magnitude = abs(tenths)
        let fraction = magnitude % 10
        return fraction == 0 ? "\(sign)\(magnitude / 10)" : "\(sign)\(magnitude / 10).\(fraction)"
    }

    /// Accepts "." or "," as the decimal separator. Nil unless finite and > 0.
    public static func parsePositive(_ text: String) -> Double? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, value > 0 else { return nil }
        return value
    }

    /// "150 g" or "250 ml"; when the grams are exactly a whole number of one
    /// of the food's servings, "2 × slice (64 g)". The first matching
    /// serving wins.
    public static func quantity(grams: Double, isLiquid: Bool, servings: [ServingDef]) -> String {
        let unit = isLiquid ? "ml" : "g"
        let base = "\(decimal(grams)) \(unit)"
        for serving in servings where serving.grams > 0 {
            let count = grams / serving.grams
            guard count >= 1, count == count.rounded(), count <= 99 else { continue }
            return "\(Int(count)) × \(serving.name) (\(base))"
        }
        return base
    }

    /// "P 30 g · C 50 g · F 20 g".
    public static func macroLine(_ amounts: MacroAmounts) -> String {
        "P \(whole(amounts.proteinG)) g · C \(whole(amounts.carbsG)) g · F \(whole(amounts.fatG)) g"
    }

    /// "500 kcal left of 2000 kcal" or "120 kcal over 2000 kcal".
    public static func againstTarget(_ remaining: Double, target: Double, unit: String) -> String {
        let phrase = leftOrOver(remaining, unit: unit)
        let joiner = remaining.rounded() < 0 ? " " : " of "
        return "\(phrase)\(joiner)\(whole(target)) \(unit)"
    }

    /// "640 kcal left" or "120 kcal over". Zero reads as "0 … left".
    public static func leftOrOver(_ remaining: Double, unit: String) -> String {
        let over = remaining.rounded() < 0
        return over
            ? "\(whole(-remaining)) \(unit) over"
            : "\(whole(remaining)) \(unit) left"
    }
}
