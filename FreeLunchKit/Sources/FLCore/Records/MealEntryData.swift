// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — plate value types (spec §1 MealEntry, MealItem, PhotoAttachment,
// AIEstimationRecord).
//
// A MealItem's `nutrition` is its log-time snapshot: the record, not a view
// of the catalog. The `foodID` is provenance only; editing that food later
// never changes the snapshot.
import Foundation

public struct PhotoAttachmentData: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// Relative to the app container. Never an absolute path.
    public var relativePath: String
    public var capturedAt: Date
    public var kind: PhotoKind

    public init(id: UUID = UUID(), relativePath: String, capturedAt: Date, kind: PhotoKind) {
        self.id = id
        self.relativePath = relativePath
        self.capturedAt = capturedAt
        self.kind = kind
    }

    /// Photos are presented by capture time, ties by id.
    public static func displayOrder(_ lhs: PhotoAttachmentData, _ rhs: PhotoAttachmentData) -> Bool {
        if lhs.capturedAt != rhs.capturedAt { return lhs.capturedAt < rhs.capturedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// The audit trail of one AI photo estimate (spec §1).
public struct AIEstimationRecordData: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var createdAt: Date
    public var photoID: UUID?
    public var hint: String?
    public var providerTier: Int
    public var modelID: String
    public var status: AIEstimationStatus
    /// The raw structured output, kept verbatim.
    public var responseJSON: Data?
    /// Re-run hints, appended in order.
    public var userCorrections: [String]

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        photoID: UUID? = nil,
        hint: String? = nil,
        providerTier: Int,
        modelID: String,
        status: AIEstimationStatus = .pending,
        responseJSON: Data? = nil,
        userCorrections: [String] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.photoID = photoID
        self.hint = hint
        self.providerTier = providerTier
        self.modelID = modelID
        self.status = status
        self.responseJSON = responseJSON
        self.userCorrections = userCorrections
    }
}

public struct MealItemData: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var order: Int
    /// Catalog provenance. Nil for an ad-hoc item.
    public var foodID: UUID?
    /// The ad-hoc item's name. Nil for a catalog item.
    public var adHocName: String?
    /// Canonical grams.
    public private(set) var quantityGrams: Double
    /// The log-time nutrition snapshot for `quantityGrams`.
    public var nutrition: NutritionValues
    public var provenance: ItemProvenance
    public var aiRecordID: UUID?
    public var confidence: Double?

    public init(
        id: UUID = UUID(),
        order: Int,
        foodID: UUID?,
        adHocName: String? = nil,
        quantity: Grams,
        nutrition: NutritionValues,
        provenance: ItemProvenance,
        aiRecordID: UUID? = nil,
        confidence: Double? = nil
    ) {
        self.id = id
        self.order = order
        self.foodID = foodID
        self.adHocName = adHocName
        self.quantityGrams = quantity.value
        self.nutrition = nutrition
        self.provenance = provenance
        self.aiRecordID = aiRecordID
        self.confidence = confidence
    }

    public mutating func setQuantity(_ quantity: Grams) {
        quantityGrams = quantity.value
    }

    /// Items are presented by `order`, ties by id.
    public static func displayOrder(_ lhs: MealItemData, _ rhs: MealItemData) -> Bool {
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// One plate, draft or logged (spec §1 MealEntry).
public struct MealEntryData: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var state: MealState
    public var createdAt: Date
    /// User-adjustable; late logging is supported.
    public var loggedAt: Date?
    /// In display order.
    public var items: [MealItemData]
    /// Optional pre-meal hunger, `DomainScale.hunger`. Nil means unknown.
    public var hunger: Int?
    public var note: String?
    /// In display order.
    public var photos: [PhotoAttachmentData]
    public var source: MealSource

    public init(
        id: UUID = UUID(),
        state: MealState = .draft,
        createdAt: Date,
        loggedAt: Date? = nil,
        items: [MealItemData] = [],
        hunger: Int? = nil,
        note: String? = nil,
        photos: [PhotoAttachmentData] = [],
        source: MealSource
    ) {
        self.id = id
        self.state = state
        self.createdAt = createdAt
        self.loggedAt = loggedAt
        self.items = items
        self.hunger = hunger
        self.note = note
        self.photos = photos
        self.source = source
    }

    /// Totals of this plate's snapshots.
    public var totals: NutritionTotals { NutritionTotals(items: items) }
}

/// What to add to a plate. A catalog item's snapshot is computed by the
/// store from the food's current per-100 g values; an ad-hoc item carries
/// its own typed values for the whole portion.
public struct MealItemInput: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case catalog(foodID: UUID)
        case adHoc(name: String, nutrition: NutritionValues)
    }

    public var id: UUID
    public var kind: Kind
    public var quantity: Grams
    public var provenance: ItemProvenance
    public var aiRecordID: UUID?
    public var confidence: Double?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        quantity: Grams,
        provenance: ItemProvenance,
        aiRecordID: UUID? = nil,
        confidence: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.quantity = quantity
        self.provenance = provenance
        self.aiRecordID = aiRecordID
        self.confidence = confidence
    }

    public static func catalog(
        id: UUID = UUID(),
        foodID: UUID,
        quantity: Grams,
        provenance: ItemProvenance = .typed
    ) -> MealItemInput {
        MealItemInput(id: id, kind: .catalog(foodID: foodID), quantity: quantity, provenance: provenance)
    }

    public static func adHoc(
        id: UUID = UUID(),
        name: String,
        quantity: Grams,
        nutrition: NutritionValues,
        provenance: ItemProvenance = .typed
    ) -> MealItemInput {
        MealItemInput(id: id, kind: .adHoc(name: name, nutrition: nutrition), quantity: quantity, provenance: provenance)
    }
}
