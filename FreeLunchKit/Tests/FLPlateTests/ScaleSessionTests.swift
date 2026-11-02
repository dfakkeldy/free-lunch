// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import FLPlate

@Suite("Scale sessions")
struct ScaleSessionTests {
    @Test("Cumulative readings become exact per-item grams")
    func cumulativeReadings() throws {
        var session = ScaleSession(mode: .cumulative)

        for reading in [120, 275.5, 275.5, 410, 1_000] {
            try session.record(reading: reading)
        }

        #expect(session.items == [.init(120), .init(155.5), .init(0), .init(134.5), .init(590)])
        #expect(session.lastCumulativeReading == 1_000)
        #expect(session.items.count == 5)
    }

    @Test("Cumulative fractional readings are quantized to the scale resolution")
    func cumulativeFractionalReadings() throws {
        var session = ScaleSession(mode: .cumulative)

        for reading in [100.1, 200.3, 412.7] {
            try session.record(reading: reading)
        }

        #expect(session.items == [.init(100.1), .init(100.2), .init(212.4)])
    }

    @Test("Cumulative negative deltas do not persist")
    func cumulativeNegativeDelta() throws {
        var session = ScaleSession(mode: .cumulative)
        try session.record(reading: 120)
        try session.record(reading: 300)
        let beforeRejectedReading = session

        #expect(throws: ScaleSessionError.negativeDelta(reading: 250, previous: 300)) {
            try session.record(reading: 250)
        }
        #expect(session == beforeRejectedReading)
        #expect(session.items == [.init(120), .init(180)])
        #expect(session.lastCumulativeReading == 300)

        #expect(throws: ScaleSessionError.negativeDelta(reading: 250, previous: 300)) {
            try session.grams(forReading: 250)
        }
        #expect(session == beforeRejectedReading)

        let item = try session.record(reading: 310)
        #expect(item == .init(10))
    }

    @Test("Cumulative sessions allow a zero first reading but reject negative readings")
    func cumulativeZeroAndNegativeFirstReadings() throws {
        var zeroSession = ScaleSession(mode: .cumulative)
        let item = try zeroSession.record(reading: 0)
        #expect(item == .init(0))
        #expect(zeroSession.items == [.init(0)])
        #expect(zeroSession.lastCumulativeReading == 0)

        var negativeSession = ScaleSession(mode: .cumulative)
        let beforeNegativeReading = negativeSession
        #expect(throws: ScaleSessionError.negativeReading(-1)) {
            try negativeSession.record(reading: -1)
        }
        #expect(negativeSession == beforeNegativeReading)
        #expect(negativeSession.items.isEmpty)
    }

    @Test("Tared readings are item grams regardless of order")
    func taredReadings() throws {
        var session = ScaleSession(mode: .tared)

        for reading in [50, 30.5, 200, 10] {
            try session.record(reading: reading)
        }

        #expect(session.items == [.init(50), .init(30.5), .init(200), .init(10)])
        #expect(session.lastCumulativeReading == 0)
    }

    @Test("Tared sessions reject negative and non-finite readings without mutation")
    func taredInvalidReadings() {
        var negativeSession = ScaleSession(mode: .tared)
        let beforeNegativeReading = negativeSession
        #expect(throws: ScaleSessionError.negativeReading(-0.5)) {
            try negativeSession.record(reading: -0.5)
        }
        #expect(negativeSession == beforeNegativeReading)

        assertNonFiniteReadingsLeaveSessionUnchanged(mode: .tared)
    }

    @Test("Cumulative sessions reject non-finite readings without mutation")
    func cumulativeNonFiniteReadings() {
        assertNonFiniteReadingsLeaveSessionUnchanged(mode: .cumulative)
    }

    @Test("Equivalent tared and cumulative weighings fill the same plate")
    func equivalentWeighings() throws {
        var tared = ScaleSession(mode: .tared)
        for reading in [120, 155.5, 134.5] {
            try tared.record(reading: reading)
        }

        var cumulative = ScaleSession(mode: .cumulative)
        for reading in [120, 275.5, 410] {
            try cumulative.record(reading: reading)
        }

        #expect(tared.items == cumulative.items)
    }

    @Test("Tared and cumulative fractional weighings produce identical items")
    func equivalentFractionalWeighings() throws {
        var tared = ScaleSession(mode: .tared)
        for reading in [100.1, 100.2, 212.4] {
            try tared.record(reading: reading)
        }

        var cumulative = ScaleSession(mode: .cumulative)
        for reading in [100.1, 200.3, 412.7] {
            try cumulative.record(reading: reading)
        }

        #expect(tared.items == cumulative.items)
    }

    private func assertNonFiniteReadingsLeaveSessionUnchanged(mode: ScaleSessionMode) {
        for reading in [Double.nan, Double.infinity] {
            var session = ScaleSession(mode: mode)
            let beforeInvalidReading = session

            do {
                try session.record(reading: reading)
                #expect(Bool(false))
            } catch let error {
                if case .notFinite = error {
                    #expect(session == beforeInvalidReading)
                } else {
                    #expect(Bool(false))
                }
            }
        }
    }
}
