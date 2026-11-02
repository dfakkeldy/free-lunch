// SPDX-License-Identifier: GPL-3.0-or-later
// FLCore — every enum the spec §1 data model names, with its exact cases.
//
// Raw values are spelled out so the persisted form never depends on Swift's
// case naming. Enums with an associated value (`SideEffectType.other`,
// `FormulaOrigin.builtin`) use synthesized Codable and are not CaseIterable.

/// Where a FoodItem came from (spec §1 FoodItem.origin).
public enum FoodOrigin: String, Sendable, Hashable, Codable, CaseIterable {
    case seeded
    case custom
    case aiCreated
    case labelOCR
    case imported
}

/// A plate is a draft until deliberately logged (spec §1 MealEntry.state).
public enum MealState: String, Sendable, Hashable, Codable, CaseIterable {
    case draft
    case logged
}

/// Which surface created a MealEntry (spec §1 MealEntry.source).
public enum MealSource: String, Sendable, Hashable, Codable, CaseIterable {
    case phone
    case watchQuickLog
    case watchMarker
    case healthKitImport
}

/// How a MealItem's quantity and nutrition were obtained (spec §1
/// MealItem.provenance). Permanent; survives edits.
public enum ItemProvenance: String, Sendable, Hashable, Codable, CaseIterable {
    case typed
    case scaleWeighed
    case aiEstimate
    case labelOCR
    case imported
}

/// Lifecycle of an AI photo estimate (spec §1 AIEstimationRecord.status).
public enum AIEstimationStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case pending
    case complete
    case failed
}

/// What a PhotoAttachment shows (spec §1 PhotoAttachment.kind).
public enum PhotoKind: String, Sendable, Hashable, Codable, CaseIterable {
    case meal
    case label
}

/// Optional 8-value injection-site rotation (spec §1 ShotEvent.site).
public enum InjectionSite: String, Sendable, Hashable, Codable, CaseIterable {
    case abdomenLeft
    case abdomenRight
    case thighLeft
    case thighRight
    case armLeft
    case armRight
    case other1
    case other2
}

/// Which surface recorded a ShotEvent (spec §1 ShotEvent.source).
public enum ShotSource: String, Sendable, Hashable, Codable, CaseIterable {
    case phone
    case watch
    case shotsyImport
}

/// On-demand side-effect categories (spec §1 SideEffectEntry.type).
/// `other` carries the user's free text.
public enum SideEffectType: Sendable, Hashable, Codable {
    case nausea
    case vomiting
    case constipation
    case diarrhea
    case fatigue
    case appetiteLoss
    case injectionSite
    case other(String)
}

/// The kind of imported record a Correction targets (spec §1 Correction).
public enum CorrectionTargetKind: String, Sendable, Hashable, Codable, CaseIterable {
    case hkWeightSample
    case hkNutritionDay
    case importedShot
}

/// What a Correction does to its target (spec §1 Correction.action).
public enum CorrectionAction: String, Sendable, Hashable, Codable, CaseIterable {
    case exclude
    case replace
}

/// State of a PlannedShot or PlannedMeal (spec §1 planner schema).
public enum PlanStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case pending
    case done
    case skipped
}

/// Where a FormulaVersion came from (spec §1 FormulaVersion.origin).
/// `builtin` carries the builtin formula's identifier.
public enum FormulaOrigin: Sendable, Hashable, Codable {
    case builtin(String)
    case userEdited
    case imported
}

/// Integer scales the spec §1 entities carry as plain `Int`s.
public enum DomainScale {
    /// Optional pre-meal hunger; absence means unknown and is never imputed.
    public static let hunger: ClosedRange<Int> = 1...5
    /// SideEffectEntry.severity.
    public static let sideEffectSeverity: ClosedRange<Int> = 1...3
}
