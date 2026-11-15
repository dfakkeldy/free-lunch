// SPDX-License-Identifier: GPL-3.0-or-later
import FLEnergyCore

public enum WeightLaneBinding {
    /// Reads the same corrected samples and persisted smoothing as the energy engine.
    @MainActor
    public static func series(store: some WeightStore & EnergySettingsStore) throws -> WeightLaneSeries {
        let smoothing = try store.energySettings().smoothing
        return WeightLaneSeries(series: try EnergyBinding.trendSeries(store: store, smoothing: smoothing))
    }
}
