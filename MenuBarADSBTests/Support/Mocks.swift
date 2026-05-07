import Foundation
import Combine
@testable import MenuBarADSB

nonisolated final class MockLocationService: LocationProviding, @unchecked Sendable {
    let subject = CurrentValueSubject<LocationState, Never>(.unknown)
    var refreshCount = 0

    var statePublisher: AnyPublisher<LocationState, Never> {
        subject.eraseToAnyPublisher()
    }

    func refresh() { refreshCount += 1 }

    func emit(_ state: LocationState) { subject.send(state) }
}

nonisolated final class MockADSBFetcher: AircraftFetching, @unchecked Sendable {
    var nextResult: Result<[Aircraft], Error> = .success([])
    private(set) var callCount = 0
    private(set) var lastRadius: Double?

    func aircraftNear(lat: Double, lon: Double, radiusKm: Double) async throws -> [Aircraft] {
        callCount += 1
        lastRadius = radiusKm
        switch nextResult {
        case .success(let arr): return arr
        case .failure(let err): throw err
        }
    }
}

nonisolated final class MockNotifier: Notifying, @unchecked Sendable {
    private(set) var notified: [Aircraft] = []
    private(set) var requestedAuth = false

    func notify(aircraft: Aircraft) { notified.append(aircraft) }
    func requestAuthorizationIfNeeded() async { requestedAuth = true }
    func clearNotified() { notified.removeAll() }
}

nonisolated final class MockRouteFetcher: RouteFetching, @unchecked Sendable {
    /// Predefined responses keyed by callsign. Defaults to .success(nil) for unknown callsigns.
    var responses: [String: Result<RouteInfo?, Error>] = [:]
    private(set) var callCounts: [String: Int] = [:]

    func route(forCallsign callsign: String) async throws -> RouteInfo? {
        callCounts[callsign, default: 0] += 1
        let result = responses[callsign] ?? .success(nil)
        switch result {
        case .success(let info): return info
        case .failure(let err): throw err
        }
    }
}

nonisolated extension Aircraft {
    static func stub(hex: String, callsign: String? = nil, altitudeFt: Int? = nil,
                     lat: Double = 0, lon: Double = 0, distanceKm: Double = 0) -> Aircraft {
        var ac = Aircraft(
            hex: hex, callsign: callsign, registration: nil, typeCode: nil,
            altitudeFt: altitudeFt, groundSpeedKt: nil, trackDeg: nil,
            lat: lat, lon: lon
        )
        ac.distanceKm = distanceKm
        return ac
    }
}
