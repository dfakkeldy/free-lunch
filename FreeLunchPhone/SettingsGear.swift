// SPDX-License-Identifier: GPL-3.0-or-later
// The one settings gear every tab shares: a leading navigation-bar button
// that presents `SettingsSheet`. It is attached to each tab's root content,
// the view carrying that screen's title, so pushed screens never inherit it.
import SwiftUI

struct SettingsGear: ViewModifier {
    @State private var isShowingSettings = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                        .accessibilityIdentifier("nav.settings")
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsSheet()
            }
    }
}

extension View {
    /// Puts the settings gear on this screen's navigation bar and presents
    /// the settings sheet from it.
    func settingsGear() -> some View {
        modifier(SettingsGear())
    }
}
