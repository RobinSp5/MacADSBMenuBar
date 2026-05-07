import Foundation
import Combine
import AppKit

@MainActor
final class AircraftStore: ObservableObject {
    private enum RouteCacheEntry {
        case data(RouteInfo)
        case noData
    }

    @Published private(set) var aircraft: [Aircraft] = []
    @Published private(set) var lastError: ADSBError?
    @Published private(set) var isStale: Bool = false
    @Published private(set) var lastFetchAt: Date?

    private let location: LocationProviding
    private let fetcher: AircraftFetching
    private let notifier: Notifying
    private let settings: AppSettings
    private let routeFetcher: RouteFetching
    private var routeCache: [String: RouteCacheEntry] = [:]
    private var pendingRouteFetches: Set<String> = []

    private var currentCoord: (lat: Double, lon: Double)?
    private var knownHexes: Set<String> = []
    private var failureCount = 0
    private var pollTimer: Timer?
    private var staleTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var inflightTask: Task<Void, Never>?

    init(location: LocationProviding, fetcher: AircraftFetching,
         routeFetcher: RouteFetching,
         notifier: Notifying, settings: AppSettings) {
        self.location = location
        self.fetcher = fetcher
        self.routeFetcher = routeFetcher
        self.notifier = notifier
        self.settings = settings

        location.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                Task { @MainActor in self?.onLocationStateChange(state) }
            }
            .store(in: &cancellables)

        settings.$radiusKm
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.tickNow() }
            }
            .store(in: &cancellables)

        settings.$updateIntervalSec
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.currentCoord != nil else { return }
                    self.startPolling()
                    self.tickNow()
                }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.currentCoord != nil else { return }
                    self.startPolling()
                    self.tickNow()
                }
            }
            .store(in: &cancellables)

        let stale = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recomputeStale() }
        }
        RunLoop.main.add(stale, forMode: .common)
        staleTimer = stale
    }

    private func onLocationStateChange(_ state: LocationState) {
        switch state {
        case .available(let lat, let lon):
            let isFirst = currentCoord == nil
            currentCoord = (lat, lon)
            if isFirst { startPolling() }
            tickNow()
        case .denied:
            currentCoord = nil
            stopPolling()
        case .unknown, .requesting:
            // Transient signal during a periodic refresh. Keep the last
            // known coord and the poll timer running — otherwise a stalled
            // requestLocation() would freeze the app permanently.
            break
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let interval = TimeInterval(settings.updateIntervalSec)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func tickNow() {
        guard let coord = currentCoord else { return }
        inflightTask?.cancel()
        let radius = settings.radiusKm
        let notificationsEnabled = settings.notificationsEnabled
        inflightTask = Task { @MainActor [weak self] in
            await self?.performFetch(lat: coord.lat, lon: coord.lon,
                                     radiusKm: radius,
                                     notificationsEnabled: notificationsEnabled)
        }
    }

    private func performFetch(lat: Double, lon: Double, radiusKm: Double,
                              notificationsEnabled: Bool) async {
        do {
            let result = try await fetcher.aircraftNear(lat: lat, lon: lon, radiusKm: radiusKm)

            // Enrich from cache before publishing.
            let enriched = result.map { ac -> Aircraft in
                guard let cs = ac.callsign,
                      case .data(let info) = routeCache[cs] else { return ac }
                var copy = ac
                copy.airline = info.airline
                copy.originIATA = info.originIATA
                copy.destinationIATA = info.destinationIATA
                return copy
            }

            self.aircraft = enriched
            self.lastError = nil
            self.failureCount = 0
            self.lastFetchAt = Date()
            self.isStale = false

            let currentHexes = Set(enriched.map { $0.hex })
            let newHexes = currentHexes.subtracting(knownHexes)
            if notificationsEnabled {
                for ac in enriched where newHexes.contains(ac.hex) {
                    notifier.notify(aircraft: ac)
                }
            }
            knownHexes = currentHexes

            // Trigger background route fetches for callsigns we don't know yet.
            for ac in enriched {
                guard let cs = ac.callsign,
                      routeCache[cs] == nil,
                      !pendingRouteFetches.contains(cs) else { continue }
                pendingRouteFetches.insert(cs)
                Task { @MainActor [weak self] in
                    await self?.fetchRoute(forCallsign: cs)
                }
            }
        } catch let error as ADSBError {
            if Task.isCancelled { return }
            failureCount += 1
            lastError = error
        } catch {
            if Task.isCancelled { return }
            failureCount += 1
            lastError = .transport
        }
    }

    private func fetchRoute(forCallsign callsign: String) async {
        defer { pendingRouteFetches.remove(callsign) }
        do {
            if let info = try await routeFetcher.route(forCallsign: callsign) {
                routeCache[callsign] = .data(info)
            } else {
                routeCache[callsign] = .noData
            }
            enrichVisibleAircraft()
        } catch {
            // Transport / HTTP / decode error — do NOT cache, retry on next tick.
        }
    }

    private func enrichVisibleAircraft() {
        var updated = self.aircraft
        for i in updated.indices {
            guard let cs = updated[i].callsign else { continue }
            if case .data(let info) = routeCache[cs] {
                updated[i].airline = info.airline
                updated[i].originIATA = info.originIATA
                updated[i].destinationIATA = info.destinationIATA
            }
        }
        if updated != self.aircraft { self.aircraft = updated }
    }

    private func recomputeStale() {
        guard let last = lastFetchAt else { isStale = false; return }
        let stalenessThreshold = TimeInterval(settings.updateIntervalSec * 2)
        isStale = Date().timeIntervalSince(last) > stalenessThreshold
    }
}
