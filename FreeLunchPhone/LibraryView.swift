// SPDX-License-Identifier: GPL-3.0-or-later
// The Library tab: the four collections the app holds, each a placeholder
// screen until its section is built (spec §7).
import SwiftUI

/// The four collections, in the order the list shows them.
enum LibrarySection: String, CaseIterable, Identifiable, Hashable {
    case foods = "Foods"
    case recipes = "Recipes"
    case formulas = "Formulas"
    case medications = "Medications"

    var id: String { rawValue }

    var title: String { rawValue }

    var systemImage: String {
        switch self {
        case .foods: "fork.knife"
        case .recipes: "book"
        case .formulas: "function"
        case .medications: "pills"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .foods: "library.foods"
        case .recipes: "library.recipes"
        case .formulas: "library.formulas"
        case .medications: "library.medications"
        }
    }
}

struct LibraryView: View {
    var body: some View {
        NavigationStack {
            List(LibrarySection.allCases) { section in
                NavigationLink {
                    LibrarySectionPlaceholder(section: section)
                } label: {
                    Label(section.title, systemImage: section.systemImage)
                }
                .accessibilityIdentifier(section.accessibilityIdentifier)
            }
            .navigationTitle("Library")
            .settingsGear()
        }
    }
}

/// One collection's placeholder. The gear stays on the Library root, so this
/// screen carries only the back button.
private struct LibrarySectionPlaceholder: View {
    let section: LibrarySection

    var body: some View {
        ContentUnavailableView(
            "Not built yet",
            systemImage: section.systemImage,
            description: Text("\(section.title) will live here.")
        )
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
