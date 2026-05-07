import Foundation
import Combine

nonisolated final class AppSettings: ObservableObject {
    private enum BaseKey {
        static let radiusKm = "radiusKm"
        static let updateIntervalSec = "updateIntervalSec"
        static let notificationsEnabled = "notificationsEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let menuBarFields = "menuBarFields"
        static let dropdownFields = "dropdownFields"
        static let menuBarSelection = "menuBarSelection"
    }

    private let defaults: UserDefaults
    private let keyPrefix: String

    @Published var radiusKm: Double {
        didSet { defaults.set(radiusKm, forKey: keyPrefix + BaseKey.radiusKm) }
    }
    @Published var updateIntervalSec: Int {
        didSet { defaults.set(updateIntervalSec, forKey: keyPrefix + BaseKey.updateIntervalSec) }
    }
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: keyPrefix + BaseKey.notificationsEnabled) }
    }
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: keyPrefix + BaseKey.launchAtLogin) }
    }
    @Published var menuBarFields: Set<DisplayField> {
        didSet {
            defaults.set(Self.encodeFields(menuBarFields),
                         forKey: keyPrefix + BaseKey.menuBarFields)
        }
    }
    @Published var dropdownFields: Set<DisplayField> {
        didSet {
            defaults.set(Self.encodeFields(dropdownFields),
                         forKey: keyPrefix + BaseKey.dropdownFields)
        }
    }
    @Published var menuBarSelection: MenuBarSelection {
        didSet {
            defaults.set(menuBarSelection.rawValue,
                         forKey: keyPrefix + BaseKey.menuBarSelection)
        }
    }

    init(defaults: UserDefaults = .standard, keyPrefix: String = "") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        self.radiusKm = defaults.object(forKey: keyPrefix + BaseKey.radiusKm) as? Double ?? 3.0
        self.updateIntervalSec = defaults.object(forKey: keyPrefix + BaseKey.updateIntervalSec) as? Int ?? 15
        self.notificationsEnabled = defaults.bool(forKey: keyPrefix + BaseKey.notificationsEnabled)
        self.launchAtLogin = defaults.bool(forKey: keyPrefix + BaseKey.launchAtLogin)
        self.menuBarFields = Self.loadFields(
            defaults: defaults, key: keyPrefix + BaseKey.menuBarFields,
            fallback: [.altitude]
        )
        self.dropdownFields = Self.loadFields(
            defaults: defaults, key: keyPrefix + BaseKey.dropdownFields,
            fallback: [.aircraftType, .altitude, .speed, .distance, .heading]
        )
        let selectionRaw = defaults.string(forKey: keyPrefix + BaseKey.menuBarSelection) ?? ""
        self.menuBarSelection = MenuBarSelection(rawValue: selectionRaw) ?? .closest
    }

    private static func encodeFields(_ fields: Set<DisplayField>) -> String {
        fields.map(\.rawValue).sorted().joined(separator: ",")
    }

    private static func loadFields(defaults: UserDefaults, key: String,
                                   fallback: Set<DisplayField>) -> Set<DisplayField> {
        guard let raw = defaults.string(forKey: key) else { return fallback }
        if raw.isEmpty { return [] }
        return Set(raw.split(separator: ",").compactMap { DisplayField(rawValue: String($0)) })
    }
}
