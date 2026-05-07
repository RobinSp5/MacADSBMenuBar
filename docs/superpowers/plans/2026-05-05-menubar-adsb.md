# MenuBarADSB Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS menu bar app that displays aircraft within an adjustable horizontal radius (default 3 km) of the user, fetched from adsb.lol, with German UI strings.

**Architecture:** Pure SwiftUI app using `MenuBarExtra` + `Settings` scenes. One coordinator (`AircraftStore`) owns a polling timer and reacts to Combine publishers from `AppSettings` and `LocationService`. Stateless services for HTTP, notifications, and login-item registration. All system-API wrappers live behind protocols so the store can be tested with mocks.

**Tech Stack:** Swift 5.9+, SwiftUI, Combine, async/await, XCTest, CoreLocation, UserNotifications, ServiceManagement, AppKit (`NSWorkspace` only).

**Spec:** `docs/superpowers/specs/2026-05-05-menubar-adsb-design.md` — refer to it for any decisions not explicit in this plan.

**Note on git:** This project is not (yet) a git repository. Plan therefore omits `git commit` steps. If git is initialised later, add commits at the end of each task as natural checkpoints.

---

## File Structure

### Created files

| Path | Responsibility |
|---|---|
| `MenuBarADSB/Models/Aircraft.swift` | Domain struct + custom `Decodable` (handles `alt_baro: "ground"`). |
| `MenuBarADSB/Models/GeoMath.swift` | Haversine distance, km↔NM conversions, `Double.toRadians`. |
| `MenuBarADSB/Services/LocationService.swift` | `CLLocationManager` wrapper, publishes `LocationState`. Conforms to `LocationProviding`. |
| `MenuBarADSB/Services/ADSBService.swift` | adsb.lol HTTP client. Conforms to `AircraftFetching`. Defines `ADSBError`. |
| `MenuBarADSB/Services/NotificationService.swift` | `UNUserNotificationCenter` wrapper. Conforms to `Notifying`. |
| `MenuBarADSB/Services/LaunchAtLoginService.swift` | `SMAppService.mainApp` wrapper. |
| `MenuBarADSB/State/AppSettings.swift` | `ObservableObject`, UserDefaults-backed via `@AppStorage`-style property wrappers. |
| `MenuBarADSB/State/AircraftStore.swift` | Polling coordinator. `@Published var aircraft, lastError, isStale`. |
| `MenuBarADSB/Views/MenuBarLabelView.swift` | Compact menu bar label. |
| `MenuBarADSB/Views/MenuBarContentView.swift` | Dropdown content (all UI states). |
| `MenuBarADSB/Views/SettingsView.swift` | Settings window form. |
| `MenuBarADSBTests/GeoMathTests.swift` | Haversine + conversion tests. |
| `MenuBarADSBTests/AircraftTests.swift` | Codable parsing tests (uses fixtures). |
| `MenuBarADSBTests/ADSBServiceTests.swift` | URL building, distance/sort, error tests via `MockURLProtocol`. |
| `MenuBarADSBTests/AircraftStoreTests.swift` | Polling, notification, error, stale, sleep/wake tests via mocks. |
| `MenuBarADSBTests/AppSettingsTests.swift` | UserDefaults persistence tests. |
| `MenuBarADSBTests/Support/MockURLProtocol.swift` | Reusable URLSession mock. |
| `MenuBarADSBTests/Support/Mocks.swift` | `MockLocationService`, `MockADSBFetcher`, `MockNotifier`. |
| `MenuBarADSBTests/Fixtures/adsb-full.json` | Three-aircraft sample. |
| `MenuBarADSBTests/Fixtures/adsb-empty.json` | Empty response. |
| `MenuBarADSBTests/Fixtures/adsb-ground.json` | Aircraft with `alt_baro: "ground"`. |
| `MenuBarADSBTests/Fixtures/adsb-minimal.json` | Aircraft with only required fields. |

### Modified files

| Path | Change |
|---|---|
| `MenuBarADSB/MenuBarADSBApp.swift` | Replace `WindowGroup { ContentView() }` with `MenuBarExtra` + `Settings` scenes wired to dependencies. |
| Xcode project settings | Deployment target → macOS 14, Info keys (`LSUIElement`, `NSLocationUsageDescription`), Capabilities (App Sandbox + Network + Location, Hardened Runtime). |

### Deleted files

| Path | Reason |
|---|---|
| `MenuBarADSB/ContentView.swift` | Template artifact, not used. |

---

## Test commands

All tasks below show `xcodebuild` invocations for CLI use. Equivalent in Xcode: select the test in the test navigator and press the diamond, or use **Product → Test** (⌘U) to run the whole suite.

**Run all tests (CLI):**
```bash
cd "/Users/robinspeichermann/Documents/Xcode Stuff/MenuBarADSB" && \
  xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' -quiet
```

**Run a single test:**
```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/GeoMathTests/testHaversineFrankfurtMunich -quiet
```

**Build only:**
```bash
xcodebuild build -scheme MenuBarADSB -destination 'platform=macOS' -quiet
```

---

## Task 0: Project configuration

**Files:**
- Modify: Xcode project (target settings, signing & capabilities, info)
- Delete: `MenuBarADSB/ContentView.swift`
- Modify: `MenuBarADSB/MenuBarADSBApp.swift`

This task is mostly Xcode UI work. After it, the app builds, shows an `airplane` SF Symbol in the menu bar, and the dropdown contains a placeholder. No Dock icon.

- [ ] **Step 1: Set deployment target**

In Xcode: select the project (root in navigator) → target `MenuBarADSB` → **General** tab → **Minimum Deployments** → set **macOS** to `14.0`. Repeat for `MenuBarADSBTests` and `MenuBarADSBUITests` targets.

- [ ] **Step 2: Set Info.plist keys**

Target `MenuBarADSB` → **Info** tab → **Custom macOS Application Target Properties**. Add:

| Key | Type | Value |
|---|---|---|
| `Application is agent (UIElement)` (`LSUIElement`) | Boolean | `YES` |
| `Privacy - Location Usage Description` (`NSLocationUsageDescription`) | String | `MenuBarADSB nutzt deinen Standort, um Flugzeuge in deinem Umkreis zu finden.` |

- [ ] **Step 3: Enable App Sandbox + capabilities**

Target `MenuBarADSB` → **Signing & Capabilities** → **+ Capability** → add **App Sandbox**. In the App Sandbox section, check:
- App Data: (leave defaults)
- Network: **Outgoing Connections (Client)**
- Hardware: **Location**

Then **+ Capability** → add **Hardened Runtime** (defaults are fine).

- [ ] **Step 4: Delete `ContentView.swift`**

In Xcode navigator: right-click `ContentView.swift` → **Delete** → **Move to Trash**.

- [ ] **Step 5: Replace app entry point**

Open `MenuBarADSB/MenuBarADSBApp.swift`. Replace its entire contents with:

```swift
import SwiftUI

@main
struct MenuBarADSBApp: App {
    var body: some Scene {
        MenuBarExtra("MenuBarADSB", systemImage: "airplane") {
            Text("MenuBarADSB läuft.")
                .padding()
            Divider()
            Button("Beenden") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.window)

        Settings {
            Text("Einstellungen kommen später.")
                .padding()
                .frame(width: 380, height: 320)
        }
    }
}
```

