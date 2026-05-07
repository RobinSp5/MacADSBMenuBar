# MenuBarADSB — Design Spec

**Date:** 2026-05-05
**Status:** Approved (brainstorming complete, ready for implementation plan)
**Target Platform:** macOS 14 (Sonoma) and later, Apple Silicon + Intel
**Language Stack:** Swift 5.9+, SwiftUI, async/await, Combine

---

## 1. Overview

A macOS menu bar app that displays aircraft currently flying within a user-configurable horizontal radius (default 3 km) of the user's location. Data is fetched from the public adsb.lol API. The app is always-on, lives only in the menu bar (no Dock icon), and gives the user a glanceable view of overhead air traffic.

**Primary use case:** "What's that plane flying over my house right now?" — answered in one glance at the menu bar.

---

## 2. Locked Decisions

These were settled in brainstorming and are not up for re-debate during implementation:

| # | Topic | Decision |
|---|---|---|
| 1 | Location source | macOS CoreLocation, automatic. No manual fallback. |
| 2 | Menu bar label | Dynamic: icon alone when no aircraft in radius; icon + closest-aircraft callsign + altitude when one or more present. |
| 3 | Altitude filter | None. All aircraft within horizontal radius are shown, including high-altitude cruise traffic. |
| 4 | Dropdown row content | Callsign, aircraft type, altitude, ground speed, distance, plus heading/track hint. |
| 5 | Click on aircraft | Opens `https://www.flightradar24.com/<callsign>` in default browser. Fallback to globe.adsb.lol with hex code if callsign is missing. |
| 6 | Polling frequency | Default 15 s, user-adjustable in Settings (range 5–60 s). |
| 7 | Notifications | Optional, default OFF. Toggle in Settings. When ON, fires when a new hex code enters the radius. |
| 8 | Settings UI | Separate SwiftUI `Settings` scene window, opened via "Einstellungen…" item in the dropdown. |
| 9 | Launch at login | Toggle in Settings, default OFF. Implemented via `SMAppService.mainApp`. |

**UI language:** German (matches the user). All user-visible strings are in German.

---

## 3. Architecture

### 3.1 Approach

Pure SwiftUI using the `MenuBarExtra` and `Settings` scenes introduced/matured in macOS 13+. No AppKit `NSStatusItem` boilerplate, no AppDelegate. This is sufficient for every requirement above.

### 3.2 Project Layout

```
MenuBarADSB/
├── MenuBarADSBApp.swift              # App entry, scenes, root @StateObjects
├── Models/
│   └── Aircraft.swift                # Domain model + GeoMath helpers
├── Services/
│   ├── LocationService.swift         # CLLocationManager wrapper
│   ├── ADSBService.swift             # adsb.lol HTTP client
│   ├── NotificationService.swift     # UNUserNotificationCenter wrapper
│   └── LaunchAtLoginService.swift    # SMAppService wrapper
├── State/
│   ├── AppSettings.swift             # ObservableObject, UserDefaults-backed
│   └── AircraftStore.swift           # Polling coordinator, the brain
├── Views/
│   ├── MenuBarLabelView.swift        # Compact menu bar label
│   ├── MenuBarContentView.swift      # Dropdown content
│   └── SettingsView.swift            # Settings window content
└── Assets.xcassets/                  # App icon, status bar icon (template image)

MenuBarADSBTests/
├── GeoMathTests.swift
├── ADSBServiceTests.swift
├── AircraftStoreTests.swift
├── AppSettingsTests.swift
└── Fixtures/
    └── adsb-sample-*.json

MenuBarADSBUITests/
└── MenuBarADSBUITests.swift          # Smoke test only
```

### 3.3 Component Responsibilities

