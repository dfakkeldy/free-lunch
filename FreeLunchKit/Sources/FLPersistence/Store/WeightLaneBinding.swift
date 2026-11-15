// SPDX-License-Identifier: GPL-3.0-or-later
import FLEnergyCore

public enum WeightLaneBinding {
    /// Reads the corrected samples and persisted smoothing used by the engine's
    /// default weights source. A coordinator with an injected source may differ.
    @MainActor
    public static func series(store: some WeightStore & EnergySettingsStore) throws -> WeightLaneSeries {
        let smoothing = try store.energySettings().smoothing
        return WeightLaneSeries(series: try EnergyBinding.trendSeries(store: store, smoothing: smoothing))
    }
}