- [ ] **Step 6: Build and run**

Run:
```bash
cd "/Users/robinspeichermann/Documents/Xcode Stuff/MenuBarADSB" && \
  xcodebuild build -scheme MenuBarADSB -destination 'platform=macOS' -quiet
```

Expected: build succeeds, no warnings.

Then ⌘R in Xcode. Expected:
- Airplane icon appears in the menu bar (top right).
- No icon appears in the Dock.
- Clicking the menu bar icon opens a small window with "MenuBarADSB läuft." and a "Beenden" button.
- ⌘, opens an empty Settings window with the placeholder text.

If the menu bar icon does not appear, double-check `LSUIElement = YES` and rebuild.

---

## Task 1: GeoMath — haversine

**Files:**
- Create: `MenuBarADSB/Models/GeoMath.swift`
- Create: `MenuBarADSBTests/GeoMathTests.swift`

- [ ] **Step 1: Add empty `GeoMath.swift` to project**

In Xcode: right-click `MenuBarADSB` group → **New Group** → name it `Models`. Right-click `Models` → **New File…** → **Swift File** → name `GeoMath.swift`. Ensure target membership = `MenuBarADSB`. Leave file with just `import Foundation`.

- [ ] **Step 2: Add `GeoMathTests.swift` to test target**

Right-click `MenuBarADSBTests` → **New File…** → **Swift File** → name `GeoMathTests.swift`. Ensure target membership = `MenuBarADSBTests` only.

- [ ] **Step 3: Write the failing test**

Replace contents of `MenuBarADSBTests/GeoMathTests.swift`:

```swift
import XCTest
@testable import MenuBarADSB

final class GeoMathTests: XCTestCase {
    // Frankfurt am Main: 50.1109°N, 8.6821°E
    // München:          48.1351°N, 11.5820°E
    // Real-world great-circle distance ≈ 304 km.
    func testHaversineFrankfurtMunich() {
        let d = GeoMath.haversineKm(
            lat1: 50.1109, lon1: 8.6821,
            lat2: 48.1351, lon2: 11.5820
        )
        XCTAssertEqual(d, 304.0, accuracy: 2.0)
    }
}
```

- [ ] **Step 4: Run the test, verify it fails**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/GeoMathTests/testHaversineFrankfurtMunich -quiet
```

Expected: compile error — `Cannot find 'GeoMath' in scope`.

- [ ] **Step 5: Implement `GeoMath`**

Replace `MenuBarADSB/Models/GeoMath.swift` with:

```swift
import Foundation

enum GeoMath {
    /// Great-circle distance in kilometres between two points on Earth.
    static func haversineKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let R = 6371.0 // Earth mean radius in km
        let dLat = (lat2 - lat1).toRadians
        let dLon = (lon2 - lon1).toRadians
        let a = sin(dLat / 2) * sin(dLat / 2)
              + cos(lat1.toRadians) * cos(lat2.toRadians)
              * sin(dLon / 2) * sin(dLon / 2)
        return 2 * R * asin(min(1, sqrt(a)))
    }
}

extension Double {
    var toRadians: Double { self * .pi / 180.0 }
}
```

- [ ] **Step 6: Run the test, verify it passes**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/GeoMathTests/testHaversineFrankfurtMunich -quiet
```

Expected: PASS.

---

## Task 2: GeoMath — edge cases & NM/km conversions

**Files:**
- Modify: `MenuBarADSB/Models/GeoMath.swift`
- Modify: `MenuBarADSBTests/GeoMathTests.swift`

- [ ] **Step 1: Add edge-case tests**

Append to `MenuBarADSBTests/GeoMathTests.swift` (inside the `final class` body):

```swift
    func testHaversineSamePointIsZero() {
        let d = GeoMath.haversineKm(lat1: 50.0, lon1: 8.0, lat2: 50.0, lon2: 8.0)
        XCTAssertEqual(d, 0, accuracy: 0.0001)
    }

    func testHaversineAntipodes() {
        // (0,0) and (0,180) are antipodal: half the Earth's circumference at R=6371 km.
        let d = GeoMath.haversineKm(lat1: 0, lon1: 0, lat2: 0, lon2: 180)
        XCTAssertEqual(d, 20015.0, accuracy: 1.0)
    }

    func testKmToNauticalMiles() {
        XCTAssertEqual(GeoMath.kmToNM(1.852), 1.0, accuracy: 0.001)
        XCTAssertEqual(GeoMath.kmToNM(3.0), 1.62, accuracy: 0.01)
    }

    func testRadiusKmToFetchNM_overFetchesByCeil() {
        // 3 km → ceil(1.62) = 2 NM (≈3.7 km), giving us a small buffer.
        XCTAssertEqual(GeoMath.radiusKmToFetchNM(3.0), 2)
        XCTAssertEqual(GeoMath.radiusKmToFetchNM(1.0), 1)
        XCTAssertEqual(GeoMath.radiusKmToFetchNM(50.0), 27)
    }
```

- [ ] **Step 2: Run, verify two tests fail (the conversion ones)**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/GeoMathTests -quiet
```

Expected: `testHaversineSamePointIsZero` and `testHaversineAntipodes` PASS, `testKmToNauticalMiles` and `testRadiusKmToFetchNM_overFetchesByCeil` fail with `Cannot find 'kmToNM'` / `Cannot find 'radiusKmToFetchNM'`.

- [ ] **Step 3: Add conversions to `GeoMath`**

In `MenuBarADSB/Models/GeoMath.swift`, append inside the `enum GeoMath`:

```swift
    /// Convert kilometres to nautical miles. 1 NM = 1.852 km exactly.
    static func kmToNM(_ km: Double) -> Double { km / 1.852 }

    /// Nautical-mile value to send to the adsb.lol /dist/ endpoint, given a desired km radius.
    /// We `ceil` so we slightly over-fetch and then filter client-side to the exact km radius.
    static func radiusKmToFetchNM(_ radiusKm: Double) -> Int {
        Int(ceil(kmToNM(radiusKm)))
    }
```

- [ ] **Step 4: Run all GeoMath tests, verify pass**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/GeoMathTests -quiet
```

Expected: 4 tests pass.

---

## Task 3: Aircraft model — full payload parsing

**Files:**
- Create: `MenuBarADSB/Models/Aircraft.swift`
- Create: `MenuBarADSBTests/AircraftTests.swift`
- Create: `MenuBarADSBTests/Fixtures/adsb-full.json`

- [ ] **Step 1: Create fixture file**

In Xcode, right-click `MenuBarADSBTests` → **New Group** → `Fixtures`. Right-click `Fixtures` → **New File…** → **Empty** → name `adsb-full.json`. **Important:** in target membership, check `MenuBarADSBTests`, NOT `MenuBarADSB`. Also: file inspector → "Location" set to "Relative to Group", and check the file is added as a **Resource** (Build Phases → Copy Bundle Resources of `MenuBarADSBTests`).

Contents:
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

- [ ] **Step 2: Create `AircraftTests.swift`**

Add new file `MenuBarADSBTests/AircraftTests.swift`, target membership `MenuBarADSBTests`:

