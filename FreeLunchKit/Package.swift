// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

// Every v1 target is declared here up front so feature tasks add files,
// not targets. Dependency edges are the architecture: FLEnergyCore stays
// dependency-free (pure math over plain values, golden-vector tested), and
// FLPersistence is the only target that knows about SwiftData.
let package = Package(
    name: "FreeLunchKit",
    platforms: [
        .iOS(.v26),
        .watchOS(.v26),
        // Not a shipping target. Declared so `swift test` on the host has a
        // deployment target new enough for SwiftData; kept level with the
        // iOS/watchOS floor so no macOS-only availability drift creeps in.
        .macOS(.v26)
    ],
    products: [
        .library(name: "FLCore", targets: ["FLCore"]),
        .library(name: "FLEnergyCore", targets: ["FLEnergyCore"]),
        .library(name: "FLPlate", targets: ["FLPlate"]),
        .library(name: "FLPersistence", targets: ["FLPersistence"]),
        .library(name: "FLFixtures", targets: ["FLFixtures"])
    ],
    targets: [
        // §1 domain value types, enums and canonical units. No SwiftData.
        .target(name: "FLCore"),
        // §3 energy-balance engine. Deliberately dependency-free: it speaks
        // dates, kilograms and kcal only, so it can be verified in isolation.
        .target(name: "FLEnergyCore"),
        // §2 plate logic: typeahead, scale-session math, AI capture core.
        .target(name: "FLPlate", dependencies: ["FLCore"]),
        // §1 schema (FreeLunchSchemaV1) and the store boundary.
        .target(name: "FLPersistence", dependencies: ["FLCore", "FLEnergyCore"]),
        // Synthetic fixtures only. Real health data never enters this repo.
        .target(name: "FLFixtures", dependencies: ["FLCore"]),

        .testTarget(name: "FLCoreTests", dependencies: ["FLCore", "FLFixtures"]),
        .testTarget(name: "FLEnergyCoreTests", dependencies: ["FLEnergyCore"]),
        .testTarget(name: "FLPlateTests", dependencies: ["FLPlate", "FLFixtures"]),
        .testTarget(name: "FLPersistenceTests", dependencies: ["FLPersistence", "FLFixtures"]),
        .testTarget(name: "FLFixturesTests", dependencies: ["FLFixtures"])
    ]
)
