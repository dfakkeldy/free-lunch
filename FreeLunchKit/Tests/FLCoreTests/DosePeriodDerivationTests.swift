// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §1 acceptance #8: a synthetic shot history with two strength changes
// yields periods whose total change, duration, weekly rate, injection count
// and coverage match golden vectors worked by hand (exact fractions):
//
//   period   dose   days     shots  duration  expected  coverage  change   weekly
//   1        0.25   0..28    4      28        4         1         -3.0     -3/4
//   2        0.50   28..63   4      35        5         4/5       -2.5     -1/2
//   3 open   1.00   63..84   4      21        3         4/3       -1.25    -5/12
import FLCore
import FLFixtures
import Foundation
import Testing

private typealias F = DosePeriodFixtures

private func shot(_ n: Int, day: Double, mg: Double, medication: UUID = F.medicationID) -> ShotEventData {
    ShotEventData(id: F.uuid(n), takenAt: F.day(day), dose: Milligrams(mg), medicationID: medication)
}

@Suite("Dose-strength period derivation")
struct DosePeriodDerivationTests {
    private func goldenPeriods() -> [DosePeriod] {
        DosePeriodDerivation.periods(
            shots: F.shots,
            profiles: [F.profile],
            asOf: F.asOf,
            trendKg: F.trendKg(at:)
        )
    }

