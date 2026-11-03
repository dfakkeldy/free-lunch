// SPDX-License-Identifier: GPL-3.0-or-later
// The settings sheet behind every tab's gear. Settings is never a tab: a
// placeholder until the settings section is built, when settings, data,
// export and import land here.
import SwiftUI

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Text("Settings, data, export and import will live here.")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("settings.sheet")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings.done")
                }
            }
        }
    }
}
