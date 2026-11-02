// SPDX-License-Identifier: GPL-3.0-or-later
// The persistence-neutral representation of AI capture state for one draft plate.
import Foundation

public struct AICaptureSnapshot: Sendable, Hashable {
    /// The photos referenced by `records`; their kind is the persisted capture kind.
    public var photos: [PhotoAttachmentData]
    public var records: [AIEstimationRecordData]
    /// AI-derived items only: each is linked to an AI record and has AI provenance.
    public var items: [MealItemData]

    public init(
        photos: [PhotoAttachmentData],
        records: [AIEstimationRecordData],
        items: [MealItemData]
    ) {
        self.photos = photos
        self.records = records
        self.items = items
    }
}

/// FLPlate declares its own `AIEstimationRecordData`, which shadows this
/// module's type there. This alias lets FLPlate name the stored shape.
public typealias StoredAIEstimationRecordData = AIEstimationRecordData
