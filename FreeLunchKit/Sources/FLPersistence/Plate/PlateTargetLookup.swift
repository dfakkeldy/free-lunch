// SPDX-License-Identifier: GPL-3.0-or-later
// The adopted target the plate screen and post-log sheet compare against
// (spec §2 "Plate screen", "Post-log surface"; target semantics spec §3).
// Read-only: it never adopts or changes a period.
import FLCore
import FLEnergyCore
import Foundation

extension TargetStore {
    /// The macro breakdown of the adopted target governing `day`'s calendar
    /// day, or nil when no period governs it ("no target adopted"). Uses the
    /// period's pinned adopted kcal and macros, never a live calculation.
    public func adoptedMacroBreakdown(on day: Date, calendar: Calendar) throws -> MacroBreakdown? {
        guard let period = try targetLedger().period(governing: day, calendar: calendar),
              let macros = period.macros
        else { return nil }
        return macros.breakdown(targetKcal: period.adoptedTargetKcal)
    }
}
