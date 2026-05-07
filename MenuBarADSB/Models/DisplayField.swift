import Foundation

nonisolated enum DisplayField: String, CaseIterable, Codable, Sendable {
    case airline
    case route
    case aircraftType
    case altitude
    case speed
    case distance
    case heading

    /// Canonical render order, used by both menu bar and dropdown.
    /// Identifier is rendered first separately and is not part of this list.
    static let canonicalOrder: [DisplayField] = [
        .airline, .route, .aircraftType, .altitude, .speed, .distance, .heading
    ]
}
