// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The phone's root: the timeline stand-in, which owns the way into the
/// plate screen (spec §2). The empty state lives in `TimelineStubView`.
struct ContentView: View {
    @State private var model = PhoneAppModel()

    var body: some View {
        TimelineStubView(model: model)
    }
}