| Component | Responsibility | Depends on |
|---|---|---|
| `MenuBarADSBApp` | Wires `MenuBarExtra` + `Settings` scenes, owns root `@StateObject`s. | All services + state objects |
| `Aircraft` | Plain struct mapped from API. Fields: `hex`, `callsign?`, `registration?`, `typeCode?`, `altitudeFt?`, `groundSpeedKt?`, `trackDeg?`, `lat`, `lon`, `distanceKm`. | — |
| `GeoMath` (in `Aircraft.swift`) | Haversine distance function, km↔NM conversion. | Foundation |
| `LocationService` | Wraps `CLLocationManager`. Publishes `state: LocationState` (`unknown`/`requesting`/`denied`/`available(coordinate)`). Refreshes location every 5 minutes via `requestLocation()` (single-fix). | CoreLocation |
| `ADSBService` | Stateless. `func aircraftNear(lat:lon:radiusKm:) async throws -> [Aircraft]`. Computes per-aircraft distance, returns sorted by ascending distance. | URLSession, Aircraft |
| `NotificationService` | Sends `UNNotificationRequest`s. Handles permission request. No-op when disabled. | UserNotifications |
| `LaunchAtLoginService` | Register/unregister via `SMAppService.mainApp`. Reads current status. | ServiceManagement |
| `AppSettings` | `ObservableObject`. Properties (UserDefaults-backed): `radiusKm: Double` (default 3.0), `updateIntervalSec: Int` (default 15), `notificationsEnabled: Bool` (default false), `launchAtLogin: Bool` (default false). | Foundation |
| `AircraftStore` | The coordinator. `@Published var aircraft: [Aircraft]`, `@Published var lastError: ADSBError?`, `@Published var isStale: Bool`. Owns the polling timer. Reacts to settings changes via Combine. | LocationService, ADSBService, NotificationService, AppSettings |
| `MenuBarLabelView` | Reads `AircraftStore.aircraft.first`. Renders icon alone, or icon + label string. | AircraftStore |
| `MenuBarContentView` | Renders state (loading/empty/list/error) + footer (Settings button, Quit button). Click on aircraft → opens flightradar24 in browser. | AircraftStore |
| `SettingsView` | Form with: radius slider (1–50 km), interval slider (5–60 s), notifications toggle, launch-at-login toggle. | AppSettings, LaunchAtLoginService |

### 3.4 Why this split

- Services are stateless or thin wrappers around system APIs — easily mockable behind protocols.
- `AircraftStore` is the one "smart" coordinator. Views are dumb.
- `AppSettings` is its own object so settings changes propagate via Combine; e.g., interval slider movement triggers timer restart automatically.
- `Aircraft` model is pure data, no networking concerns.

---

## 4. Data Flow

### 4.1 Startup

```
MenuBarADSBApp.init
  ├─ AppSettings (loads UserDefaults)
  ├─ LocationService (state = .unknown)
  ├─ AircraftStore(locationService, adsbService, notificationService, settings)
  │   └─ subscribes to LocationService.state
  │   └─ subscribes to AppSettings.radiusKm and updateIntervalSec
  └─ scenes render

LocationService.requestAuthorization()
  → user prompt (first launch only)
  → on grant: requestLocation() → state = .available(coord)
  → on deny: state = .denied
```

### 4.2 Polling tick

Triggered by `Timer` on the configured interval, AND immediately on any of: location-becomes-available, radius-change, interval-change, wake-from-sleep.

```
AircraftStore.tick()
  ├─ guard case .available(let coord) = locationService.state else return
  ├─ Task { try await adsbService.aircraftNear(lat: coord.lat, lon: coord.lon, radiusKm: settings.radiusKm) }
  ├─ on success:
  │     ├─ self.aircraft = result
  │     ├─ self.lastError = nil
  │     ├─ self.isStale = false
  │     ├─ diff hex codes against previous set
  │     │   └─ for each new hex: notificationService.notify(...)  (if settings.notificationsEnabled)
  │     └─ update knownHexes
  └─ on failure:
        ├─ increment failureCount
        ├─ self.lastError = error
        └─ if failureCount >= 3: clear aircraft list (treat as persistent error)
```

### 4.3 Settings reactions

- `radiusKm` changes → AircraftStore triggers immediate `tick()`.
- `updateIntervalSec` changes → AircraftStore invalidates timer, schedules new one.
- `notificationsEnabled` true and permission not yet granted → `NotificationService.requestAuthorization()`.
- `launchAtLogin` changes → `LaunchAtLoginService.register()` or `.unregister()`.

