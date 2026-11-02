// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import FLEnergyCore

/// Synthetic fixture shared by the target and versioning tests (fl-m3-03).
///
/// - Calendar: Gregorian pinned to UTC, so a calendar day is 86 400 s.
/// - Weight: hand-set trend 80 − 0.0625·k kg at 07:00 on every day k in
///   −22...40. Over any 21-day window Δtrend = −0.0625 × 21 = −1.3125 kg.
/// - Intake: 2000 kcal logged (2 meals) on every day 0...40.
///
/// Expenditure for any evaluation day T in 21...41 is therefore
/// 2000 + 1.3125 × ρ / 21: 2481.25 kcal/day at ρ = 7700 and 2437.5 at
/// ρ = 7000. Days 14–20 also track at those values (≥14 complete days);
/// day 13 and earlier are paused for insufficient intake. These values were
/// computed by hand and with a throwaway script outside the repo.
enum TargetFixture {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// A synthetic UTC midnight (2001-01-01 + 9260 days).
    static let origin = Date(timeIntervalSinceReferenceDate: 9_260 * 86_400)

    /// Start of fixture day `offset`.
    static func day(_ offset: Int) -> Date {
        origin.addingTimeInterval(Double(offset) * 86_400)
    }

    /// 07:00 on fixture day `offset`.
    static func morning(_ offset: Int) -> Date {
        day(offset).addingTimeInterval(7 * 3_600)
    }

    /// 12:30 on fixture day `offset`.
    static func noon(_ offset: Int) -> Date {
        day(offset).addingTimeInterval(12.5 * 3_600)
    }

    static let weights = TrendSeries(
        smoothing: .standard,
        points: (-22...40).map {
            let kg = 80 - 0.0625 * Double($0)
            return TrendPoint(measuredAt: morning($0), weightKg: kg, trendKg: kg)
        }
    )

    /// 2000 kcal on days 0...40, with `edits` replacing single days' totals
    /// (a backfill edit).
    static func intake(edits: [Int: Double] = [:]) -> [DayIntake] {
        (0...40).map {
            DayIntake(
                day: noon($0),
                intakeKcal: edits[$0] ?? 2_000,
                evidence: DayIntakeEvidence(loggedMealCount: 2)
            )
        }
    }

    /// A non-builtin-v1 version for the versioning tests: same expression,
    /// ρ = 7000 kcal/kg.
    static let v2 = EnergyFormulaVersion(
        name: "FL-EB v2 (synthetic)",
        origin: .builtin("FL-EB v2"),
        parameters: ExpenditureParameters(energyDensityKcalPerKg: 7_000)!
    )

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    static func rate(_ kgPerWeek: Double) -> RateGoal {
        RateGoal(kgPerWeek: kgPerWeek)!
    }

    static func macros(protein: Double = 128, fatFloorPct: Double = 20) -> MacroTargets {
        MacroTargets(proteinTargetG: protein, fatFloorPct: fatFloorPct)!
    }

    /// Deterministic JSON bytes, for byte-identity checks.
    static func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
