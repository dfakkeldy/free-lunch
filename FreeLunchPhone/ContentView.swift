// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "fork.knife")
                .font(.largeTitle)
                .accessibilityHidden(true)

            Text("Nothing logged yet")
                .font(.title3)
                .accessibilityIdentifier("phone.emptyState.heading")

            Text("Your plate will show up here.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
