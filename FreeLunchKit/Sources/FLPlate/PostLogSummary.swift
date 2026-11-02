// SPDX-License-Identifier: GPL-3.0-or-later
// The post-log surface (spec §2 "Post-log surface", acceptance #7): one
// dismissible sheet, remaining today first, daily totals beneath, and
// nothing after it. A plate logged late (acceptance #8) shows the day it
// was logged into: "Remaining yesterday" and yesterday's numbers. The
// section order is fixed by the type, not by the view, and `snapshot`
// renders exactly the titles and lines the sheet shows so a text snapshot
// pins what the user sees.
import FLCore
import Foundation

public struct PostLogSummary: Sendable, Hashable {
    public enum SectionKind: String, Sendable, Hashable {
        case remaining
        case dailyTotals
    }

    public struct Section: Sendable, Hashable, Identifiable {
        public let kind: SectionKind
        public let title: String
        public let lines: [String]

        public var id: SectionKind { kind }
    }

    /// The headings for a plate logged today.
    public static let remainingTitle = LoggedDay.today.remainingTitle
    public static let totalsTitle = LoggedDay.today.totalsTitle
    public static let noTargetLine = "No target adopted"

    public let remaining: RemainingToday
    public let dayTotals: MacroAmounts
    /// The day the plate was logged into, relative to when it was logged.
    public let day: LoggedDay

    /// `dayTotals` are the logged totals of the day the plate was logged
    /// into, this plate included, and `target` is that day's target. `day`
    /// names that day in the headings; it defaults to today.
    public init(dayTotals: NutritionTotals, target: DailyTarget?, day: LoggedDay = .today) {
        let totals = MacroAmounts(dayTotals)
        self.dayTotals = totals
        self.day = day
        remaining = RemainingToday(target: target, consumed: totals)
    }

    /// Always remaining first, then daily totals (locked priority).
    public var sections: [Section] {
        [
            Section(kind: .remaining, title: day.remainingTitle, lines: remainingLines),
            Section(kind: .dailyTotals, title: day.totalsTitle, lines: totalsLines)
        ]
    }

    /// The sheet as text: each section's title, then its lines indented.
    public var snapshot: String {
        sections
            .map { section in
                ([section.title] + section.lines.map { "  " + $0 }).joined(separator: "\n")
            }
            .joined(separator: "\n")
    }

    private var remainingLines: [String] {
        switch remaining {
        case .noTargetAdopted:
            return [Self.noTargetLine]
        case let .vsTarget(target, remaining):
            let t = target.amounts
            return [
                PlateFormat.againstTarget(remaining.kcal, target: t.kcal, unit: "kcal"),
                "Protein " + PlateFormat.againstTarget(remaining.proteinG, target: t.proteinG, unit: "g"),
                "Carbs " + PlateFormat.againstTarget(remaining.carbsG, target: t.carbsG, unit: "g"),
                PlateFormat.againstFloor(remaining.fatG, floor: t.fatG, name: "Fat", unit: "g")
            ]
        }
    }

    private var totalsLines: [String] {
        [
            "\(PlateFormat.whole(dayTotals.kcal)) kcal",
            PlateFormat.macroLine(dayTotals)
        ]
    }
}

/// Where the phone is in the log flow. The plate is pushed over the
/// timeline; logging pops it *before* presenting the post-log sheet over the
/// timeline, so dismissing the sheet is one gesture back to the timeline
/// (spec §2 acceptance #7). There is no interstitial chain: logging presents
/// exactly one sheet and dismissing it presents nothing else.
public struct PlateFlow: Sendable, Hashable {
    /// The plate pushed over the timeline, if any.
    public private(set) var openPlateID: UUID?
    /// The post-log sheet presented over the timeline, if any.
    public private(set) var postLog: PostLogSummary?

    public init() {}

    public var isOnTimeline: Bool { openPlateID == nil && postLog == nil }

    /// Opens a new or resumed draft (or a logged plate for editing).
    public mutating func open(plateID: UUID) {
        postLog = nil
        openPlateID = plateID
    }

    /// Leaves the plate without logging; a draft stays a draft.
    public mutating func closePlate() {
        openPlateID = nil
    }

    /// The explicit Log action succeeded: back to the timeline with the
    /// post-log sheet over it.
    public mutating func didLog(_ summary: PostLogSummary) {
        openPlateID = nil
        postLog = summary
    }

    /// The one dismissal gesture.
    public mutating func dismissPostLog() {
        postLog = nil
    }
}