    @Test("two strength changes give three periods with golden boundaries")
    func goldenBoundaries() {
        let periods = goldenPeriods()
        #expect(periods.count == 3)
        #expect(periods.map(\.doseMg) == [0.25, 0.5, 1.0])
        #expect(periods.map(\.start) == [F.day(0), F.day(28), F.day(63)])
        #expect(periods.map(\.end) == [F.day(28), F.day(63), F.day(84)])
        #expect(periods.map(\.isOpen) == [false, false, true])
        #expect(periods.map(\.medicationID) == [F.medicationID, F.medicationID, F.medicationID])
        #expect(periods.map(\.shotIDs) == [
            [F.uuid(1), F.uuid(2), F.uuid(3), F.uuid(4)],
            [F.uuid(5), F.uuid(6), F.uuid(7), F.uuid(8)],
            [F.uuid(9), F.uuid(10), F.uuid(11), F.uuid(12)]
        ])
    }

    @Test("injection count and duration")
    func countAndDuration() {
        let periods = goldenPeriods()
        #expect(periods.map(\.injectionCount) == [4, 4, 4])
        #expect(periods.map(\.durationDays) == [28, 35, 21])
        #expect(periods.map(\.intervalDays) == [7, 7, 7])
    }

    @Test("coverage = logged / expected, uncapped")
    func coverage() {
        let periods = goldenPeriods()
        #expect(periods.map(\.expectedInjections) == [4, 5, 3])
        #expect(periods[0].coverage == 1)
        #expect(isClose(periods[1].coverage, 0.8))
        #expect(isClose(periods[2].coverage, 4.0 / 3.0))
        #expect((periods[2].coverage ?? 0) > 1)
    }

    @Test("total trend change and weekly rate")
    func changeAndWeeklyRate() {
        let periods = goldenPeriods()
        #expect(periods.map(\.trendAtStartKg) == [104.0, 101.0, 98.5])
        #expect(periods.map(\.trendAtEndKg) == [101.0, 98.5, 97.25])
        #expect(periods.map(\.totalChangeKg) == [-3.0, -2.5, -1.25])
        #expect(isClose(periods[0].weeklyRateKg, -0.75))
        #expect(isClose(periods[1].weeklyRateKg, -0.5))
        #expect(isClose(periods[2].weeklyRateKg, -5.0 / 12.0))
    }

    @Test("input order does not matter")
    func orderIndependent() {
        let reversed = Array(F.shots.reversed())
        let rotated = Array(F.shots[5...] + F.shots[..<5])
        for shots in [reversed, rotated] {
            let periods = DosePeriodDerivation.periods(
                shots: shots,
                profiles: [F.profile],
                asOf: F.asOf,
                trendKg: F.trendKg(at:)
            )
            #expect(periods == goldenPeriods())
        }
    }

    @Test("without a trend, change and weekly rate are nil but the rest stands")
    func noTrend() {
        let periods = DosePeriodDerivation.periods(shots: F.shots, profiles: [F.profile], asOf: F.asOf)
        #expect(periods.map(\.totalChangeKg) == [nil, nil, nil])
        #expect(periods.map(\.weeklyRateKg) == [nil, nil, nil])
        #expect(periods.map(\.injectionCount) == [4, 4, 4])
        #expect(periods[0].coverage == 1)
    }

    @Test("a trend missing at one boundary leaves only that period's change nil")
    func partialTrend() {
        let periods = DosePeriodDerivation.periods(
            shots: F.shots,
            profiles: [F.profile],
            asOf: F.day(85),
            trendKg: F.trendKg(at:)
        )
        #expect(periods.map(\.totalChangeKg) == [-3.0, -2.5, nil])
        #expect(periods[2].durationDays == 22)
    }

    @Test("no shots, no periods")
    func empty() {
        #expect(DosePeriodDerivation.periods(shots: [], profiles: [F.profile], asOf: F.asOf).isEmpty)
    }

    @Test("returning to an earlier dose starts a new period")
    func returnToEarlierDose() {
        let shots = [
            shot(1, day: 0, mg: 0.5), shot(2, day: 7, mg: 0.5),
            shot(3, day: 14, mg: 1.0),
            shot(4, day: 21, mg: 0.5), shot(5, day: 28, mg: 0.5)
        ]
        let periods = DosePeriodDerivation.periods(shots: shots, profiles: [F.profile], asOf: F.day(35))
        #expect(periods.map(\.doseMg) == [0.5, 1.0, 0.5])
        #expect(periods.map(\.injectionCount) == [2, 1, 2])
        #expect(periods.map(\.durationDays) == [14, 7, 14])
        #expect(periods.map(\.coverage) == [1, 1, 1])
    }

    @Test("a medication change at the same dose starts a new period")
    func medicationChange() {
        let other = MedicationProfileData(id: F.uuid(901), known: .tirzepatide, intervalDays: 14)
        let shots = [
            shot(1, day: 0, mg: 2.5), shot(2, day: 7, mg: 2.5),
            shot(3, day: 14, mg: 2.5, medication: other.id)
        ]
        let periods = DosePeriodDerivation.periods(shots: shots, profiles: [F.profile, other], asOf: F.day(42))
        #expect(periods.map(\.medicationID) == [F.medicationID, other.id])
        #expect(periods.map(\.intervalDays) == [7, 14])
        #expect(periods.map(\.durationDays) == [14, 28])
        #expect(periods.map(\.expectedInjections) == [2, 2])
        #expect(periods.map(\.coverage) == [1, 0.5])
    }

    @Test("doses compare at microgram resolution")
    func microgramResolution() throws {
        let fromMicrograms = try ShotEventData(
            id: F.uuid(2),
            takenAt: F.day(7),
            dose: Measurement(value: 500, unit: UnitMass.micrograms),
            medicationID: F.medicationID
        )
        let periods = DosePeriodDerivation.periods(
            shots: [shot(1, day: 0, mg: 0.5), fromMicrograms],
            profiles: [F.profile],
            asOf: F.day(14)
        )
        #expect(periods.count == 1)
        #expect(periods[0].injectionCount == 2)
    }

    @Test("two different doses too large to scale to micrograms stay distinct")
    func hugeDosesDoNotOverflowIntoOnePeriod() {
        let periods = DosePeriodDerivation.periods(
            shots: [shot(1, day: 0, mg: 1e306), shot(2, day: 7, mg: 2e306)],
            profiles: [F.profile],
            asOf: F.day(14)
        )
        #expect(periods.count == 2)
    }

    @Test("an unknown medication profile leaves expected and coverage nil")
    func unknownProfile() {
        let periods = DosePeriodDerivation.periods(shots: F.shots, profiles: [], asOf: F.asOf)
        #expect(periods.count == 3)
        #expect(periods.map(\.intervalDays) == [nil, nil, nil])
        #expect(periods.map(\.expectedInjections) == [nil, nil, nil])
        #expect(periods.map(\.coverage) == [nil, nil, nil])
        #expect(periods.map(\.injectionCount) == [4, 4, 4])
    }

    @Test("a single shot logged right now has no length, so no coverage or rate")
    func zeroLengthPeriod() {
        let periods = DosePeriodDerivation.periods(
            shots: [shot(1, day: 0, mg: 0.25)],
            profiles: [F.profile],
            asOf: F.day(0),
            trendKg: F.trendKg(at:)
        )
        #expect(periods.count == 1)
        #expect(periods[0].durationDays == 0)
        #expect(periods[0].expectedInjections == 0)
        #expect(periods[0].coverage == nil)
        #expect(periods[0].totalChangeKg == 0)
        #expect(periods[0].weeklyRateKg == nil)
    }

    @Test("asOf before the last shot extends the open period to that shot")
    func asOfBeforeLastShot() {
        let periods = DosePeriodDerivation.periods(shots: F.shots, profiles: [F.profile], asOf: F.day(70))
        #expect(periods[2].end == F.day(81))
        #expect(periods[2].durationDays == 18)
        #expect(periods[2].injectionCount == 4)
    }
}