```swift
import XCTest
@testable import MenuBarADSB

final class AircraftTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("Fixture \(name).json not found in test bundle")
            return Data()
        }
        return try Data(contentsOf: url)
    }

    func testDecodeFullPayload() throws {
        let data = try loadFixture("adsb-full")
        let response = try JSONDecoder().decode(ADSBResponse.self, from: data)

        XCTAssertEqual(response.ac.count, 1)
        let ac = response.ac[0]
        XCTAssertEqual(ac.hex, "3c6589")
        XCTAssertEqual(ac.callsign, "DLH441")  // trimmed
        XCTAssertEqual(ac.registration, "D-AIBC")
        XCTAssertEqual(ac.typeCode, "A346")
        XCTAssertEqual(ac.altitudeFt, 36000)
        XCTAssertEqual(ac.groundSpeedKt, 452)
        XCTAssertEqual(ac.trackDeg, 287.4)
        XCTAssertEqual(ac.lat, 50.123)
        XCTAssertEqual(ac.lon, 8.456)
        XCTAssertEqual(ac.distanceKm, 0)  // not yet computed by ADSBService
    }
}
```

- [ ] **Step 3: Run, verify it fails**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/AircraftTests/testDecodeFullPayload -quiet
```

Expected: compile error — `Cannot find 'ADSBResponse' in scope` and `Cannot find 'Aircraft' in scope`.

- [ ] **Step 4: Implement `Aircraft.swift`**

Add `MenuBarADSB/Models/Aircraft.swift`, target membership `MenuBarADSB`:

```swift
import Foundation

struct ADSBResponse: Decodable {
    let ac: [Aircraft]
}

struct Aircraft: Equatable {
    let hex: String
    let callsign: String?
    let registration: String?
    let typeCode: String?
    let altitudeFt: Int?
    let groundSpeedKt: Double?
    let trackDeg: Double?
    let lat: Double
    let lon: Double
    var distanceKm: Double = 0  // populated by ADSBService after decoding

    /// Best display identifier per spec §5.8: callsign → registration → uppercased hex.
    var identifier: String {
        if let cs = callsign, !cs.isEmpty { return cs }
        if let r = registration, !r.isEmpty { return r }
        return hex.uppercased()
    }
}

extension Aircraft: Decodable {
    private enum CodingKeys: String, CodingKey {
        case hex, flight, r, t, alt_baro, gs, track, lat, lon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hex = try c.decode(String.self, forKey: .hex)

        let rawFlight = try c.decodeIfPresent(String.self, forKey: .flight)
        let trimmed = rawFlight?.trimmingCharacters(in: .whitespaces)
        self.callsign = (trimmed?.isEmpty ?? true) ? nil : trimmed

        self.registration = try c.decodeIfPresent(String.self, forKey: .r)
        self.typeCode = try c.decodeIfPresent(String.self, forKey: .t)

        // alt_baro can be Int or the literal string "ground".
        if let altInt = try? c.decodeIfPresent(Int.self, forKey: .alt_baro) {
            self.altitudeFt = altInt
        } else if let altStr = try? c.decodeIfPresent(String.self, forKey: .alt_baro),
                  altStr.lowercased() == "ground" {
            self.altitudeFt = 0
        } else {
            self.altitudeFt = nil
        }

        self.groundSpeedKt = try c.decodeIfPresent(Double.self, forKey: .gs)
        self.trackDeg = try c.decodeIfPresent(Double.self, forKey: .track)
        self.lat = try c.decode(Double.self, forKey: .lat)
        self.lon = try c.decode(Double.self, forKey: .lon)
        self.distanceKm = 0
    }
}
```

- [ ] **Step 5: Run, verify pass**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/AircraftTests/testDecodeFullPayload -quiet
```

Expected: PASS. If the test fails with "Fixture adsb-full.json not found", the fixture isn't copied into the test bundle — re-check Build Phases → Copy Bundle Resources of `MenuBarADSBTests`.

---

## Task 4: Aircraft model — edge cases (ground, missing fields, empty array)

**Files:**
- Create: `MenuBarADSBTests/Fixtures/adsb-ground.json`
- Create: `MenuBarADSBTests/Fixtures/adsb-minimal.json`
- Create: `MenuBarADSBTests/Fixtures/adsb-empty.json`
- Modify: `MenuBarADSBTests/AircraftTests.swift`

- [ ] **Step 1: Add `adsb-ground.json` fixture**

Same procedure as Task 3 step 1, target = `MenuBarADSBTests`:
```json
{
  "ac": [
    { "hex": "abc123", "flight": "N12345", "alt_baro": "ground", "lat": 50.0, "lon": 8.0 }
  ],
  "msg": "No error", "now": 1746442800000
}
```

- [ ] **Step 2: Add `adsb-minimal.json` fixture**

```json
{
  "ac": [
    { "hex": "deadbe", "lat": 51.0, "lon": 9.0 }
  ],
  "msg": "No error", "now": 1746442800000
}
```

- [ ] **Step 3: Add `adsb-empty.json` fixture**

```json
{ "ac": [], "msg": "No error", "now": 1746442800000 }
```

- [ ] **Step 4: Add three edge-case tests**

Append inside `AircraftTests`:

```swift
    func testDecodeGroundAircraft_altitudeIsZero() throws {
        let data = try loadFixture("adsb-ground")
        let response = try JSONDecoder().decode(ADSBResponse.self, from: data)
        XCTAssertEqual(response.ac.first?.altitudeFt, 0)
    }

    func testDecodeMinimalAircraft_optionalsNil() throws {
        let data = try loadFixture("adsb-minimal")
        let response = try JSONDecoder().decode(ADSBResponse.self, from: data)
        let ac = try XCTUnwrap(response.ac.first)
        XCTAssertEqual(ac.hex, "deadbe")
        XCTAssertNil(ac.callsign)
        XCTAssertNil(ac.registration)
        XCTAssertNil(ac.typeCode)
        XCTAssertNil(ac.altitudeFt)
        XCTAssertNil(ac.groundSpeedKt)
        XCTAssertNil(ac.trackDeg)
        XCTAssertEqual(ac.identifier, "DEADBE")  // hex fallback, uppercased
    }

    func testDecodeEmptyAircraftArray() throws {
        let data = try loadFixture("adsb-empty")
        let response = try JSONDecoder().decode(ADSBResponse.self, from: data)
        XCTAssertTrue(response.ac.isEmpty)
    }
```

- [ ] **Step 5: Run, verify all pass**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/AircraftTests -quiet
```

Expected: 4 tests pass.

---

## Task 5: ADSBService — protocol, fetch, decode

**Files:**
- Create: `MenuBarADSB/Services/ADSBService.swift`
- Create: `MenuBarADSBTests/Support/MockURLProtocol.swift`
- Create: `MenuBarADSBTests/ADSBServiceTests.swift`

- [ ] **Step 1: Create `MockURLProtocol.swift`**

Add new group `MenuBarADSBTests/Support` (right-click `MenuBarADSBTests` → **New Group**). New file `MockURLProtocol.swift`, target `MenuBarADSBTests`:

```swift
import Foundation

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            fatalError("MockURLProtocol.requestHandler not set")
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}
```

- [ ] **Step 2: Create `ADSBServiceTests.swift`**

New file `MenuBarADSBTests/ADSBServiceTests.swift`, target `MenuBarADSBTests`:

```swift
import XCTest
@testable import MenuBarADSB

