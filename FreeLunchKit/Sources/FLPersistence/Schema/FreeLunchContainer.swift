// SPDX-License-Identifier: GPL-3.0-or-later
// Container factory — module-internal. `ModelContainer` exposes bulk
// erase/delete-all, which would bypass every integrity rule the store
// enforces, so `ModelContainer` never appears in a public signature of this
// module. Public construction goes through `SwiftDataStore.phone(at:)`,
// `.watch(at:)` and `init(kind:at:)`.
//
// Every container is built through `FreeLunchMigrationPlan` (spec §1
// acceptance #6), never `ModelContainer(for:)` alone.
import Foundation
import SwiftData

/// Which device's store to open. Distinct store files: the phone keeps full
/// history, the watch a pruned working set (spec §1 store shape).
public enum FreeLunchStoreKind: String, Sendable, CaseIterable {
    case phone
    case watch

    /// Configuration name and default store filename stem.
    public var storeName: String {
        switch self {
        case .phone: "FreeLunch-phone"
        case .watch: "FreeLunch-watch"
        }
    }
}

/// Where the store lives.
public enum FreeLunchStoreLocation: Sendable {
    /// Application Support/FreeLunch/<storeName>.store.
    case applicationDefault
    /// An explicit file URL (cold reloads of the same store in tests;
    /// future export tooling).
    case file(URL)
    /// No file. Tests only.
    case inMemory
}

public enum FreeLunchContainerError: Error, Equatable, Sendable {
    /// Application Support was unavailable or its FreeLunch subdirectory
    /// could not be created.
    case defaultStoreDirectoryUnavailable
}

enum FreeLunchContainer {
    static func make(
        _ kind: FreeLunchStoreKind,
        at location: FreeLunchStoreLocation = .applicationDefault
    ) throws -> ModelContainer {
        let schema = Schema(versionedSchema: FreeLunchSchemaCurrent.self)
        let configuration: ModelConfiguration
        switch location {
        case .inMemory:
            configuration = ModelConfiguration(kind.storeName, schema: schema, isStoredInMemoryOnly: true)
        case .file(let url):
            configuration = ModelConfiguration(kind.storeName, schema: schema, url: url)
        case .applicationDefault:
            let url = try defaultStoreURL(for: kind)
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                throw FreeLunchContainerError.defaultStoreDirectoryUnavailable
            }
            configuration = ModelConfiguration(kind.storeName, schema: schema, url: url)
        }
        return try ModelContainer(
            for: schema,
            migrationPlan: FreeLunchMigrationPlan.self,
            configurations: configuration
        )
    }

    /// Pure: computes the path and touches nothing on disk.
    static func defaultStoreURL(for kind: FreeLunchStoreKind) throws -> URL {
        guard
            let support = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        else {
            throw FreeLunchContainerError.defaultStoreDirectoryUnavailable
        }
        return support
            .appending(path: "FreeLunch", directoryHint: .isDirectory)
            .appending(path: "\(kind.storeName).store", directoryHint: .notDirectory)
    }
}
