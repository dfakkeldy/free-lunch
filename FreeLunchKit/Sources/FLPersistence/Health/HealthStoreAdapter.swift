// SPDX-License-Identifier: GPL-3.0-or-later
// The protocol in front of Apple Health (spec §1 Weight, §6, §11). Every
// HealthKit type stays behind it, so the sync and weigh-in logic runs on the
// package's macOS test host against a mock store. `HealthKitStoreAdapter` is
// the real implementation.
import FLCore
import Foundation

/// Apple Health, as Free Lunch uses it. Only the phone builds one: the phone
/// is Free Lunch's sole HealthKit writer (spec §9), and the watch app doesn't
/// link this module.
///
/// Implementations report a missing device capability or denied access by
/// throwing `HealthAccessError`; callers turn that into a degraded state.
@MainActor
public protocol HealthStoreAdapter: AnyObject {
    /// False on devices without Health data (some iPads, the Mac).
    var isHealthDataAvailable: Bool { get }

    /// The bundle identifier Apple Health records as the source of the
    /// samples `saveWeight` writes. The one definition of "this app's own".
    var ownSourceBundleID: String { get }

    /// Write access to `type`. Read access is not observable.
    func authorizationStatus(for type: HealthDataType) -> HealthAuthorizationStatus

    /// Whether `requestAuthorization` with these types would show the sheet.
    func authorizationRequestStatus(
        toShare: Set<HealthDataType>,
        read: Set<HealthDataType>
    ) async throws -> HealthAuthorizationRequestStatus

    /// Shows the system sheet for any type not yet asked about. Returns
    /// without saying what the user chose (HealthKit doesn't).
    func requestAuthorization(toShare: Set<HealthDataType>, read: Set<HealthDataType>) async throws

    // MARK: Weight (body mass)

    /// Weight samples added and deleted after `anchor`, at most `limit` per
    /// page. A nil anchor starts at the beginning of the user's history.
    /// A sample that can't be expressed as a weight is counted in
    /// `unreadable` rather than dropped silently.
    func weightChanges(after anchor: HealthQueryAnchor?, limit: Int) async throws -> HealthWeightChanges

    /// Saves one body-mass sample and returns it as Apple Health stored it:
    /// its HealthKit UUID and this app as the source.
    func saveWeight(_ weight: Kilograms, at date: Date) async throws -> WeightSampleData

    /// Deletes a sample this app wrote. Returns quietly if the sample is
    /// already gone; throws `FreeLunchStoreError.importedRecordImmutable` if
    /// it exists under another source, which HealthKit won't delete.
    func deleteWeight(hkUUID: UUID) async throws
}