### 4.4 Wake from sleep

Subscribe to `NSWorkspace.didWakeNotification`. On fire: trigger immediate `tick()`, recreate timer.

### 4.5 View rendering

Reactive — Views observe `AircraftStore` and `AppSettings`. No imperative refresh calls.

---

## 5. API & Math

### 5.1 Endpoint

```
GET https://api.adsb.lol/v2/lat/{lat}/lon/{lon}/dist/{distNM}
```

- `distNM` is nautical miles. Max 250.
- Conversion: `distNM = ceil(radiusKm * 0.539957)`. We over-fetch slightly (e.g., 3 km → 2 NM ≈ 3.7 km) and filter client-side to the exact `radiusKm`. This avoids API rounding artifacts and gives precise km filtering regardless of NM granularity.

### 5.2 HTTP

- Method: GET
- Headers:
  - `User-Agent: MenuBarADSB/1.0` — adsb.lol asks apps to identify themselves. (Optional: append a contact email or repo URL in a later release; left out of v1 to avoid baking personal contact info into the binary.)
  - `Accept: application/json`
- Timeout: 10 s per request (`URLRequest.timeoutInterval`).

### 5.3 Response shape (relevant fields only)

```json
{
  "ac": [
    {
      "hex": "3c6589",
      "flight": "DLH441  ",
      "r": "D-AIBC",
      "t": "A346",
      "alt_baro": 36000,
      "gs": 452,
      "track": 287.4,
      "lat": 50.123,
      "lon": 8.456
    }
  ],
  "msg": "No error",
  "now": 1746442800000
}
```

### 5.4 Field mapping (all Aircraft fields except hex/lat/lon are optional — defensive parsing)

| API field | Aircraft property | Notes |
|---|---|---|
| `hex` | `hex` | Always present, used as primary identity key. |
| `flight` | `callsign` | Trim whitespace; nil if empty after trim. |
| `r` | `registration` | nil if missing. |
| `t` | `typeCode` | ICAO type designator (e.g., "A346"). |
| `alt_baro` | `altitudeFt` | Can be the literal string `"ground"` → map to `0`. Can be missing → nil. |
| `gs` | `groundSpeedKt` | Knots. nil if missing. |
| `track` | `trackDeg` | Course over ground, 0–360°. nil if missing. |
| `lat`, `lon` | `lat`, `lon` | Doubles, always present for valid aircraft. |
| (computed) | `distanceKm` | Haversine to user coord, computed in `ADSBService`. |

### 5.5 Display conversions

Done in views, not stored in model:

- Altitude: `altitudeFt × 0.3048` → metres, integer-rounded, displayed as e.g., "11.300 m".
- Speed: `groundSpeedKt × 1.852` → km/h, integer-rounded, e.g., "838 km/h".
- Distance: `distanceKm` → one decimal place, e.g., "2,4 km" (German decimal comma).
- Heading: `trackDeg` → 8-point compass abbreviation (N, NO, O, SO, S, SW, W, NW).

### 5.6 Haversine (in `GeoMath`)

```swift
func haversineKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let R = 6371.0 // Earth mean radius in km
    let dLat = (lat2 - lat1).toRadians
    let dLon = (lon2 - lon1).toRadians
    let a = sin(dLat/2) * sin(dLat/2)
          + cos(lat1.toRadians) * cos(lat2.toRadians)
          * sin(dLon/2) * sin(dLon/2)
    return 2 * R * asin(min(1, sqrt(a)))
}
```

### 5.7 Rate limiting & errors

- adsb.lol limit: 1 request/second. Our minimum interval is 5 s → 5× headroom.
- HTTP 429 → skip this tick silently, retry on next tick. No exponential backoff (minimum interval already conservative).
- Transport error / timeout → bump failure counter, set `lastError`, retry on next tick.
- Three consecutive failures → clear the aircraft list and surface a persistent error state (see §6).
- Successful response resets failure counter to 0.

### 5.8 Display fallback chain for aircraft identifier

