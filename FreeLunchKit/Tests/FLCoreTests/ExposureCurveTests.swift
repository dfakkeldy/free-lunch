// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §5 acceptance #2 (golden vectors, single-dose peak at tmax), #3
// (reference recomputes on dose and interval change, never-miss converges
// to 100%) and the pure-math half of #6 (no absolute level in the output).
import Foundation
import Testing
@testable import FLCore
import FLFixtures

private typealias F = ExposureCurveFixtures

/// Golden values match to this many percentage points. The script works in
/// 50-digit decimal; Double sums of a dozen terms agree far tighter.
private let goldenTolerance = 1e-8

private func curve(_ shots: [ShotEventData], _ profile: MedicationProfileData) throws -> ExposureCurve {
    try ExposureCurve(shots: shots, profile: profile)
}

private func expectGolden(
    _ curve: ExposureCurve,
    _ golden: [(hours: Double, percent: Double)],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for (hours, percent) in golden {
        let value = curve.percentOfSteadyState(at: F.hour(hours))
        #expect(
            abs(value - percent) < goldenTolerance,
            "hour \(hours): \(value) vs golden \(percent)",
            sourceLocation: sourceLocation
        )
    }
}

@Suite("Exposure curve")
struct ExposureCurveTests {
    // The script is run with the prefills below. If a prefill changes, rerun
    // it with the new numbers and paste the new vectors.
    @Test("known-medication prefills match the numbers given to the golden script")
    func prefillsMatchScriptInputs() {
        #expect(KnownMedication.semaglutide.halfLifeHours == 168)
        #expect(KnownMedication.semaglutide.tmaxHours == 36)
        #expect(KnownMedication.tirzepatide.halfLifeHours == 120)
        #expect(KnownMedication.tirzepatide.tmaxHours == 24)
        #expect(MedicationProfileData.defaultIntervalDays == 7)
    }

    // Produced by:
    //   python3 Scripts/exposure-curve-golden.py semaglutide 168 36 7
    // over DosePeriodFixtures.shots (0.25 mg x4, 0.5 mg with day 42 missed,
    // 1.0 mg every 6 days). Reference: 1.0 mg every 7 days.
    //   ke 4.125876074761579e-3 /h, ka 8.964059605724918e-2 /h
    //   steady-state peak 27.894414289090 h after each shot
    @Test("semaglutide golden vectors with a missed week and dose changes")
    func semaglutideGolden() throws {
        let profile = MedicationProfileData(id: DosePeriodFixtures.medicationID, known: .semaglutide)
        let curve = try curve(DosePeriodFixtures.shots, profile)
        #expect(abs(curve.eliminationRatePerHour - 4.125876074761579e-3) < 1e-17)
        #expect(abs(curve.absorptionRatePerHour - 8.964059605724918e-2) < 1e-15)
        #expect(abs(curve.reference.peakOffsetHours - 27.894414289090) < 1e-9)
        #expect(curve.reference.doseMg == 1.0)
        #expect(curve.reference.intervalDays == 7)
        expectGolden(curve, [
            (-24, 0.000000000000),
            (0, 0.000000000000),
            (36, 12.088879762580),
            (168, 7.350655975376),
            (240, 16.361418477580),
            (672, 13.782483661101),
            (1008, 25.497594137503),
            (1092, 18.029527705880),
            (1176, 12.748801305633),
            (1512, 25.239172489416),
            (1980, 103.973180444560),
            (2016, 91.540512999592),
            (2184, 45.816536909690),
            (2520, 11.454134234091)
        ])
    }

    // Produced by:
    //   python3 Scripts/exposure-curve-golden.py tirzepatide 120 24 7
    // over ExposureCurveFixtures.tirzepatideShots (2.5 mg x4, 5 mg with day
    // 42 missed and a shot 30 h late). Reference: 5 mg every 7 days.
    //   ke 5.776226504666211e-3 /h, ka 1.380079089762877e-1 /h
    //   steady-state peak 20.397912429832 h after each shot
    @Test("tirzepatide golden vectors with a missed week, a dose change and a late shot")
    func tirzepatideGolden() throws {
        let curve = try curve(F.tirzepatideShots, F.tirzepatideProfile)
        #expect(abs(curve.eliminationRatePerHour - 5.776226504666211e-3) < 1e-17)
        #expect(abs(curve.absorptionRatePerHour - 1.380079089762877e-1) < 1e-15)
        #expect(abs(curve.reference.peakOffsetHours - 20.397912429832) < 1e-9)
        #expect(curve.reference.doseMg == 5)
        expectGolden(curve, [
            (0, 0.000000000000),
            (24, 30.414103502553),
            (168, 13.816800172886),
            (504, 21.036305357801),
            (696, 79.795823015443),
            (1008, 41.233266729017),
            (1152, 17.947821791449),
            (1200, 74.430112416143),
            (1374, 28.215584263919),
            (1398, 85.391299779872),
            (1536, 100.505053517946),
            (1680, 44.903950892749),
            (2016, 6.447636816314)
        ])
    }

