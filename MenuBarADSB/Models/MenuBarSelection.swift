import Foundation

nonisolated enum MenuBarSelection: String, CaseIterable, Codable, Sendable {
    case closest
    case highestAltitude
    case lowestAltitude
    case fastest

    var label: String {
        switch self {
        case .closest:          return String(localized: "Closest")
        case .highestAltitude:  return String(localized: "Highest altitude")
        case .lowestAltitude:   return String(localized: "Lowest altitude")
        case .fastest:          return String(localized: "Fastest")
        }
    }

    /// Returns the aircraft to feature in the menu bar label.
    /// Assumes `aircraft` is already sorted by ascending distance (the closest first).
    /// For altitude/speed modes: aircraft missing the relevant field are skipped.
    /// If no aircraft has the relevant field, falls back to the closest.
    func selectFeatured(from aircraft: [Aircraft]) -> Aircraft? {
        guard !aircraft.isEmpty else { return nil }
        switch self {
        case .closest:
            return aircraft.first
        case .highestAltitude:
            let withAlt = aircraft.filter { $0.altitudeFt != nil }
            return withAlt.max { ($0.altitudeFt ?? 0) < ($1.altitudeFt ?? 0) } ?? aircraft.first
        case .lowestAltitude:
            let withAlt = aircraft.filter { $0.altitudeFt != nil }
            return withAlt.min { ($0.altitudeFt ?? 0) < ($1.altitudeFt ?? 0) } ?? aircraft.first
        case .fastest:
            let withSpeed = aircraft.filter { $0.groundSpeedKt != nil }
            return withSpeed.max { ($0.groundSpeedKt ?? 0) < ($1.groundSpeedKt ?? 0) } ?? aircraft.first
        }
    }
}