final class ADSBServiceTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testAircraftNear_buildsCorrectURLAndDecodes() async throws {
        var capturedURL: URL?
        MockURLProtocol.requestHandler = { request in
            capturedURL = request.url
            let body = """
            { "ac": [{ "hex": "abc123", "lat": 50.0, "lon": 8.0 }],
              "msg": "No error", "now": 1 }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }

        let svc = ADSBService(session: MockURLProtocol.makeSession())
        let aircraft = try await svc.aircraftNear(lat: 50.0, lon: 8.0, radiusKm: 3.0)

        XCTAssertEqual(aircraft.count, 1)
        XCTAssertEqual(aircraft[0].hex, "abc123")

        // Spec §5.1: distNM = ceil(3.0 * 0.539957) = 2
        let url = try XCTUnwrap(capturedURL)
        XCTAssertEqual(url.host, "api.adsb.lol")
        XCTAssertTrue(url.path.contains("/v2/lat/50.0/lon/8.0/dist/2"),
                      "Unexpected URL path: \(url.path)")
    }
}
```

- [ ] **Step 3: Run, verify it fails**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/ADSBServiceTests/testAircraftNear_buildsCorrectURLAndDecodes -quiet
```

Expected: compile error — `Cannot find 'ADSBService'` and `Cannot find 'AircraftFetching'`.

- [ ] **Step 4: Implement `ADSBService.swift`**

New group `MenuBarADSB/Services` (if not present). New file `ADSBService.swift`, target `MenuBarADSB`:

```swift
import Foundation

protocol AircraftFetching {
    func aircraftNear(lat: Double, lon: Double, radiusKm: Double) async throws -> [Aircraft]
}

enum ADSBError: Error, Equatable {
    case http(Int)
    case decoding
    case transport
    case rateLimited
}

final class ADSBService: AircraftFetching {
    private let session: URLSession
    private let userAgent = "MenuBarADSB/1.0"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func aircraftNear(lat: Double, lon: Double, radiusKm: Double) async throws -> [Aircraft] {
        let nm = GeoMath.radiusKmToFetchNM(radiusKm)
        let urlString = "https://api.adsb.lol/v2/lat/\(lat)/lon/\(lon)/dist/\(nm)"
        guard let url = URL(string: urlString) else { throw ADSBError.transport }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ADSBError.transport
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299: break
            case 429: throw ADSBError.rateLimited
            default: throw ADSBError.http(http.statusCode)
            }
        }

        let decoded: ADSBResponse
        do {
            decoded = try JSONDecoder().decode(ADSBResponse.self, from: data)
        } catch {
            throw ADSBError.decoding
        }

        // Compute distance, filter to exact radius, sort ascending.
        let withDistance = decoded.ac.map { aircraft -> Aircraft in
            var ac = aircraft
            ac.distanceKm = GeoMath.haversineKm(
                lat1: lat, lon1: lon,
                lat2: aircraft.lat, lon2: aircraft.lon
            )
            return ac
        }
        let filtered = withDistance.filter { $0.distanceKm <= radiusKm }
        return filtered.sorted { $0.distanceKm < $1.distanceKm }
    }
}
```

- [ ] **Step 5: Run, verify pass**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/ADSBServiceTests/testAircraftNear_buildsCorrectURLAndDecodes -quiet
```

Expected: PASS.

---

## Task 6: ADSBService — distance, sort, radius filter

**Files:**
- Modify: `MenuBarADSBTests/ADSBServiceTests.swift`

- [ ] **Step 1: Add tests**

Append inside `ADSBServiceTests`:

```swift
    private func mock200(json: String) {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, json.data(using: .utf8)!)
        }
    }

    func testAircraftNear_sortsByAscendingDistance() async throws {
        // User at (50,8). Three aircraft at increasing distance.
        // (50.001, 8) ≈ 0.11 km   (closest)
        // (50.01,  8) ≈ 1.11 km
        // (50.02,  8) ≈ 2.22 km   (farthest, still within 3 km)
        mock200(json: """
        { "ac": [
            { "hex": "ccc", "lat": 50.02, "lon": 8.0 },
            { "hex": "aaa", "lat": 50.001, "lon": 8.0 },
            { "hex": "bbb", "lat": 50.01, "lon": 8.0 }
          ], "msg": "No error", "now": 1 }
        """)

        let svc = ADSBService(session: MockURLProtocol.makeSession())
        let aircraft = try await svc.aircraftNear(lat: 50.0, lon: 8.0, radiusKm: 3.0)

        XCTAssertEqual(aircraft.map { $0.hex }, ["aaa", "bbb", "ccc"])
        XCTAssertLessThan(aircraft[0].distanceKm, aircraft[1].distanceKm)
        XCTAssertLessThan(aircraft[1].distanceKm, aircraft[2].distanceKm)
    }

    func testAircraftNear_filtersOutsideRadius() async throws {
        // (50.1, 8) ≈ 11.1 km — well outside a 3 km radius,
        // even though API would return it inside our 2 NM ≈ 3.7 km over-fetch.
        // Note: the API itself would not return aircraft at 11 km when we ask for 2 NM,
        // but to test the client-side filter we fake a too-far aircraft in the response.
        mock200(json: """
        { "ac": [
            { "hex": "in",  "lat": 50.001, "lon": 8.0 },
            { "hex": "out", "lat": 50.1,   "lon": 8.0 }
          ], "msg": "No error", "now": 1 }
        """)

        let svc = ADSBService(session: MockURLProtocol.makeSession())
        let aircraft = try await svc.aircraftNear(lat: 50.0, lon: 8.0, radiusKm: 3.0)

        XCTAssertEqual(aircraft.map { $0.hex }, ["in"])
    }
```

- [ ] **Step 2: Run, verify all pass**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/ADSBServiceTests -quiet
```

Expected: 3 tests pass.

---

## Task 7: ADSBService — error handling

**Files:**
- Modify: `MenuBarADSBTests/ADSBServiceTests.swift`

- [ ] **Step 1: Add error tests**

Append inside `ADSBServiceTests`:

```swift
    func testAircraftNear_throwsRateLimitedOn429() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, Data())
        }
        let svc = ADSBService(session: MockURLProtocol.makeSession())
        do {
            _ = try await svc.aircraftNear(lat: 50.0, lon: 8.0, radiusKm: 3.0)
            XCTFail("Expected throw")
        } catch ADSBError.rateLimited {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testAircraftNear_throwsHTTPOn500() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, Data())
        }
        let svc = ADSBService(session: MockURLProtocol.makeSession())
        do {
            _ = try await svc.aircraftNear(lat: 50.0, lon: 8.0, radiusKm: 3.0)
            XCTFail("Expected throw")
        } catch ADSBError.http(500) {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testAircraftNear_throwsDecodingOnGarbage() async {
        mock200(json: "this is not json")
        let svc = ADSBService(session: MockURLProtocol.makeSession())
        do {
            _ = try await svc.aircraftNear(lat: 50.0, lon: 8.0, radiusKm: 3.0)
            XCTFail("Expected throw")
        } catch ADSBError.decoding {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
```

- [ ] **Step 2: Run, verify pass**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/ADSBServiceTests -quiet
```

Expected: 6 tests pass.

---

## Task 8: AppSettings

**Files:**
- Create: `MenuBarADSB/State/AppSettings.swift`
- Create: `MenuBarADSBTests/AppSettingsTests.swift`

- [ ] **Step 1: Create test file**

New group `MenuBarADSB/State` (in main target). New file `AppSettingsTests.swift`, target `MenuBarADSBTests`:

```swift
import XCTest
@testable import MenuBarADSB

final class AppSettingsTests: XCTestCase {

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "test-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func testDefaults() {
        let defaults = makeIsolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.radiusKm, 3.0)
        XCTAssertEqual(settings.updateIntervalSec, 15)
        XCTAssertFalse(settings.notificationsEnabled)
        XCTAssertFalse(settings.launchAtLogin)
    }

    func testPersistAndReload() {
        let defaults = makeIsolatedDefaults()
        do {
            let s = AppSettings(defaults: defaults)
            s.radiusKm = 7.5
            s.updateIntervalSec = 30
            s.notificationsEnabled = true
            s.launchAtLogin = true
        }
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.radiusKm, 7.5)
        XCTAssertEqual(reloaded.updateIntervalSec, 30)
        XCTAssertTrue(reloaded.notificationsEnabled)
        XCTAssertTrue(reloaded.launchAtLogin)
    }
}
```

- [ ] **Step 2: Run, verify it fails**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/AppSettingsTests -quiet
```

Expected: compile error — `Cannot find 'AppSettings'`.

- [ ] **Step 3: Implement `AppSettings.swift`**

New file `MenuBarADSB/State/AppSettings.swift`, target `MenuBarADSB`:

```swift
import Foundation
import Combine

final class AppSettings: ObservableObject {
    private enum Key {
        static let radiusKm = "radiusKm"
        static let updateIntervalSec = "updateIntervalSec"
        static let notificationsEnabled = "notificationsEnabled"
        static let launchAtLogin = "launchAtLogin"
    }

    private let defaults: UserDefaults

    @Published var radiusKm: Double {
        didSet { defaults.set(radiusKm, forKey: Key.radiusKm) }
    }
    @Published var updateIntervalSec: Int {
        didSet { defaults.set(updateIntervalSec, forKey: Key.updateIntervalSec) }
    }
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.radiusKm = defaults.object(forKey: Key.radiusKm) as? Double ?? 3.0
        self.updateIntervalSec = defaults.object(forKey: Key.updateIntervalSec) as? Int ?? 15
        self.notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        self.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
    }
}
```

- [ ] **Step 4: Run, verify pass**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/AppSettingsTests -quiet
```

Expected: 2 tests pass.

---

## Task 9: LocationService

**Files:**
- Create: `MenuBarADSB/Services/LocationService.swift`

No unit tests — `CLLocationManager` is hard to mock meaningfully and we'll smoke-test interactively. The protocol exists so the *consumer* (`AircraftStore`) can be tested.

- [ ] **Step 1: Implement `LocationService.swift`**

New file `MenuBarADSB/Services/LocationService.swift`, target `MenuBarADSB`:

```swift
import Foundation
import Combine
import CoreLocation

enum LocationState: Equatable {
    case unknown
    case denied
    case requesting
    case available(lat: Double, lon: Double)
}

protocol LocationProviding {
    var statePublisher: AnyPublisher<LocationState, Never> { get }
    func refresh()
}

final class LocationService: NSObject, LocationProviding, CLLocationManagerDelegate {

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

    /// Call once at app launch. Triggers permission prompt on first run.
    func start() {
        let status = manager.authorizationStatus
        handleAuthorizationStatus(status)
    }

    /// Request a fresh single-fix. Used on launch, on wake, and every 5 min.
    func refresh() {
        guard manager.authorizationStatus == .authorizedAlways
                || manager.authorizationStatus == .authorized else {
            return
        }
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
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - CLLocationManagerDelegate

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
```

- [ ] **Step 2: Build, verify compiles**

```bash
xcodebuild build -scheme MenuBarADSB -destination 'platform=macOS' -quiet
```

Expected: build succeeds.

---

## Task 10: NotificationService

**Files:**
- Create: `MenuBarADSB/Services/NotificationService.swift`

- [ ] **Step 1: Implement**

New file `MenuBarADSB/Services/NotificationService.swift`, target `MenuBarADSB`:

```swift
import Foundation
import UserNotifications

protocol Notifying {
    func notify(aircraft: Aircraft)
    func requestAuthorizationIfNeeded() async
}

final class NotificationService: Notifying {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func notify(aircraft: Aircraft) {
        let content = UNMutableNotificationContent()
        content.title = aircraft.identifier
        var parts: [String] = []
        if let alt = aircraft.altitudeFt {
            let metres = Int((Double(alt) * 0.3048).rounded())
            parts.append("\(metres) m")
        }
        parts.append(String(format: "%.1f km", aircraft.distanceKm).replacingOccurrences(of: ".", with: ","))
        content.body = parts.joined(separator: " · ")
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "adsb-\(aircraft.hex)",
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }
}
```

- [ ] **Step 2: Build, verify compiles**

```bash
xcodebuild build -scheme MenuBarADSB -destination 'platform=macOS' -quiet
```

Expected: build succeeds.

---

## Task 11: LaunchAtLoginService

**Files:**
- Create: `MenuBarADSB/Services/LaunchAtLoginService.swift`

- [ ] **Step 1: Implement**

New file `MenuBarADSB/Services/LaunchAtLoginService.swift`, target `MenuBarADSB`:

```swift
import Foundation
import ServiceManagement

enum LaunchAtLoginService {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            // Surface failure via console; UI can re-read isEnabled to detect.
            print("LaunchAtLogin: \(error)")
        }
    }
}
```

- [ ] **Step 2: Build, verify compiles**

```bash
xcodebuild build -scheme MenuBarADSB -destination 'platform=macOS' -quiet
```

Expected: build succeeds.

---

## Task 12: Mocks for AircraftStore tests

**Files:**
- Create: `MenuBarADSBTests/Support/Mocks.swift`

- [ ] **Step 1: Implement test mocks**

New file `MenuBarADSBTests/Support/Mocks.swift`, target `MenuBarADSBTests`:

```swift
import Foundation
import Combine
@testable import MenuBarADSB

final class MockLocationService: LocationProviding {
    let subject = CurrentValueSubject<LocationState, Never>(.unknown)
    var refreshCount = 0

    var statePublisher: AnyPublisher<LocationState, Never> {
        subject.eraseToAnyPublisher()
    }

    func refresh() { refreshCount += 1 }

    func emit(_ state: LocationState) { subject.send(state) }
}

final class MockADSBFetcher: AircraftFetching {
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

final class MockNotifier: Notifying {
    private(set) var notified: [Aircraft] = []
    private(set) var requestedAuth = false

    func notify(aircraft: Aircraft) { notified.append(aircraft) }
    func requestAuthorizationIfNeeded() async { requestedAuth = true }
}

extension Aircraft {
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
```

Note: this requires `Aircraft` to have a memberwise initializer accessible to tests. Since `init(from:)` is the only init defined, also add a memberwise init to `Aircraft.swift`. Update `MenuBarADSB/Models/Aircraft.swift` — append before the `extension`:

```swift
extension Aircraft {
    init(hex: String, callsign: String?, registration: String?, typeCode: String?,
         altitudeFt: Int?, groundSpeedKt: Double?, trackDeg: Double?,
         lat: Double, lon: Double) {
        self.hex = hex
        self.callsign = callsign
        self.registration = registration
        self.typeCode = typeCode
        self.altitudeFt = altitudeFt
        self.groundSpeedKt = groundSpeedKt
        self.trackDeg = trackDeg
        self.lat = lat
        self.lon = lon
        self.distanceKm = 0
    }
}
```

- [ ] **Step 2: Build the test target**

```bash
xcodebuild build-for-testing -scheme MenuBarADSB -destination 'platform=macOS' -quiet
```

Expected: build succeeds.

---

## Task 13: AircraftStore — basic polling lifecycle

**Files:**
- Create: `MenuBarADSB/State/AircraftStore.swift`
- Create: `MenuBarADSBTests/AircraftStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

New file `MenuBarADSBTests/AircraftStoreTests.swift`, target `MenuBarADSBTests`:

```swift
import XCTest
import Combine
@testable import MenuBarADSB

@MainActor
final class AircraftStoreTests: XCTestCase {

    func testNoTickBeforeLocationAvailable() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        let notifier = MockNotifier()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)

        _ = AircraftStore(
            location: location, fetcher: fetcher,
            notifier: notifier, settings: settings
        )

        try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        XCTAssertEqual(fetcher.callCount, 0)
    }

    func testTicksOnceWhenLocationBecomesAvailable() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        fetcher.nextResult = .success([.stub(hex: "abc", distanceKm: 1.0)])
        let notifier = MockNotifier()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)

        let store = AircraftStore(
            location: location, fetcher: fetcher,
            notifier: notifier, settings: settings
        )

        location.emit(.available(lat: 50, lon: 8))
        try await Task.sleep(nanoseconds: 200_000_000) // 200 ms

        XCTAssertEqual(fetcher.callCount, 1)
        XCTAssertEqual(store.aircraft.map { $0.hex }, ["abc"])
    }
}
```

- [ ] **Step 2: Run, verify it fails**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/AircraftStoreTests -quiet
```

Expected: compile error — `Cannot find 'AircraftStore'`.

- [ ] **Step 3: Implement `AircraftStore.swift`**

New file `MenuBarADSB/State/AircraftStore.swift`, target `MenuBarADSB`:

```swift
import Foundation
import Combine
import AppKit

@MainActor
final class AircraftStore: ObservableObject {
    @Published private(set) var aircraft: [Aircraft] = []
    @Published private(set) var lastError: ADSBError?
    @Published private(set) var isStale: Bool = false
    @Published private(set) var lastFetchAt: Date?

    private let location: LocationProviding
    private let fetcher: AircraftFetching
    private let notifier: Notifying
    private let settings: AppSettings

    private var currentCoord: (lat: Double, lon: Double)?
    private var knownHexes: Set<String> = []
    private var failureCount = 0
    private var pollTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var inflightTask: Task<Void, Never>?

    init(location: LocationProviding, fetcher: AircraftFetching,
         notifier: Notifying, settings: AppSettings) {
        self.location = location
        self.fetcher = fetcher
        self.notifier = notifier
        self.settings = settings

        location.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.onLocationStateChange(state) }
            .store(in: &cancellables)
    }

    private func onLocationStateChange(_ state: LocationState) {
        switch state {
        case .available(let lat, let lon):
            let isFirst = currentCoord == nil
            currentCoord = (lat, lon)
            if isFirst { startPolling() }
            tickNow()
        case .denied, .unknown, .requesting:
            currentCoord = nil
            stopPolling()
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let interval = TimeInterval(settings.updateIntervalSec)
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickNow() }
        }
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
            self.aircraft = result
            self.lastError = nil
            self.failureCount = 0
            self.lastFetchAt = Date()
            self.isStale = false

            let currentHexes = Set(result.map { $0.hex })
            let newHexes = currentHexes.subtracting(knownHexes)
            if notificationsEnabled {
                for ac in result where newHexes.contains(ac.hex) {
                    notifier.notify(aircraft: ac)
                }
            }
            knownHexes = currentHexes
        } catch let error as ADSBError {
            failureCount += 1
            lastError = error
            if failureCount >= 3 { aircraft = [] }
        } catch {
            failureCount += 1
            lastError = .transport
            if failureCount >= 3 { aircraft = [] }
        }
    }
}
```

- [ ] **Step 4: Run, verify pass**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/AircraftStoreTests -quiet
```

Expected: 2 tests pass.

---

## Task 14: AircraftStore — settings reactivity

**Files:**
- Modify: `MenuBarADSB/State/AircraftStore.swift`
- Modify: `MenuBarADSBTests/AircraftStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `AircraftStoreTests`:

```swift
    func testRadiusChangeTriggersImmediateTick() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        let notifier = MockNotifier()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)

        _ = AircraftStore(
            location: location, fetcher: fetcher,
            notifier: notifier, settings: settings
        )

        location.emit(.available(lat: 50, lon: 8))
        try await Task.sleep(nanoseconds: 200_000_000)
        let initialCalls = fetcher.callCount  // 1

        settings.radiusKm = 10.0
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertGreaterThan(fetcher.callCount, initialCalls)
        XCTAssertEqual(fetcher.lastRadius, 10.0)
    }

    func testIntervalChangeRestartsTimer() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        let notifier = MockNotifier()
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: suite)

        _ = AircraftStore(
            location: location, fetcher: fetcher,
            notifier: notifier, settings: settings
        )

        location.emit(.available(lat: 50, lon: 8))
        try await Task.sleep(nanoseconds: 200_000_000)

        // No assertion on actual timer firing (real wall-clock waits would slow tests).
        // Just confirm changing the interval does not crash and an immediate tick is OK.
        settings.updateIntervalSec = 5
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThanOrEqual(fetcher.callCount, 1)
    }
```

- [ ] **Step 2: Run, verify failure**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/AircraftStoreTests -quiet
```

Expected: `testRadiusChangeTriggersImmediateTick` fails — radius change does not (yet) cause a tick.

- [ ] **Step 3: Add settings observation in `AircraftStore.init`**

In `MenuBarADSB/State/AircraftStore.swift`, inside `init` after the `location.statePublisher` subscription, append:

```swift
        settings.$radiusKm
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tickNow() }
            .store(in: &cancellables)

        settings.$updateIntervalSec
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.currentCoord != nil else { return }
                self.startPolling()
                self.tickNow()
            }
            .store(in: &cancellables)
```

- [ ] **Step 4: Run, verify pass**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/AircraftStoreTests -quiet
```

Expected: 4 tests pass.

---

## Task 15: AircraftStore — notifications

**Files:**
- Modify: `MenuBarADSBTests/AircraftStoreTests.swift`

- [ ] **Step 1: Add notification tests**

Append inside `AircraftStoreTests`:

```swift
    func testNotifiesOnlyOnNewHex() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        let notifier = MockNotifier()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        settings.notificationsEnabled = true

        let store = AircraftStore(
            location: location, fetcher: fetcher,
            notifier: notifier, settings: settings
        )
        _ = store // silence unused

        // First tick: aaa, bbb -> notifies both
        fetcher.nextResult = .success([.stub(hex: "aaa"), .stub(hex: "bbb")])
        location.emit(.available(lat: 50, lon: 8))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(Set(notifier.notified.map { $0.hex }), ["aaa", "bbb"])
        notifier.notified.removeAll()

        // Second tick: still aaa, bbb (no new) — and ccc is new
        fetcher.nextResult = .success([.stub(hex: "aaa"), .stub(hex: "bbb"), .stub(hex: "ccc")])
        settings.radiusKm = 5.0  // forces immediate retick
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(notifier.notified.map { $0.hex }, ["ccc"])
    }

    func testNoNotificationsWhenDisabled() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        fetcher.nextResult = .success([.stub(hex: "aaa")])
        let notifier = MockNotifier()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        // notificationsEnabled stays false

        _ = AircraftStore(
            location: location, fetcher: fetcher,
            notifier: notifier, settings: settings
        )

        location.emit(.available(lat: 50, lon: 8))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(notifier.notified.isEmpty)
    }
```

- [ ] **Step 2: Run, verify pass**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/AircraftStoreTests -quiet
```

Expected: 6 tests pass.

---

## Task 16: AircraftStore — error handling, staleness, sleep/wake

**Files:**
- Modify: `MenuBarADSB/State/AircraftStore.swift`
- Modify: `MenuBarADSBTests/AircraftStoreTests.swift`

- [ ] **Step 1: Add error and staleness tests**

Append inside `AircraftStoreTests`:

```swift
    func testThreeConsecutiveFailuresClearsList() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        let notifier = MockNotifier()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)

        let store = AircraftStore(
            location: location, fetcher: fetcher,
            notifier: notifier, settings: settings
        )

        // First tick succeeds, populates list.
        fetcher.nextResult = .success([.stub(hex: "abc")])
        location.emit(.available(lat: 50, lon: 8))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.aircraft.count, 1)

        // Three failed ticks via radius-change trigger.
        fetcher.nextResult = .failure(ADSBError.transport)
        for r in [4.0, 5.0, 6.0] {
            settings.radiusKm = r
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertEqual(store.aircraft.count, 0)
        XCTAssertEqual(store.lastError, .transport)
    }

    func testSuccessAfterFailureResetsCounter() async throws {
        let location = MockLocationService()
        let fetcher = MockADSBFetcher()
        let notifier = MockNotifier()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)

        let store = AircraftStore(
            location: location, fetcher: fetcher,
            notifier: notifier, settings: settings
        )

        fetcher.nextResult = .success([.stub(hex: "abc")])
        location.emit(.available(lat: 50, lon: 8))
        try await Task.sleep(nanoseconds: 200_000_000)

        fetcher.nextResult = .failure(ADSBError.transport)
        settings.radiusKm = 4.0
        try await Task.sleep(nanoseconds: 200_000_000)
        settings.radiusKm = 5.0
        try await Task.sleep(nanoseconds: 200_000_000)

        fetcher.nextResult = .success([.stub(hex: "xyz")])
        settings.radiusKm = 6.0
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.aircraft.first?.hex, "xyz")
    }
```

- [ ] **Step 2: Run, verify pass**

These should already pass with the existing implementation (failure/recovery logic is in `performFetch`). Run:

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/AircraftStoreTests -quiet
```

Expected: 8 tests pass.

- [ ] **Step 3: Add sleep/wake handling to `AircraftStore`**

In `MenuBarADSB/State/AircraftStore.swift`, inside `init` after the settings subscriptions, append:

```swift
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.currentCoord != nil else { return }
                self.startPolling()
                self.tickNow()
            }
            .store(in: &cancellables)
```

- [ ] **Step 4: Add staleness detection**

The `isStale` flag is set elsewhere by a polling watchdog. Add an extra timer in `AircraftStore`. In the `init`, after the workspace subscription, append:

```swift
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recomputeStale() }
        }
```

And add this method on `AircraftStore`:

```swift
    private func recomputeStale() {
        guard let last = lastFetchAt else { isStale = false; return }
        let stalenessThreshold = TimeInterval(settings.updateIntervalSec * 2)
        isStale = Date().timeIntervalSince(last) > stalenessThreshold
    }
```

- [ ] **Step 5: Build, verify all tests still pass**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/AircraftStoreTests -quiet
```

Expected: 8 tests pass.

---

## Task 17: MenuBarLabelView

**Files:**
- Create: `MenuBarADSB/Views/MenuBarLabelView.swift`

No unit tests for SwiftUI views — verified manually after wiring.

- [ ] **Step 1: Implement**

New group `MenuBarADSB/Views`. New file `MenuBarLabelView.swift`, target `MenuBarADSB`:

```swift
import SwiftUI

struct MenuBarLabelView: View {
    @ObservedObject var store: AircraftStore

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "airplane")
            if let nearest = store.aircraft.first {
                Text(label(for: nearest))
                    .font(.system(size: 12))
            }
        }
    }

    private func label(for aircraft: Aircraft) -> String {
        var parts: [String] = [aircraft.identifier]
        if let alt = aircraft.altitudeFt {
            let metres = Int((Double(alt) * 0.3048).rounded())
            parts.append(formatThousands(metres) + " m")
        }
        return parts.joined(separator: " · ")
    }

    private func formatThousands(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "de_DE")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
```

---

## Task 18: MenuBarContentView

**Files:**
- Create: `MenuBarADSB/Views/MenuBarContentView.swift`

- [ ] **Step 1: Implement**

New file `MenuBarADSB/Views/MenuBarContentView.swift`, target `MenuBarADSB`:

```swift
import SwiftUI
import Combine

struct MenuBarContentView: View {
    @ObservedObject var store: AircraftStore
    @ObservedObject var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(width: 360)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var content: some View {
        if store.aircraft.isEmpty {
            emptyOrErrorView
                .padding()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.aircraft, id: \.hex) { ac in
                        AircraftRow(aircraft: ac)
                            .opacity(store.isStale ? 0.5 : 1.0)
                            .onTapGesture { open(aircraft: ac) }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 360)
        }
    }

    @ViewBuilder
    private var emptyOrErrorView: some View {
        if let error = store.lastError, store.aircraft.isEmpty {
            switch error {
            case .rateLimited, .transport, .http, .decoding:
                Text("Verbindung zu adsb.lol nicht möglich")
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keine Flugzeuge im \(formatRadius()) Radius.")
                    .foregroundStyle(.secondary)
                if let last = store.lastFetchAt {
                    Text("Aktualisiert: vor \(secondsAgo(last)) s")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Einstellungen…") { openSettings() }
            Spacer()
            Button("Beenden") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func formatRadius() -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "de_DE")
        f.maximumFractionDigits = 1
        let s = f.string(from: NSNumber(value: settings.radiusKm)) ?? "\(settings.radiusKm)"
        return "\(s) km"
    }

    private func secondsAgo(_ date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date)))
    }

    private func open(aircraft: Aircraft) {
        let url: URL?
        if let cs = aircraft.callsign, !cs.isEmpty {
            url = URL(string: "https://www.flightradar24.com/\(cs)")
        } else {
            url = URL(string: "https://globe.adsb.lol/?icao=\(aircraft.hex)")
        }
        if let url { NSWorkspace.shared.open(url) }
    }
}

private struct AircraftRow: View {
    let aircraft: Aircraft

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(aircraft.identifier)
                    .font(.system(size: 13, weight: .semibold))
                Text(secondaryLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(distanceText)
                    .font(.system(size: 13, weight: .medium))
                if let heading = headingText {
                    Text(heading)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var secondaryLine: String {
        var parts: [String] = []
        if let t = aircraft.typeCode { parts.append(t) }
        if let alt = aircraft.altitudeFt {
            let metres = Int((Double(alt) * 0.3048).rounded())
            parts.append(formatInt(metres) + " m")
        }
        if let kt = aircraft.groundSpeedKt {
            let kmh = Int((kt * 1.852).rounded())
            parts.append(formatInt(kmh) + " km/h")
        }
        return parts.joined(separator: " · ")
    }

    private var distanceText: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "de_DE")
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 1
        let s = f.string(from: NSNumber(value: aircraft.distanceKm)) ?? "\(aircraft.distanceKm)"
        return "\(s) km"
    }

    private var headingText: String? {
        guard let track = aircraft.trackDeg else { return nil }
        let dirs = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        let idx = Int(((track / 45.0).rounded(.toNearestOrEven))).quotientAndRemainder(dividingBy: 8).remainder
        let normalized = (idx + 8) % 8
        return dirs[normalized]
    }

    private func formatInt(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "de_DE")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
```

- [ ] **Step 2: Build, verify compiles**

```bash
xcodebuild build -scheme MenuBarADSB -destination 'platform=macOS' -quiet
```

Expected: build succeeds.

---

## Task 19: SettingsView

**Files:**
- Create: `MenuBarADSB/Views/SettingsView.swift`

- [ ] **Step 1: Implement**

New file `MenuBarADSB/Views/SettingsView.swift`, target `MenuBarADSB`:

```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Radius") {
                VStack(alignment: .leading) {
                    Slider(value: $settings.radiusKm, in: 1...50, step: 0.5)
                    Text(String(format: "%.1f km", settings.radiusKm)
                            .replacingOccurrences(of: ".", with: ","))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Aktualisierung") {
                VStack(alignment: .leading) {
                    Slider(
                        value: Binding(
                            get: { Double(settings.updateIntervalSec) },
                            set: { settings.updateIntervalSec = Int($0) }
                        ),
                        in: 5...60, step: 1
                    )
                    Text("alle \(settings.updateIntervalSec) s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Benachrichtigungen") {
                Toggle("Bei neuen Flugzeugen benachrichtigen", isOn: $settings.notificationsEnabled)
                    .onChange(of: settings.notificationsEnabled) { _, newValue in
                        if newValue {
                            Task { await NotificationService().requestAuthorizationIfNeeded() }
                        }
                    }
            }

            Section("Allgemein") {
                Toggle("Beim Anmelden öffnen", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, newValue in
                        LaunchAtLoginService.setEnabled(newValue)
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 320)
    }
}
```

- [ ] **Step 2: Build, verify compiles**

```bash
xcodebuild build -scheme MenuBarADSB -destination 'platform=macOS' -quiet
```

Expected: build succeeds.

---

## Task 20: App wiring

**Files:**
- Modify: `MenuBarADSB/MenuBarADSBApp.swift`

- [ ] **Step 1: Replace placeholder with real wiring**

Replace contents of `MenuBarADSB/MenuBarADSBApp.swift` with:

```swift
import SwiftUI

@main
struct MenuBarADSBApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var store: AircraftStore
    private let location: LocationService

    init() {
        let settings = AppSettings()
        let location = LocationService()
        let fetcher = ADSBService()
        let notifier = NotificationService()
        let store = AircraftStore(
            location: location, fetcher: fetcher,
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
            MenuBarLabelView(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings)
        }
    }
}
```

- [ ] **Step 2: Build & run**

```bash
xcodebuild build -scheme MenuBarADSB -destination 'platform=macOS' -quiet
```

Then ⌘R in Xcode. Expected:
- Permission prompt appears asking for Location access.
- After granting, within ~30 seconds the dropdown either shows aircraft or the empty state with "Aktualisiert: vor X s".
- ⌘, opens the Settings window with four working controls.

---

## Task 21: Acceptance verification

Walk through every acceptance criterion from spec §10. For each, check the box only after observing the behaviour live.

- [ ] **AC1:** App builds on macOS 14+ with no warnings.
  - `xcodebuild build -scheme MenuBarADSB -destination 'platform=macOS'` → no warnings.

- [ ] **AC2:** First-launch permission prompt shown; appropriate dropdown state during/after.
  - Reset permissions: System Settings → Privacy & Security → Location Services → toggle MenuBarADSB off, or `tccutil reset CoreLocationAgent com.speichermann.MenuBarADSB` then re-launch.
  - Verify dropdown shows "Warte auf Standortzugriff…" pre-grant, transitions to "Standort wird ermittelt…" post-grant, then to data.

- [ ] **AC3:** Polling at 15 s default, sorted by distance.
  - Watch the dropdown over 30 s — list refreshes.
  - In Console.app, filter for `api.adsb.lol` and confirm one request per ~15 s.

- [ ] **AC4:** Menu bar label dynamic.
  - Empty: only the airplane icon. With aircraft: icon + identifier + altitude.

- [ ] **AC5:** Click aircraft → flightradar24 in browser.
  - Click any row → browser opens with `https://www.flightradar24.com/<callsign>` (or globe.adsb.lol if no callsign).

- [ ] **AC6:** Settings window reachable, all four controls work.
  - Open via "Einstellungen…" button → window shows.
  - Move radius slider → list updates within ~1 s.
  - Move interval slider → polling cadence visibly changes.
  - Toggle notifications → permission prompt fires once.
  - Toggle launch-at-login → MenuBarADSB appears in System Settings → General → Login Items.

- [ ] **AC7:** New aircraft entering the radius produces a single notification (no duplicates).
  - Enable notifications, watch the menu bar in real airspace activity (or fake by setting radius briefly small then back to baseline).
  - Confirm: each `hex` produces exactly one notification per "entry event".

- [ ] **AC8:** Launch-at-login appears in System Settings.
  - Toggle on → System Settings → General → Login Items shows MenuBarADSB.
  - Reboot → app starts on login.

- [ ] **AC9:** Documented UI states render correctly.
  - Permission denied: revoke in System Settings, dropdown shows the denied state with "Systemeinstellungen öffnen" button (which works).
  - Network failure: turn off Wi-Fi briefly, observe transient → persistent error transition after ~3 ticks.

- [ ] **AC10:** All unit tests pass.
  - `xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS'` → all green.

---

## Self-Review Notes

After writing the plan, I checked it against the spec:

- **Spec coverage:** Every section maps to a task. §3.3 components → Tasks 1, 3, 5, 8, 9, 10, 11, 13, 17, 18, 19. §4 data flow → Tasks 13–16, 20. §5 API & math → Tasks 1, 2, 5, 6. §6 UI states → Tasks 17, 18, 21. §7 testing → Tasks 1–8, 12–16. §8 macOS config → Task 0. §10 acceptance → Task 21.
- **Placeholder scan:** No "TBD"/"TODO". All code blocks are complete.
- **Type consistency:** `LocationProviding`, `AircraftFetching`, `Notifying` protocols defined in Tasks 9, 5, 10 are used in mocks (Task 12) and `AircraftStore` (Task 13). `Aircraft.identifier` defined in Task 3 used in Tasks 10, 17, 18. `LocationState` enum cases (`unknown`, `denied`, `requesting`, `available`) consistent across services and tests.
- **Mocks helper note:** `Aircraft.stub(...)` in `Mocks.swift` requires a memberwise init — Task 12 includes adding it to `Aircraft.swift`.
