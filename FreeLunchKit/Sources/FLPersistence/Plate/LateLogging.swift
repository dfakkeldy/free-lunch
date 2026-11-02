// SPDX-License-Identifier: GPL-3.0-or-later
// The user-facing late-logging actions (spec §2 "Log": `loggedAt` defaults
// to now and stays editable; acceptance #8). These are what the app calls:
// they apply `LoggedAtRule` (never in the future, judged by the service's
// clock) and return the day totals the screens show next.
//
// The lower-level `log(mealID:at:)` and `setLoggedAt(_:mealID:)` stay
// unchecked, for imported or synced timestamps and for fixtures that pin a
// clock; nothing a person types reaches them directly.
import FLCore
import Foundation

public enum LateLoggingError: Error, Equatable, Sendable {
    /// The chosen `loggedAt` is later than now.
    case loggedAtInFuture(UUID)
}

/// One calendar day's logged totals.
public struct LoggedDayTotals: Sendable, Hashable {
    /// Any moment inside the day (the plate's `loggedAt`).
    public let day: Date
    public let totals: NutritionTotals

    public init(day: Date, totals: NutritionTotals) {
        self.day = day
        self.totals = totals
    }
}

/// What moving a logged plate's `loggedAt` changed: the plate, and the
/// recomputed totals of the day it left and the day it joined. When both
/// moments fall in the same day the two totals are the same day's.
public struct LoggedAtMove: Sendable, Hashable {
    public let meal: MealEntryData
    public let previousDay: LoggedDayTotals
    public let newDay: LoggedDayTotals
}

/// The result of the Log action: the logged plate and the totals of the
/// day it was logged into, this plate included.
public struct LoggedPlate: Sendable, Hashable {
    public let meal: MealEntryData
    public let day: LoggedDayTotals
}

extension PlateLifecycleService {
    /// The deliberate Log action. `at == nil` keeps the default, now (the
    /// service's clock); an earlier moment logs the plate late. A future
    /// moment is refused and the plate stays a draft.
    @discardableResult
    public func logPlate(mealID: UUID, at chosen: Date?, calendar: Calendar) throws -> LoggedPlate {
        let current = now()
        let loggedAt = chosen ?? current
        guard LoggedAtRule.permits(loggedAt, now: current) else {
            throw LateLoggingError.loggedAtInFuture(mealID)
        }
        let meal = try log(mealID: mealID, at: loggedAt)
        let day = meal.loggedAt ?? loggedAt
        return LoggedPlate(
            meal: meal,
            day: LoggedDayTotals(day: day, totals: try dayTotals(containing: day, calendar: calendar))
        )
    }

    /// Edits a logged plate's `loggedAt`. The plate moves to the new day and
    /// both days' totals are recomputed from the stored snapshots. A future
    /// moment is refused and nothing changes.
    @discardableResult
    public func moveLoggedMeal(mealID: UUID, to loggedAt: Date, calendar: Calendar) throws -> LoggedAtMove {
        guard LoggedAtRule.permits(loggedAt, now: now()) else {
            throw LateLoggingError.loggedAtInFuture(mealID)
        }
        guard let before = try store.meal(id: mealID) else {
            throw FreeLunchStoreError.notFound(mealID)
        }
        guard before.state == .logged, let previous = before.loggedAt else {
            throw PlateLifecycleError.mealNotLogged(mealID)
        }
        let meal = try setLoggedAt(loggedAt, mealID: mealID)
        return LoggedAtMove(
            meal: meal,
            previousDay: LoggedDayTotals(day: previous, totals: try dayTotals(containing: previous, calendar: calendar)),
            newDay: LoggedDayTotals(day: loggedAt, totals: try dayTotals(containing: loggedAt, calendar: calendar))
        )
    }
}
