import Foundation
import Combine
import CoreLocation

nonisolated enum LocationState: Equatable, Sendable {
    case unknown
    case denied
    case requesting
    case available(lat: Double, lon: Double)
}

nonisolated protocol LocationProviding: Sendable {
    var statePublisher: AnyPublisher<LocationState, Never> { get }
    func refresh()
}

nonisolated final class LocationService: NSObject, LocationProviding, CLLocationManagerDelegate, @unchecked Sendable {

    private let manager = CLLocationManager()
    private let subject = CurrentValueSubject<LocationState, Never>(.unknown)
    private var refreshTimer: Timer?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var statePublisher: AnyPublisher<LocationState, Never> {
        subject.eraseToAnyPublisher()
    }

    func start() {
        handleAuthorizationStatus(manager.authorizationStatus)
    }

    func refresh() {
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorized else { return }
        subject.send(.requesting)
        manager.requestLocation()
    }

    private func handleAuthorizationStatus(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            subject.send(.requesting)
        case .denied, .restricted:
            subject.send(.denied)
        case .authorizedAlways, .authorized:
            refresh()
            startPeriodicRefresh()
        @unknown default:
            subject.send(.unknown)
        }
    }

    private func startPeriodicRefresh() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorizationStatus(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        subject.send(.available(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep last known state; transient failures shouldn't flip UI.
    }
}
