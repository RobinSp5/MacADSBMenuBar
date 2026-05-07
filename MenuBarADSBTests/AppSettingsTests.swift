import XCTest
@testable import MenuBarADSB

final class AppSettingsTests: XCTestCase {

    private let baseKeys = ["radiusKm", "updateIntervalSec", "notificationsEnabled", "launchAtLogin",
                            "menuBarFields", "dropdownFields"]

    /// Generate a unique key prefix per test invocation so parallel runs don't collide.
    private func freshKeyPrefix() -> String {
        "test-\(UUID().uuidString)-"
    }

    private func clearKeys(prefix: String) {
        let defaults = UserDefaults.standard
        for key in baseKeys { defaults.removeObject(forKey: prefix + key) }
    }

    func testDefaults() {
        let prefix = freshKeyPrefix()
        clearKeys(prefix: prefix)
        defer { clearKeys(prefix: prefix) }

        let settings = AppSettings(defaults: .standard, keyPrefix: prefix)
        XCTAssertEqual(settings.radiusKm, 3.0)
        XCTAssertEqual(settings.updateIntervalSec, 15)
        XCTAssertFalse(settings.notificationsEnabled)
        XCTAssertFalse(settings.launchAtLogin)
    }

    func testPersistAndReload() {
        let prefix = freshKeyPrefix()
        clearKeys(prefix: prefix)
        defer { clearKeys(prefix: prefix) }

        do {
            let s = AppSettings(defaults: .standard, keyPrefix: prefix)
            s.radiusKm = 7.5
            s.updateIntervalSec = 30
            s.notificationsEnabled = true
            s.launchAtLogin = true
        }
        let reloaded = AppSettings(defaults: .standard, keyPrefix: prefix)
        XCTAssertEqual(reloaded.radiusKm, 7.5)
        XCTAssertEqual(reloaded.updateIntervalSec, 30)
        XCTAssertTrue(reloaded.notificationsEnabled)
        XCTAssertTrue(reloaded.launchAtLogin)
    }

    func testFieldDefaults() {
        let prefix = freshKeyPrefix()
        clearKeys(prefix: prefix)
        defer { clearKeys(prefix: prefix) }

        let s = AppSettings(defaults: .standard, keyPrefix: prefix)
        XCTAssertEqual(s.menuBarFields, [.altitude])
        XCTAssertEqual(s.dropdownFields, [.aircraftType, .altitude, .speed, .distance, .heading])
    }

    func testFieldPersistence() {
        let prefix = freshKeyPrefix()
        clearKeys(prefix: prefix)
        defer { clearKeys(prefix: prefix) }

        do {
            let s = AppSettings(defaults: .standard, keyPrefix: prefix)
            s.menuBarFields = [.airline, .route]
            s.dropdownFields = [.altitude, .heading]
        }
        let reloaded = AppSettings(defaults: .standard, keyPrefix: prefix)
        XCTAssertEqual(reloaded.menuBarFields, [.airline, .route])
        XCTAssertEqual(reloaded.dropdownFields, [.altitude, .heading])
    }

    func testFieldEmptySetPersists() {
        let prefix = freshKeyPrefix()
        clearKeys(prefix: prefix)
        defer { clearKeys(prefix: prefix) }

        do {
            let s = AppSettings(defaults: .standard, keyPrefix: prefix)
            s.menuBarFields = []
            s.dropdownFields = []
        }
        let reloaded = AppSettings(defaults: .standard, keyPrefix: prefix)
        XCTAssertEqual(reloaded.menuBarFields, [])
        XCTAssertEqual(reloaded.dropdownFields, [])
    }
}
