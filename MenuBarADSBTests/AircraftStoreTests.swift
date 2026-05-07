import XCTest
import Combine
@testable import MenuBarADSB

@MainActor
final class AircraftStoreTests: XCTestCase {

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: .standard, keyPrefix: "test-store-\(UUID().uuidString)-")
    }

    func testNoTickBeforeLocationAvailable() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        let notifier = MockNotifier()
        let settings = makeSettings()

        _ = AircraftStore(
            location: location, fetcher: fetcher,
            routeFetcher: MockRouteFetcher(),
            notifier: notifier, settings: settings
        )

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fetcher.callCount, 0)
    }

    func testTicksOnceWhenLocationBecomesAvailable() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        fetcher.nextResult = .success([.stub(hex: "abc", distanceKm: 1.0)])
        let notifier = MockNotifier()
        let settings = makeSettings()

        let store = AircraftStore(
            location: location, fetcher: fetcher,
            routeFetcher: MockRouteFetcher(),
            notifier: notifier, settings: settings
        )

        location.emit(.available(lat: 50, lon: 8))
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(fetcher.callCount, 1)
        XCTAssertEqual(store.aircraft.map { $0.hex }, ["abc"])
    }

    func testRadiusChangeTriggersImmediateTick() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        let notifier = MockNotifier()
        let settings = makeSettings()

        let store = AircraftStore(
            location: location, fetcher: fetcher,
            routeFetcher: MockRouteFetcher(),
            notifier: notifier, settings: settings
        )
        _ = store

        location.emit(.available(lat: 50, lon: 8))
        try await Task.sleep(nanoseconds: 250_000_000)
        let initialCalls = fetcher.callCount

        settings.radiusKm = 10.0
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertGreaterThan(fetcher.callCount, initialCalls)
        XCTAssertEqual(fetcher.lastRadius, 10.0)
    }

    func testIntervalChangeRestartsTimer() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        let notifier = MockNotifier()
        let settings = makeSettings()

        let store = AircraftStore(
            location: location, fetcher: fetcher,
            routeFetcher: MockRouteFetcher(),
            notifier: notifier, settings: settings
        )
        _ = store

        location.emit(.available(lat: 50, lon: 8))
        try await Task.sleep(nanoseconds: 250_000_000)

        settings.updateIntervalSec = 5
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThanOrEqual(fetcher.callCount, 1)
    }

    func testNotifiesOnlyOnNewHex() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        let notifier = MockNotifier()
        let settings = makeSettings()
        settings.notificationsEnabled = true

        let store = AircraftStore(
            location: location, fetcher: fetcher,
            routeFetcher: MockRouteFetcher(),
            notifier: notifier, settings: settings
        )
        _ = store

        fetcher.nextResult = .success([.stub(hex: "aaa"), .stub(hex: "bbb")])
        location.emit(.available(lat: 50, lon: 8))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(Set(notifier.notified.map { $0.hex }), ["aaa", "bbb"])
        notifier.clearNotified()

        fetcher.nextResult = .success([.stub(hex: "aaa"), .stub(hex: "bbb"), .stub(hex: "ccc")])
        settings.radiusKm = 5.0
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(notifier.notified.map { $0.hex }, ["ccc"])
    }

    func testNoNotificationsWhenDisabled() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        fetcher.nextResult = .success([.stub(hex: "aaa")])
        let notifier = MockNotifier()
        let settings = makeSettings()

        _ = AircraftStore(
            location: location, fetcher: fetcher,
            routeFetcher: MockRouteFetcher(),
            notifier: notifier, settings: settings
        )

        location.emit(.available(lat: 50, lon: 8))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(notifier.notified.isEmpty)
    }

    func testTransientFailuresKeepLastKnownList() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        let notifier = MockNotifier()
        let settings = makeSettings()

        let store = AircraftStore(
            location: location, fetcher: fetcher,
            routeFetcher: MockRouteFetcher(),
            notifier: notifier, settings: settings
        )

        fetcher.nextResult = .success([.stub(hex: "abc")])
        location.emit(.available(lat: 50, lon: 8))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(store.aircraft.count, 1)

        fetcher.nextResult = .failure(ADSBError.transport)
        for r in [4.0, 5.0, 6.0] {
            settings.radiusKm = r
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        // Last-known list is preserved across transient failures so the user
        // keeps seeing (stale) data instead of an empty error screen.
        XCTAssertEqual(store.aircraft.count, 1)
        XCTAssertEqual(store.lastError, .transport)
    }

    func testSuccessAfterFailureResetsCounter() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        let notifier = MockNotifier()
        let settings = makeSettings()

        let store = AircraftStore(
            location: location, fetcher: fetcher,
            routeFetcher: MockRouteFetcher(),
            notifier: notifier, settings: settings
        )

        fetcher.nextResult = .success([.stub(hex: "abc")])
        location.emit(.available(lat: 50, lon: 8))
        try await Task.sleep(nanoseconds: 250_000_000)

        fetcher.nextResult = .failure(ADSBError.transport)
        settings.radiusKm = 4.0
        try await Task.sleep(nanoseconds: 250_000_000)
        settings.radiusKm = 5.0
        try await Task.sleep(nanoseconds: 250_000_000)

        fetcher.nextResult = .success([.stub(hex: "xyz")])
        settings.radiusKm = 6.0
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.aircraft.first?.hex, "xyz")
    }

    func testRouteDataPopulatesAircraft() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        let routeFetcher = MockRouteFetcher()
        let notifier = MockNotifier()
        let settings = makeSettings()

        let info = RouteInfo(airline: "Lufthansa", originIATA: "FRA", destinationIATA: "MUC")
        routeFetcher.responses["DLH441"] = .success(info)
        fetcher.nextResult = .success([.stub(hex: "abc", callsign: "DLH441")])

        let store = AircraftStore(
            location: location, fetcher: fetcher,
            routeFetcher: routeFetcher,
            notifier: notifier, settings: settings
        )

        location.emit(.available(lat: 50, lon: 8))
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(store.aircraft.first?.airline, "Lufthansa")
        XCTAssertEqual(store.aircraft.first?.originIATA, "FRA")
        XCTAssertEqual(store.aircraft.first?.destinationIATA, "MUC")
    }

    func testRouteFetchedOncePerCallsignAcrossTicks() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        let routeFetcher = MockRouteFetcher()
        let notifier = MockNotifier()
        let settings = makeSettings()

        routeFetcher.responses["DLH441"] = .success(
            RouteInfo(airline: "Lufthansa", originIATA: "FRA", destinationIATA: "MUC")
        )
        fetcher.nextResult = .success([.stub(hex: "abc", callsign: "DLH441")])

        let store = AircraftStore(
            location: location, fetcher: fetcher,
            routeFetcher: routeFetcher,
            notifier: notifier, settings: settings
        )
        _ = store

        location.emit(.available(lat: 50, lon: 8))
        try await Task.sleep(nanoseconds: 400_000_000)

        settings.radiusKm = 5.0
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(routeFetcher.callCounts["DLH441"], 1)
    }

    func testNegativeCachePreventsRefetch() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        let routeFetcher = MockRouteFetcher()
        let notifier = MockNotifier()
        let settings = makeSettings()

        routeFetcher.responses["UNKNOWN1"] = .success(nil)
        fetcher.nextResult = .success([.stub(hex: "x", callsign: "UNKNOWN1")])

        let store = AircraftStore(
            location: location, fetcher: fetcher,
            routeFetcher: routeFetcher,
            notifier: notifier, settings: settings
        )
        _ = store

        location.emit(.available(lat: 50, lon: 8))
        try await Task.sleep(nanoseconds: 400_000_000)
        settings.radiusKm = 5.0
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(routeFetcher.callCounts["UNKNOWN1"], 1)
    }

    func testRouteFailureDoesNotPoisonAircraftList() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        let routeFetcher = MockRouteFetcher()
        let notifier = MockNotifier()
        let settings = makeSettings()

        routeFetcher.responses["DLH441"] = .failure(ADSBError.transport)
        fetcher.nextResult = .success([.stub(hex: "abc", callsign: "DLH441")])

        let store = AircraftStore(
            location: location, fetcher: fetcher,
            routeFetcher: routeFetcher,
            notifier: notifier, settings: settings
        )

        location.emit(.available(lat: 50, lon: 8))
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(store.aircraft.first?.hex, "abc")
        XCTAssertNil(store.aircraft.first?.airline)
        XCTAssertNil(store.lastError)
    }
}
