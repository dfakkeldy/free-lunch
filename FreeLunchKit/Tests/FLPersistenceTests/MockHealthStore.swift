// SPDX-License-Identifier: GPL-3.0-or-later
// A synthetic Apple Health for the Health adapter suites, and a weight store
// that records its writes into the same ordered log, so a test can read the
// order in which Apple Health and the mirror were touched. Every value is
// synthetic.
import FLCore
import Foundation
@testable import FLPersistence

/// The ordered record of every call either side received.
@MainActor
final class CallLog {
    private(set) var entries: [String] = []

    func record(_ entry: String) {
        entries.append(entry)
    }
}

/// The source bundle the mock gives samples this "app" saves.
let ownBundleID = "org.example.freelunch-tests"
/// A third-party source, such as a smart scale's app.
let scaleBundleID = "org.example.scale"

/// Apple Health in memory: a change journal for anchored queries, write
/// access per type, and switches for each degraded state.
@MainActor
final class MockHealthStore: HealthStoreAdapter {
    private enum Change {
        case added(WeightSampleData)
        case deleted(UUID)
    }

    let log: CallLog
    var isHealthDataAvailable = true
    var sharing: [HealthDataType: HealthAuthorizationStatus] = [.bodyMass: .sharingAuthorized]
    var requestStatus: HealthAuthorizationRequestStatus = .shouldRequest
    /// A denied read: HealthKit returns no samples rather than an error.
    var readDenied = false
    /// Thrown by the next anchored query, then cleared.
    var queryError: (any Error)?
    /// Thrown by the next save, then cleared.
    var saveError: (any Error)?
    /// Thrown by the next delete, then cleared.
    var deleteError: (any Error)?
    /// Runs inside `saveWeight` after the sample is in "Apple Health" and
    /// before the call returns.
    var onSave: ((WeightSampleData) throws -> Void)?

    /// Every anchor an anchored query was given, in order.
    private(set) var queriedAnchors: [HealthQueryAnchor?] = []
    private(set) var requestedAuthorization: [(share: Set<HealthDataType>, read: Set<HealthDataType>)] = []

    private var journal: [Change] = []
    private var nextUUID = 70_000

    init(log: CallLog = CallLog()) {
        self.log = log
    }

    /// Samples currently in "Apple Health".
    var liveSamples: [WeightSampleData] {
        var live: [UUID: WeightSampleData] = [:]
        for change in journal {
            switch change {
            case .added(let sample): live[sample.hkUUID] = sample
            case .deleted(let id): live[id] = nil
            }
        }
        return live.values.sorted { $0.measuredAt < $1.measuredAt }
    }

    /// Another app (or this one, earlier) adds a sample.
    func seed(_ sample: WeightSampleData) {
        journal.append(.added(sample))
    }

    /// Another app deletes a sample.
    func externalDelete(_ hkUUID: UUID) {
        journal.append(.deleted(hkUUID))
    }

    static func anchor(_ position: Int) -> HealthQueryAnchor {
        HealthQueryAnchor(data: Data("anchor-\(position)".utf8))
    }

    private static func position(of anchor: HealthQueryAnchor?) -> Int {
        guard let anchor else { return 0 }
        return Int(String(decoding: anchor.data, as: UTF8.self).dropFirst("anchor-".count))!
    }

    // MARK: HealthStoreAdapter

    func authorizationStatus(for type: HealthDataType) -> HealthAuthorizationStatus {
        isHealthDataAvailable ? sharing[type] ?? .notDetermined : .unavailable
    }

    func authorizationRequestStatus(
        toShare: Set<HealthDataType>,
        read: Set<HealthDataType>
    ) async throws -> HealthAuthorizationRequestStatus {
        requestStatus
    }

    func requestAuthorization(toShare: Set<HealthDataType>, read: Set<HealthDataType>) async throws {
        log.record("hk.requestAuthorization")
        requestedAuthorization.append((toShare, read))
    }

    func weightChanges(after anchor: HealthQueryAnchor?, limit: Int) async throws -> HealthWeightChanges {
        log.record("hk.query")
        queriedAnchors.append(anchor)
        if let error = queryError {
            queryError = nil
            throw error
        }
        let start = Self.position(of: anchor)
        let page = journal.dropFirst(start).prefix(limit)
        let end = start + page.count
        var added: [WeightSampleData] = []
        var deleted: [UUID] = []
        for change in page {
            switch change {
            case .added(let sample):
                // Only this app's own samples are visible when reads are denied.
                if !readDenied || sample.sourceBundleID == ownBundleID { added.append(sample) }
            case .deleted(let id):
                if !readDenied { deleted.append(id) }
            }
        }
        return HealthWeightChanges(added: added, deleted: deleted, anchor: Self.anchor(end))
    }