    /// Sampled each minute, the single-dose maximum falls on tmax within one
    /// sampling step, and the solved ka satisfies the tmax equation.
    @Test("a single dose peaks at tmaxHours", arguments: KnownMedication.allCases)
    func singleDosePeak(known: KnownMedication) throws {
        let profile = MedicationProfileData(known: known)
        let shot = ShotEventData(takenAt: F.anchor, dose: Milligrams(1), medicationID: profile.id)
        let curve = try curve([shot], profile)

        let ke = curve.eliminationRatePerHour
        let ka = curve.absorptionRatePerHour
        #expect(ka > ke)
        #expect(abs(log(ka / ke) / (ka - ke) - known.tmaxHours) < 1e-9)

        let stepMinutes = 1.0
        var best = (minutes: 0.0, value: -Double.infinity)
        var minutes = stepMinutes
        while minutes <= known.tmaxHours * 60 * 4 {
            let value = curve.percentOfSteadyState(at: F.anchor.addingTimeInterval(minutes * 60))
            if value > best.value { best = (minutes, value) }
            minutes += stepMinutes
        }
        #expect(abs(best.minutes / 60 - known.tmaxHours) <= stepMinutes / 60)
    }

    /// 20 weekly shots leave at most 2^-20 of the approach to steady state
    /// for semaglutide (one half-life per week) and less for tirzepatide, so
    /// the last peak is within 0.001 percentage points of 100. The curve
    /// approaches from below and never passes 100.
    @Test("a never-miss schedule converges to 100%", arguments: [
        (KnownMedication.semaglutide, 7),
        (KnownMedication.tirzepatide, 7),
        (KnownMedication.semaglutide, 14),
        (KnownMedication.tirzepatide, 10)
    ])
    func neverMissConverges(known: KnownMedication, intervalDays: Int) throws {
        let profile = MedicationProfileData(known: known, intervalDays: intervalDays)
        let shots = F.neverMiss(
            count: 20, mg: 2, intervalDays: Double(intervalDays), medicationID: profile.id
        )
        let curve = try curve(shots, profile)
        let last = shots[shots.count - 1].takenAt

        let peak = curve.percentOfSteadyState(
            at: last.addingTimeInterval(curve.reference.peakOffsetHours * 3_600)
        )
        #expect(abs(peak - 100) < 0.001)

        let end = last.addingTimeInterval(Double(intervalDays) * 86_400)
        var date = F.anchor
        while date <= end {
            #expect(curve.percentOfSteadyState(at: date) <= 100 + 1e-9)
            date.addTimeInterval(3_600)
        }
    }

    /// Linear kinetics: two histories that differ only in the latest dose
    /// give curves that, before that shot, differ only by the reference, so
    /// their ratio is exactly the inverse dose ratio.
    @Test("the reference recomputes when the latest dose changes")
    func referenceFollowsDose() throws {
        let profile = MedicationProfileData(known: .semaglutide)
        let earlier = F.neverMiss(count: 6, mg: 0.5, intervalDays: 7, medicationID: profile.id)
        let lastAt = DosePeriodFixtures.day(42)
        let same = ShotEventData(takenAt: lastAt, dose: Milligrams(0.5), medicationID: profile.id)
        let raised = ShotEventData(takenAt: lastAt, dose: Milligrams(1), medicationID: profile.id)

        let flat = try curve(earlier + [same], profile)
        let stepped = try curve(earlier + [raised], profile)
        #expect(flat.reference.doseMg == 0.5)
        #expect(stepped.reference.doseMg == 1)

        for hours in stride(from: 12.0, through: 41 * 24, by: 37) {
            let date = F.hour(hours)
            let ratio = flat.percentOfSteadyState(at: date) / stepped.percentOfSteadyState(at: date)
            #expect(abs(ratio - 2) < 1e-12)
        }
        // After the raised shot its own contribution counts at the new dose.
        let after = lastAt.addingTimeInterval(36 * 3_600)
        #expect(stepped.percentOfSteadyState(at: after) > flat.percentOfSteadyState(at: after) / 2)
    }