When showing a row's identity (and the menu bar label):
1. `callsign` if present and non-empty after trim
2. else `registration`
3. else `hex` (uppercased)

---

## 6. UI States & Edge Cases

Both `MenuBarLabelView` and `MenuBarContentView` must render every state below correctly.

| State | Menu bar label | Dropdown |
|---|---|---|
| Permission requesting (first launch) | Dimmed icon | "Warte auf Standortzugriff…" + brief explanation |
| Permission denied | Icon with ⚠ overlay | "Standortzugriff fehlt." + button "Systemeinstellungen öffnen" (opens `x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices`) |
| Permission granted, no fix yet | Pulsing icon | "Standort wird ermittelt…" |
| First fetch in flight | Icon | "Lade Flugzeuge…" |
| No aircraft in radius | Icon only | "Keine Flugzeuge im {N} km Radius." + footer "Aktualisiert: vor {X} s" |
| 1+ aircraft in radius | Icon + closest aircraft identifier + altitude (e.g., "✈ DLH441 · 11.300 m") | List rows, sorted by ascending distance |
| Transient network error (1–2 fails) | Last known label remains | List remains visible (last successful response); footer note "Aktualisierung fehlgeschlagen — neuer Versuch in {N} s" |
| Persistent error (3+ fails) | Icon with ⚠ | "Verbindung zu adsb.lol nicht möglich" — list cleared |
| Notifications permission denied after toggle-on | unchanged | In Settings: red hint near toggle: "Notifications in Systemeinstellungen aktivieren" |

### 6.1 Stale-data indicator

If `now - lastSuccessfulFetch > 2 × updateIntervalSec`, the aircraft list in the dropdown is rendered at 50% opacity and the footer reads "Veraltet — letzter Stand: vor {X} s". This is independent of the error states above and helps the user spot frozen data after sleep/wake or transient errors.

### 6.2 Notifications — duplicate suppression

`AircraftStore` keeps `var knownHexes: Set<String>`. After each successful tick:
1. Compute `newHexes = currentHexes \ knownHexes`
2. For each `hex` in `newHexes`: `NotificationService.notify(...)` (only if `settings.notificationsEnabled` is true).
3. Set `knownHexes = currentHexes` (this naturally drops aircraft that left the radius — they re-notify if they come back later, which is intended).

### 6.3 Wake from sleep

Timers paused during sleep can fire late or not at all. We subscribe to `NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)`. On fire: invalidate and recreate the timer, trigger an immediate `tick()`.

### 6.4 Location refresh strategy

Use `requestLocation()` (single-fix) on:
- App launch (after permission granted)
- Wake from sleep
- Every 5 minutes via a separate scheduled task

Do **not** use `startUpdatingLocation()` — it drains battery and we don't need real-time tracking. Macs rarely move while running.

---

## 7. Testing

| Subject | Test file | Approach |
|---|---|---|
| Haversine accuracy | `GeoMathTests.swift` | Known city pairs (Frankfurt↔München ≈ 300.5 km), tolerate ±0.1% error. Edge cases: same point → 0; antipodes → ~20015 km. |
| ADSB JSON parsing | `ADSBServiceTests.swift` | Fixture JSONs under `Tests/Fixtures/`. Cases: full payload, missing optional fields, `alt_baro: "ground"`, empty `ac` array, malformed JSON → throws. |
| ADSB distance + sort | `ADSBServiceTests.swift` | Fixture with three known coordinates, confirm sorted ascending by distance and distances correct. |
| AircraftStore notification logic | `AircraftStoreTests.swift` | Mock `NotificationService`. Two ticks, second tick adds one new hex — assert exactly one notify call. |
| AircraftStore polling lifecycle | `AircraftStoreTests.swift` | Mock `LocationService` + `ADSBService`. No tick before location available; tick fires after location becomes available; interval change restarts timer; sleep/wake triggers immediate tick. |
| AppSettings persistence | `AppSettingsTests.swift` | UserDefaults `(suiteName: "test-...")` per test. Write each setting, reload, assert. |
| Smoke UI test | `MenuBarADSBUITests.swift` | App launches, status item appears, dropdown can be opened. |