    func saveWeight(_ weight: Kilograms, at date: Date) async throws -> WeightSampleData {
        log.record("hk.save")
        if let error = saveError {
            saveError = nil
            throw error
        }
        nextUUID += 1
        let sample = WeightSampleData(
            hkUUID: uid(nextUUID),
            measuredAt: date,
            weight: weight,
            sourceBundleID: ownBundleID
        )
        journal.append(.added(sample))
        try onSave?(sample)
        return sample
    }

    func deleteWeight(hkUUID: UUID) async throws {
        log.record("hk.delete")
        if let error = deleteError {
            deleteError = nil
            throw error
        }
        journal.append(.deleted(hkUUID))
    }
}

/// Forwards to a real store and records each mirror write in the shared log.
@MainActor
final class RecordingWeightStore: WeightStore {
    let base: SwiftDataStore
    let log: CallLog
    /// Thrown by the next upsert, then cleared.
    var upsertError: (any Error)?

    init(base: SwiftDataStore, log: CallLog) {
        self.base = base
        self.log = log
    }

    func upsertWeightSample(_ sample: WeightSampleData) throws {
        log.record("mirror.upsert")
        if let error = upsertError {
            upsertError = nil
            throw error
        }
        try base.upsertWeightSample(sample)
    }

    func markWeightSampleDeletedInHK(hkUUID: UUID) throws {
        log.record("mirror.markDeleted")
        try base.markWeightSampleDeletedInHK(hkUUID: hkUUID)
    }

    func weightSamples(includingDeletedInHK: Bool) throws -> [WeightSampleData] {
        try base.weightSamples(includingDeletedInHK: includingDeletedInHK)
    }

    func addCorrection(_ correction: CorrectionData) throws {
        try base.addCorrection(correction)
    }

    func corrections(targetKind: CorrectionTargetKind?) throws -> [CorrectionData] {
        try base.corrections(targetKind: targetKind)
    }

    func deleteCorrection(id: UUID) throws {
        try base.deleteCorrection(id: id)
    }

    func correctedWeightView() throws -> [CorrectedWeightSample] {
        try base.correctedWeightView()
    }
}

/// An anchor store in memory.
@MainActor
final class MemoryAnchorStore: HealthAnchorStore {
    private var anchors: [HealthDataType: HealthQueryAnchor] = [:]

    func anchor(for type: HealthDataType) -> HealthQueryAnchor? {
        anchors[type]
    }

    func setAnchor(_ anchor: HealthQueryAnchor?, for type: HealthDataType) {
        anchors[type] = anchor
    }
}

/// One synthetic body-mass sample.
func healthWeight(_ number: Int, day: Double, kilograms: Double, source: String = scaleBundleID) -> WeightSampleData {
    WeightSampleData(
        hkUUID: uid(number),
        measuredAt: at(day: day),
        weight: Kilograms(kilograms),
        sourceBundleID: source
    )
}

/// The pieces of one Health adapter test: a mock Apple Health, a recording
/// store over a real in-memory store, and the service under test.
@MainActor
struct HealthHarness {
    let log: CallLog
    let health: MockHealthStore
    let store: SwiftDataStore
    let weights: RecordingWeightStore
    let anchors: any HealthAnchorStore
    let sync: HealthWeightSync

    init(pageLimit: Int = HealthWeightSync.defaultPageLimit, anchors: (any HealthAnchorStore)? = nil) throws {
        log = CallLog()
        health = MockHealthStore(log: log)
        store = try makeInMemoryStore()
        weights = RecordingWeightStore(base: store, log: log)
        self.anchors = anchors ?? MemoryAnchorStore()
        sync = HealthWeightSync(
            health: health,
            weights: weights,
            anchors: self.anchors,
            ownSourceBundleID: ownBundleID,
            pageLimit: pageLimit
        )
    }

    func mirror(includingDeleted: Bool = true) throws -> [WeightSampleData] {
        try store.weightSamples(includingDeletedInHK: includingDeleted)
    }
}