    /// A longer interval lowers the steady-state peak, so the same shots read
    /// higher. The ratio is constant across the curve and equals the ratio
    /// of the two closed-form peaks.
    @Test("the reference recomputes when the interval changes")
    func referenceFollowsInterval() throws {
        let weekly = MedicationProfileData(id: DosePeriodFixtures.medicationID, known: .semaglutide)
        var fortnightly = weekly
        fortnightly.intervalDays = 14

        let a = try curve(DosePeriodFixtures.shots, weekly)
        let b = try curve(DosePeriodFixtures.shots, fortnightly)
        #expect(a.reference.intervalDays == 7)
        #expect(b.reference.intervalDays == 14)
        #expect(a.reference.peakOffsetHours != b.reference.peakOffsetHours)

        let ke = a.eliminationRatePerHour
        let ka = a.absorptionRatePerHour
        let expected = ExposureCurve.steadyStatePeak(ke: ke, ka: ka, intervalHours: 168).peak
            / ExposureCurve.steadyStatePeak(ke: ke, ka: ka, intervalHours: 336).peak
        #expect(expected > 1)
        for hours in stride(from: 30.0, through: 2_500, by: 97) {
            let date = F.hour(hours)
            let ratio = b.percentOfSteadyState(at: date) / a.percentOfSteadyState(at: date)
            #expect(abs(ratio - expected) < 1e-12)
        }
    }

    /// Day 42 is missed in the semaglutide fixture: from shortly after the
    /// day-35 peak until the day-49 shot the curve only falls.
    @Test("a missed dose shows the trough, with no phantom shot")
    func missedDoseShowsTrough() throws {
        let curve = try curve(DosePeriodFixtures.shots, DosePeriodFixtures.profile)
        var previous = curve.percentOfSteadyState(at: F.hour(37 * 24))
        for hours in stride(from: 37.0 * 24 + 1, through: 49 * 24, by: 1) {
            let value = curve.percentOfSteadyState(at: F.hour(hours))
            #expect(value < previous, "rose at hour \(hours)")
            previous = value
        }
    }

    @Test("zero before the first shot and at its instant")
    func zeroBeforeFirstShot() throws {
        let curve = try curve(DosePeriodFixtures.shots, DosePeriodFixtures.profile)
        #expect(curve.percentOfSteadyState(at: F.hour(-1)) == 0)
        #expect(curve.percentOfSteadyState(at: F.anchor) == 0)
        #expect(curve.percentOfSteadyState(at: F.hour(1)) > 0)
    }

    @Test("samples keep the given order and carry only a date and a percent")
    func samplesAreUnitFree() throws {
        let curve = try curve(F.tirzepatideShots, F.tirzepatideProfile)
        let dates = [F.hour(500), F.hour(24), F.hour(1_000)]
        let samples = curve.samples(at: dates)
        #expect(samples.map(\.date) == dates)
        #expect(samples.map(\.percentOfSteadyState) == dates.map { curve.percentOfSteadyState(at: $0) })
        let labels = Mirror(reflecting: samples[0]).children.compactMap(\.label)
        #expect(labels == ["date", "percentOfSteadyState"])
    }

    @Test("shots for another medication are ignored")
    func otherMedicationIgnored() throws {
        let other = ShotEventData(
            takenAt: DosePeriodFixtures.day(30), dose: Milligrams(10), medicationID: UUID()
        )
        let base = try curve(F.tirzepatideShots, F.tirzepatideProfile)
        let mixed = try curve(F.tirzepatideShots + [other], F.tirzepatideProfile)
        #expect(mixed.reference == base.reference)
        #expect(mixed.percentOfSteadyState(at: F.hour(800)) == base.percentOfSteadyState(at: F.hour(800)))
    }

    @Test("invalid inputs are reported, not turned into NaN")
    func invalidInputs() {
        let profile = MedicationProfileData(known: .semaglutide)
        let shot = ShotEventData(takenAt: F.anchor, dose: Milligrams(1), medicationID: profile.id)

        #expect(throws: ExposureCurveError.noShots) { try curve([], profile) }

        var bad = profile
        bad.halfLifeHours = 0
        #expect(throws: ExposureCurveError.invalidHalfLife) { try curve([shot], bad) }

        bad = profile
        bad.tmaxHours = profile.halfLifeHours / M_LN2
        #expect(throws: ExposureCurveError.invalidTmax) { try curve([shot], bad) }
        bad.tmaxHours = 0
        #expect(throws: ExposureCurveError.invalidTmax) { try curve([shot], bad) }

        bad = profile
        bad.intervalDays = 0
        #expect(throws: ExposureCurveError.invalidInterval) { try curve([shot], bad) }

        let zero = ShotEventData(takenAt: F.hour(1), dose: Milligrams(0), medicationID: profile.id)
        #expect(throws: ExposureCurveError.invalidDose) { try curve([shot, zero], profile) }
    }

    @Test(
        "tmax at halfLifeHours / ln 2 is rejected whichever way ke·tmax rounds",
        arguments: KnownMedication.allCases
    )
    func tmaxBoundRejected(known: KnownMedication) {
        var profile = MedicationProfileData(known: known)
        let shot = ShotEventData(takenAt: F.anchor, dose: Milligrams(1), medicationID: profile.id)
        let bound = profile.halfLifeHours / M_LN2
        for tmax in [bound, bound.nextDown, bound.nextUp] {
            profile.tmaxHours = tmax
            #expect(throws: ExposureCurveError.invalidTmax) { try curve([shot], profile) }
        }
    }
}
