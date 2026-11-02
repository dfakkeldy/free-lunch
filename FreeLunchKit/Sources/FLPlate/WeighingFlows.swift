// SPDX-License-Identifier: GPL-3.0-or-later
// The two weighing flows of spec §2 as the app drives them.
//
// Add-then-weigh: a reading entered in the quantity step's grams field is a
// scale reading, so an item added from it is `.scaleWeighed`. Picking a
// ServingDef, or confirming the prefilled last portion untouched, is not a
// reading and stays `.typed`.
//
// Weigh-as-you-go: a plate-level scale session (tared or cumulative) turns
// each reading into one item's grams. Both flows hand the store the same
// thing, a catalog item with grams and `.scaleWeighed`, so the plate does
// not care which path filled it.
//
// FLPlate cannot see the store, so the session takes the write as a
// closure. The order inside `add` is the guarantee: validate the reading,
// persist, and only then advance the cumulative baseline. A rejected reading
// never reaches the closure, and a failed write never moves the baseline.
import FLCore

// MARK: - Add-then-weigh

extension QuantityStep {
    /// The provenance of the item this step adds (spec §2 "Weighing flows").
    ///
    /// A gram reading the user entered is a scale reading. Everything else
    /// stays `.typed`:
    /// - the prefilled `lastPortionGrams` confirmed without editing (spec §2
    ///   "one-tap confirm"): a remembered portion, nothing was weighed;
    /// - a liquid's grams field, labelled as millilitres: a jug or bottle
    ///   measure rather than a scale reading;
    /// - a picked ServingDef.
    public var provenance: ItemProvenance {
        switch mode {
        case .grams:
            if food.isLiquid || gramsText == prefilledGramsText { return .typed }
            return .scaleWeighed
        case .serving:
            return .typed
        }
    }
}

// MARK: - Weigh-as-you-go

/// Why a scale reading was not turned into an item. The user is asked to
/// re-enter the reading; nothing is stored.
public enum ScaleEntryError: Error, Equatable, Sendable {
    /// The reading itself was refused by the session math.
    case rejected(ScaleSessionError)
    /// The reading adds nothing: a tared 0 g, or a cumulative reading equal
    /// to the last one. The store refuses zero-gram items, so ask again here.
    case nothingAdded
}

/// A plate-level scale session (spec §2 "Weigh-as-you-go"). Session state
/// lives in memory for the open plate; the items it adds are ordinary
/// stored plate items.
public struct PlateScaleSession: Sendable, Equatable {
    /// Every item a scale session adds carries this provenance.
    public static let provenance: ItemProvenance = .scaleWeighed

    public private(set) var session: ScaleSession

    public init(mode: ScaleSessionMode) {
        session = ScaleSession(mode: mode)
    }

    public var mode: ScaleSessionMode { session.mode }

    /// How many readings became items in this session.
    public var itemCount: Int { session.items.count }

    /// What the scale showed at the last accepted reading. Nil for a tared
    /// session (there is no running total) and before the first item.
    public var lastReading: Double? {
        guard mode == .cumulative, !session.items.isEmpty else { return nil }
        return session.lastCumulativeReading
    }

    /// The grams a reading would add, without changing the session.
    public func grams(forReading reading: Double) throws(ScaleEntryError) -> Grams {
        let grams: Grams
        do {
            grams = try session.grams(forReading: reading)
        } catch {
            throw .rejected(error)
        }
        guard grams.value > 0 else { throw .nothingAdded }
        return grams
    }

    /// Turns one reading into one stored item.
    ///
    /// `persist` receives the item's grams and its provenance and does the
    /// store write. It is not called for a rejected reading. The session
    /// only advances after `persist` returns, so a failed write leaves the
    /// cumulative baseline where it was and the same reading can be retried.
    @discardableResult
    public mutating func add<Item>(
        reading: Double,
        persist: (Grams, ItemProvenance) throws -> Item
    ) throws -> Item {
        let grams = try grams(forReading: reading)
        let item = try persist(grams, Self.provenance)
        // Same reading, same unchanged session: `grams(forReading:)` above
        // already accepted it, so this cannot throw.
        try session.record(reading: reading)
        return item
    }
}

// MARK: - Wording

/// The strings the scale-session UI shows, kept here so they are tested
/// and locale-independent like the rest of the plate's presentation.
public enum ScaleSessionText {
    public static func modeName(_ mode: ScaleSessionMode) -> String {
        switch mode {
        case .tared: "Tared"
        case .cumulative: "Cumulative"
        }
    }

    /// One line describing how the mode reads the scale.
    public static func modeExplanation(_ mode: ScaleSessionMode) -> String {
        switch mode {
        case .tared: "Tare before each item. Each reading is that item."
        case .cumulative: "Never tare. Each item is the increase since the last reading."
        }
    }

    /// The label above the reading field.
    public static func readingFieldLabel(_ mode: ScaleSessionMode) -> String {
        switch mode {
        case .tared: "Scale reading (g)"
        case .cumulative: "Total on the scale (g)"
        }
    }

    /// The running status shown on the plate while a session is active.
    public static func status(_ session: PlateScaleSession) -> String {
        if let last = session.lastReading {
            return "Scale showed \(PlateFormat.decimal(last)) g"
        }
        switch session.mode {
        case .tared: return "Tare, add the food, enter the reading"
        case .cumulative: return "Tare the empty bowl once, then add food"
        }
    }

    /// "Adds 162.5 g" for a reading the session would accept.
    public static func preview(_ grams: Grams) -> String {
        "Adds \(PlateFormat.decimal(grams.value)) g"
    }

    /// The re-entry prompt for a refused reading.
    public static func prompt(for error: ScaleEntryError, mode: ScaleSessionMode) -> String {
        switch error {
        case .rejected(.negativeDelta(let reading, let previous)):
            "\(PlateFormat.decimal(reading)) g is less than the last total of "
                + "\(PlateFormat.decimal(previous)) g. Check the scale and enter the new total."
        case .rejected(.negativeReading), .rejected(.notFinite):
            "Enter the number the scale shows, in grams."
        case .nothingAdded:
            switch mode {
            case .tared: "The reading is 0 g. Add the food, then enter the reading."
            case .cumulative: "The total hasn't changed. Add the food, then enter the new total."
            }
        }
    }
}
