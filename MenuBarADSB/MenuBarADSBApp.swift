import SwiftUI

@main
struct MenuBarADSBApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var store: AircraftStore
    private let location: LocationService

    init() {
        let settings = AppSettings()
        let location = LocationService()
        let fetcher = ADSBService()
        let routeFetcher = RouteService()
        let notifier = NotificationService()
        let store = AircraftStore(
            location: location, fetcher: fetcher,
            routeFetcher: routeFetcher,
            notifier: notifier, settings: settings
        )

        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: store)
        self.location = location

        location.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(store: store, settings: settings)
        } label: {
            MenuBarLabelView(store: store, settings: settings)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings)
        }
    }
}