### Mocking

Define protocols for the three services that need mocking:

```swift
protocol LocationProviding {
    var statePublisher: AnyPublisher<LocationState, Never> { get }
    func refresh()
}
protocol AircraftFetching {
    func aircraftNear(lat: Double, lon: Double, radiusKm: Double) async throws -> [Aircraft]
}
protocol Notifying {
    func notify(aircraft: Aircraft)
    func requestAuthorizationIfNeeded() async
}
```

Production types conform to these. Tests inject mocks.

---

## 8. macOS Configuration

### 8.1 Deployment

- Minimum: **macOS 14 (Sonoma)**.
- Architectures: Universal (arm64 + x86_64).

### 8.2 Info.plist / Build Settings

| Key | Value | Purpose |
|---|---|---|
| `LSUIElement` | `YES` | Hide from Dock and Cmd-Tab. |
| `NSLocationUsageDescription` | "MenuBarADSB nutzt deinen Standort, um Flugzeuge in deinem Umkreis zu finden." | Required permission rationale. |
| Bundle ID | `com.speichermann.MenuBarADSB` | — |
| Display Name | "MenuBarADSB" | — |

### 8.3 Capabilities

- **App Sandbox: ON**
  - Network → Outgoing Connections (Client)
  - Hardware → Location
- **Hardened Runtime: ON** (needed for future notarization)

### 8.4 Frameworks

All Apple-provided, no third-party dependencies:
- SwiftUI, Foundation, Combine
- CoreLocation
- UserNotifications
- ServiceManagement
- AppKit (only for `NSWorkspace`)

### 8.5 Initial cleanup

The Xcode template ships with `WindowGroup` and a `ContentView`. Both must be replaced:

- `MenuBarADSBApp.swift`: `WindowGroup { ContentView() }` → `MenuBarExtra(...) { MenuBarContentView() }` + `Settings { SettingsView() }`
- `ContentView.swift`: delete

### 8.6 Settings window

- Default size: ~ 380 × 320 pt
- Not resizable
- Standard SwiftUI `Settings` scene (gives Cmd+, automatically and a single-tab settings window)

### 8.7 Status bar icon

Use SF Symbol `airplane` as a template image. Renders correctly in both light and dark menu bars and in both regular and reduced-transparency modes without further work.

---

## 9. Out of Scope (YAGNI)

These were considered and explicitly **excluded** from v1. They may be revisited later if real usage shows demand.

- Altitude filter (user explicitly chose not to filter — see decision #3).
- Inline detail expansion in the dropdown (rejected in favour of opening flightradar24).
- In-app map view or flight track visualisation.
- Persistent history of seen aircraft / "logbook" feature.
- Sound alerts.
- iOS / iPadOS port.
- Localization beyond German.
- Manual location entry (rejected — CoreLocation is the only path).
- Multiple "favourite locations" or per-location settings.
- Background fetching while system is asleep.
- Third-party libraries (e.g., MenuBarExtraAccess) — pure first-party APIs only.

---

## 10. Acceptance Criteria

The implementation is complete when:

1. App builds and runs on macOS 14+ with no warnings.
2. On first launch, app prompts for location access and shows the appropriate dropdown state during/after the prompt.
3. Once location is granted and a fix is acquired, the app polls adsb.lol every 15 s by default and displays returned aircraft in the dropdown sorted by distance.
4. Menu bar label updates dynamically: icon-only when empty, icon + closest-aircraft identifier + altitude when occupied.
5. Clicking an aircraft row opens flightradar24 in the default browser.
6. Settings window is reachable from the dropdown, contains all four configurable values, and changes take effect immediately (or on next tick for radius/interval).
7. With notifications toggled on and permission granted, a new aircraft entering the radius produces a single macOS notification (no duplicates on subsequent ticks).
8. With launch-at-login toggled on, the app appears in System Settings → General → Login Items, and starts on next user login.
9. Network failures, missing location permission, and persistent errors all render the documented UI states.
10. All unit tests in §7 pass.
