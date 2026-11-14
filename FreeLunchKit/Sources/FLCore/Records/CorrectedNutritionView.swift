// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Replacement totals for a reconstructed day. Missing macros remain unknown.
public struct NutritionDayReplacement: Codable, Sendable, Hashable {
    public let kcal: Double
    public let proteinG: Double?
    public let carbsG: Double?
    public let fatG: Double?

    public init(energy: Kilocalories, protein: Grams? = nil, carbs: Grams? = nil, fat: Grams? = nil) {
        kcal = energy.value
        proteinG = protein?.value
        carbsG = carbs?.value
        fatG = fat?.value
    }

    public var isValid: Bool {
        [kcal, proteinG, carbsG, fatG].allSatisfy { $0 == nil || ($0!.isFinite && $0! >= 0) }
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
}

public struct ReconstructedNutritionDay: Sendable, Hashable {
    public let day: Date
    public let totals: NutritionDayReplacement
    public let correctionID: UUID?
}

public enum CorrectedNutritionView {
    /// Civil Gregorian date in the caller's time zone, independent of UTC offsets.
    public static func dayKey(_ day: Date, calendar: Calendar) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let c = gregorian.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func isValidDayKey(_ key: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: key) else { return false }
        return formatter.string(from: date) == key
    }

    public static func derive(samples: [DietarySampleData], corrections: [CorrectionData],
                              ownSourceBundleID: String, calendar: Calendar) -> [ReconstructedNutritionDay] {
        let groups = Dictionary(grouping: samples.filter { !$0.deletedInHK && $0.sourceBundleID != ownSourceBundleID }) {
            calendar.startOfDay(for: $0.date)
        }
        return groups.keys.sorted().compactMap { day in
            let rows = groups[day]!
            let key = dayKey(day, calendar: calendar)
            let correction = corrections.filter {
                $0.targetKind == .hkNutritionDay && $0.targetID == key &&
                ($0.action == .exclude || $0.replacement.flatMap { try? NutritionDayReplacement.decode($0) }?.isValid == true)
            }.max {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
            }
            if correction?.action == .exclude { return nil }
            if let correction, let data = correction.replacement,
               let totals = try? NutritionDayReplacement.decode(data) {
                return ReconstructedNutritionDay(day: day, totals: totals, correctionID: correction.id)
            }
            func sum(_ values: [Double?]) -> Grams? {
                guard values.allSatisfy({ $0 != nil }) else { return nil }
                return try? Grams(validating: values.compactMap { $0 }.reduce(0, +))
            }
            guard let energy = try? Kilocalories(validating: rows.reduce(0) { $0 + $1.kcal }) else { return nil }
            return ReconstructedNutritionDay(day: day, totals: NutritionDayReplacement(
                energy: energy, protein: sum(rows.map(\.proteinG)), carbs: sum(rows.map(\.carbsG)),
                fat: sum(rows.map(\.fatG))), correctionID: nil)
        }
    }
}
