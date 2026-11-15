// SPDX-License-Identifier: GPL-3.0-or-later
import FLCore
import Foundation
import WidgetKit

@MainActor
final class ComplicationBridge {
    private let defaults = UserDefaults(suiteName: NextDoseComplicationConfiguration.appGroup)!
    private let key = NextDoseComplicationConfiguration.stateKey
    private var state: NextDoseComplicationState

    init() {
        let data = defaults.data(forKey: key)
        state = data.flatMap { try? JSONDecoder().decode(NextDoseComplicationState.self, from: $0) } ?? .init()
    }

    func shotLogged(at date: Date) {
        var needsReload = false
        state.shotLogged(at: date, calendar: .current) { needsReload = true }
        save()
        if needsReload { reload() }
    }

    func digestApplied(_ digest: WatchDigestData) {
        var needsReload = false
        state.digestApplied(digest) { needsReload = true }
        save()
        if needsReload { reload() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
    }

    private func reload() {
        WidgetCenter.shared.reloadTimelines(ofKind: NextDoseComplicationConfiguration.kind)
    }
}
