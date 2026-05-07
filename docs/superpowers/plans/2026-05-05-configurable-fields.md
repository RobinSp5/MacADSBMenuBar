# Configurable Display Fields & Route Enrichment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add user-configurable per-aircraft display fields (independent for menu bar and dropdown) plus airline + origin/destination route enrichment via the adsbdb API.

**Architecture:** A new `RouteService` (mirroring `ADSBService`) fetches route info per callsign. `AircraftStore` caches results in-memory and merges them into the published aircraft list. Two new `Set<DisplayField>` properties on `AppSettings` drive what each view renders, with a centralised formatter on `Aircraft`.

**Tech Stack:** Swift 5.9+, SwiftUI, Combine, async/await, XCTest. No new third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-05-05-configurable-fields-design.md`.

**Note:** This project is NOT a git repository — plan omits `git commit` steps. Each task is its own natural checkpoint.

---

## File Structure

### Created files

| Path | Responsibility |
|---|---|
| `MenuBarADSB/Models/DisplayField.swift` | Enum of toggleable fields + canonical render order. |
| `MenuBarADSB/Services/RouteService.swift` | adsbdb HTTP client + `RouteFetching` protocol. |
| `MenuBarADSBTests/RouteServiceTests.swift` | URL building + JSON parsing + error tests. |
| `MenuBarADSBTests/Fixtures/route-full.json` | Successful response with full route data. |
| `MenuBarADSBTests/Fixtures/route-partial.json` | Successful response with only origin filled. |

### Modified files

| Path | Change |
|---|---|
| `MenuBarADSB/Models/Aircraft.swift` | Add `airline`, `originIATA`, `destinationIATA` properties. Add `RouteInfo` struct. Add `formattedValue(for:)` extension. Update memberwise init. |
| `MenuBarADSB/State/AppSettings.swift` | Add `menuBarFields` + `dropdownFields` with comma-separated string persistence. |
| `MenuBarADSB/State/AircraftStore.swift` | Inject `RouteFetching`. Add `RouteCacheEntry` enum, `routeCache`, `pendingRouteFetches`. Implement `enrichVisibleAircraft`. |
| `MenuBarADSB/Views/MenuBarLabelView.swift` | Dynamic field rendering driven by `settings.menuBarFields`. Inject `AppSettings`. |
| `MenuBarADSB/Views/MenuBarContentView.swift` | `AircraftRow` rewritten to read `settings.dropdownFields` and render accordingly. |
| `MenuBarADSB/Views/SettingsView.swift` | Two new sections with field toggles. Helper for binding to `Set<DisplayField>`. |
| `MenuBarADSB/MenuBarADSBApp.swift` | Construct `RouteService`, pass through to `AircraftStore` and `MenuBarLabelView`. |
| `MenuBarADSBTests/Support/Mocks.swift` | Add `MockRouteFetcher`. |
| `MenuBarADSBTests/AircraftStoreTests.swift` | New tests for enrichment, caching, negative caching, route-failure isolation. Update existing tests' `AircraftStore(...)` calls to pass a `MockRouteFetcher`. |
| `MenuBarADSBTests/AppSettingsTests.swift` | New tests for `menuBarFields` / `dropdownFields` defaults, persistence, decoding. |
| `MenuBarADSBTests/AircraftTests.swift` | New tests for `Aircraft.formattedValue(for:)` mappings. |

---

## Test commands

Reuses the existing scheme. From project root `/Users/robinspeichermann/Documents/Xcode Stuff/MenuBarADSB`:

```bash
# Full suite
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' -quiet

# Single test
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/<Class>/<test> -quiet

# Build only
xcodebuild build -scheme MenuBarADSB -destination 'platform=macOS' -quiet
```

---

## Task 1: DisplayField enum + Aircraft model extensions

**Files:**
- Create: `MenuBarADSB/Models/DisplayField.swift`
- Modify: `MenuBarADSB/Models/Aircraft.swift`
- Modify: `MenuBarADSBTests/AircraftTests.swift`

- [ ] **Step 1: Create DisplayField.swift**

```swift
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
```

- [ ] **Step 2: Add new fields, RouteInfo, and formatter to Aircraft.swift**

In `MenuBarADSB/Models/Aircraft.swift`:

(a) Add three new stored properties to the `Aircraft` struct, immediately after the existing `var distanceKm: Double = 0` line:

```swift
    var airline: String? = nil
    var originIATA: String? = nil
    var destinationIATA: String? = nil
```

(b) Update the memberwise init in the existing `nonisolated extension Aircraft { init(hex:...) }` block to take three new optional parameters with `nil` defaults and assign them. Replace the entire init block with:

```swift
    init(hex: String, callsign: String?, registration: String?, typeCode: String?,
         altitudeFt: Int?, groundSpeedKt: Double?, trackDeg: Double?,
         lat: Double, lon: Double,
         airline: String? = nil, originIATA: String? = nil, destinationIATA: String? = nil) {
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
        self.airline = airline
        self.originIATA = originIATA
        self.destinationIATA = destinationIATA
    }
```

(c) Append a new `RouteInfo` struct at the bottom of the file:

```swift
nonisolated struct RouteInfo: Equatable, Sendable {
    let airline: String?
    let originIATA: String?
    let destinationIATA: String?
}
```

(d) Append a new extension that adds the formatter:

```swift
nonisolated extension Aircraft {
    /// Human-readable representation of a single field for display, or nil if no value.
    func formattedValue(for field: DisplayField) -> String? {
        switch field {
        case .airline:
            return airline
        case .route:
            return formattedRoute
        case .aircraftType:
            return typeCode
        case .altitude:
            return altitudeFt.map { formatThousands(Int((Double($0) * 0.3048).rounded())) + " m" }
        case .speed:
            return groundSpeedKt.map { formatThousands(Int(($0 * 1.852).rounded())) + " km/h" }
        case .distance:
            return formattedDistance
        case .heading:
            return formattedHeading
        }
    }

    private var formattedRoute: String? {
        switch (originIATA, destinationIATA) {
        case (nil, nil): return nil
        case (let o?, let d?): return "\(o) → \(d)"
        case (let o?, nil): return "\(o) →"
        case (nil, let d?): return "→ \(d)"
        }
    }

    private var formattedDistance: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "de_DE")
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 1
        let s = f.string(from: NSNumber(value: distanceKm)) ?? "\(distanceKm)"
        return "\(s) km"
    }

    private var formattedHeading: String? {
        guard let track = trackDeg else { return nil }
        let dirs = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        let idx = ((Int(track / 45.0 + 0.5)) % 8 + 8) % 8
        return dirs[idx]
    }

    private func formatThousands(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "de_DE")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
```

- [ ] **Step 3: Add Aircraft formatter tests**

Append the following test methods inside the existing `AircraftTests` class in `MenuBarADSBTests/AircraftTests.swift`:

```swift
    private func makeAircraft(altitudeFt: Int? = 36000, groundSpeedKt: Double? = 452,
                              trackDeg: Double? = 0,
                              originIATA: String? = nil, destinationIATA: String? = nil,
                              airline: String? = nil) -> Aircraft {
        var ac = Aircraft(
            hex: "abc", callsign: "DLH441", registration: nil, typeCode: "A346",
            altitudeFt: altitudeFt, groundSpeedKt: groundSpeedKt, trackDeg: trackDeg,
            lat: 50, lon: 8,
            airline: airline, originIATA: originIATA, destinationIATA: destinationIATA
        )
        ac.distanceKm = 2.4
        return ac
    }

    func testFormattedAltitude() {
        let ac = makeAircraft()
        // 36000 ft × 0.3048 = 10972.8 m → 10.973 m (German thousands separator)
        XCTAssertEqual(ac.formattedValue(for: .altitude), "10.973 m")
    }

    func testFormattedSpeed() {
        let ac = makeAircraft()
        // 452 kt × 1.852 = 837.1 km/h → 837 km/h
        XCTAssertEqual(ac.formattedValue(for: .speed), "837 km/h")
    }

    func testFormattedDistance() {
        let ac = makeAircraft()
        XCTAssertEqual(ac.formattedValue(for: .distance), "2,4 km")
    }

    func testFormattedAircraftType() {
        let ac = makeAircraft()
        XCTAssertEqual(ac.formattedValue(for: .aircraftType), "A346")
    }

    func testFormattedHeading_eachQuadrant() {
        XCTAssertEqual(makeAircraft(trackDeg: 0).formattedValue(for: .heading), "N")
        XCTAssertEqual(makeAircraft(trackDeg: 45).formattedValue(for: .heading), "NO")
        XCTAssertEqual(makeAircraft(trackDeg: 90).formattedValue(for: .heading), "O")
        XCTAssertEqual(makeAircraft(trackDeg: 180).formattedValue(for: .heading), "S")
        XCTAssertEqual(makeAircraft(trackDeg: 270).formattedValue(for: .heading), "W")
        XCTAssertEqual(makeAircraft(trackDeg: 359).formattedValue(for: .heading), "N")
    }

    func testFormattedHeading_nilWhenTrackMissing() {
        XCTAssertNil(makeAircraft(trackDeg: nil).formattedValue(for: .heading))
    }

    func testFormattedRoute_bothEnds() {
        let ac = makeAircraft(originIATA: "FRA", destinationIATA: "MUC")
        XCTAssertEqual(ac.formattedValue(for: .route), "FRA → MUC")
    }

    func testFormattedRoute_originOnly() {
        let ac = makeAircraft(originIATA: "FRA", destinationIATA: nil)
        XCTAssertEqual(ac.formattedValue(for: .route), "FRA →")
    }

    func testFormattedRoute_destinationOnly() {
        let ac = makeAircraft(originIATA: nil, destinationIATA: "MUC")
        XCTAssertEqual(ac.formattedValue(for: .route), "→ MUC")
    }

    func testFormattedRoute_nilWhenBothMissing() {
        XCTAssertNil(makeAircraft().formattedValue(for: .route))
    }

    func testFormattedAirline() {
        let ac = makeAircraft(airline: "Lufthansa")
        XCTAssertEqual(ac.formattedValue(for: .airline), "Lufthansa")
    }

    func testFormattedAirline_nilWhenMissing() {
        XCTAssertNil(makeAircraft().formattedValue(for: .airline))
    }

    func testFormattedAltitude_nilWhenMissing() {
        XCTAssertNil(makeAircraft(altitudeFt: nil).formattedValue(for: .altitude))
    }
```

- [ ] **Step 4: Run new tests, verify they fail**

```bash
cd "/Users/robinspeichermann/Documents/Xcode Stuff/MenuBarADSB" && \
  xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/AircraftTests -quiet
```

Expected: 4 prior tests pass, 13 new tests fail until Step 2 changes are saved. (If Step 2 is already saved, all pass; that's fine.)

- [ ] **Step 5: Run all tests, verify everything passes**

```bash
cd "/Users/robinspeichermann/Documents/Xcode Stuff/MenuBarADSB" && \
  xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' -quiet
```

Expected: 26 prior unit tests + 13 new = 39 unit tests, all green. If `Aircraft.stub` callers in `Mocks.swift` need updating because of the memberwise-init change, they don't — the new params have defaults (`= nil`). Confirmed by inspection.

---

## Task 2: RouteService (using adsbdb API)

**Files:**
- Create: `MenuBarADSB/Services/RouteService.swift`
- Create: `MenuBarADSBTests/Fixtures/route-full.json`
- Create: `MenuBarADSBTests/Fixtures/route-partial.json`
- Create: `MenuBarADSBTests/RouteServiceTests.swift`

**API:** `https://api.adsbdb.com/v0/callsign/{CALLSIGN}` (GET)

**Verified live response shape (smoke check 2026-05-05 with callsign RYR8658):**
```json
{
  "response": {
    "flightroute": {
      "callsign": "RYR8658",
      "callsign_icao": "RYR8658",
      "callsign_iata": "FR8658",
      "airline": {
        "name": "Ryanair",
        "icao": "RYR",
        "iata": "FR",
        "country": "Ireland",
        "country_iso": "IE",
        "callsign": "RYANAIR"
      },
      "origin": {
        "iata_code": "CTA",
        "icao_code": "LICC",
        "name": "Catania-Fontanarossa Airport",
        "municipality": "Catania",
        "country_name": "Italy"
      },
      "destination": {
        "iata_code": "GOA",
        "icao_code": "LIMJ",
        "name": "Genoa Cristoforo Colombo Airport",
        "municipality": "Genova",
        "country_name": "Italy"
      }
    }
  }
}
```

**Unknown callsign returns HTTP 404 with body** `{"response":"unknown callsign"}`.

- [ ] **Step 1: Create the two fixture files**

`MenuBarADSBTests/Fixtures/route-full.json`:
```json
{
  "response": {
    "flightroute": {
      "callsign": "DLH441",
      "callsign_icao": "DLH441",
      "callsign_iata": "LH441",
      "airline": {
        "name": "Lufthansa",
        "icao": "DLH",
        "iata": "LH"
      },
      "origin": {
        "iata_code": "FRA",
        "icao_code": "EDDF",
        "name": "Frankfurt am Main Airport"
      },
      "destination": {
        "iata_code": "MUC",
        "icao_code": "EDDM",
        "name": "Munich Airport"
      }
    }
  }
}
```

`MenuBarADSBTests/Fixtures/route-partial.json` (origin only, no destination, no airline):
```json
{
  "response": {
    "flightroute": {
      "callsign": "PRIVATE1",
      "origin": {
        "iata_code": "FRA",
        "icao_code": "EDDF",
        "name": "Frankfurt am Main Airport"
      }
    }
  }
}
```

- [ ] **Step 2: Write RouteServiceTests.swift**

`MenuBarADSBTests/RouteServiceTests.swift`:

```swift
import XCTest
@testable import MenuBarADSB

final class RouteServiceTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("Fixture \(name).json not found")
            return Data()
        }
        return try Data(contentsOf: url)
    }

    private func mock200(data: Data) {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, data)
        }
    }

    func testRoute_fullPayload() async throws {
        let data = try loadFixture("route-full")
        mock200(data: data)
        let svc = RouteService(session: MockURLProtocol.makeSession())
        let info = try await svc.route(forCallsign: "DLH441")
        XCTAssertEqual(info?.airline, "Lufthansa")
        XCTAssertEqual(info?.originIATA, "FRA")
        XCTAssertEqual(info?.destinationIATA, "MUC")
    }

    func testRoute_partialPayload() async throws {
        let data = try loadFixture("route-partial")
        mock200(data: data)
        let svc = RouteService(session: MockURLProtocol.makeSession())
        let info = try await svc.route(forCallsign: "PRIVATE1")
        XCTAssertNil(info?.airline)
        XCTAssertEqual(info?.originIATA, "FRA")
        XCTAssertNil(info?.destinationIATA)
    }

    func testRoute_unknownCallsignReturns404Nil() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, "{\"response\":\"unknown callsign\"}".data(using: .utf8)!)
        }
        let svc = RouteService(session: MockURLProtocol.makeSession())
        let info = try await svc.route(forCallsign: "UNKNOWN")
        XCTAssertNil(info)  // 404 → nil, not an error
    }

    func testRoute_throwsRateLimitedOn429() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, Data())
        }
        let svc = RouteService(session: MockURLProtocol.makeSession())
        do {
            _ = try await svc.route(forCallsign: "X")
            XCTFail("Expected throw")
        } catch ADSBError.rateLimited {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testRoute_throwsHTTPOn500() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, Data())
        }
        let svc = RouteService(session: MockURLProtocol.makeSession())
        do {
            _ = try await svc.route(forCallsign: "X")
            XCTFail("Expected throw")
        } catch ADSBError.http(500) {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testRoute_throwsDecodingOnGarbage() async {
        mock200(data: "not json".data(using: .utf8)!)
        let svc = RouteService(session: MockURLProtocol.makeSession())
        do {
            _ = try await svc.route(forCallsign: "X")
            XCTFail("Expected throw")
        } catch ADSBError.decoding {
            // ok
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testRoute_buildsGetRequestWithCallsignInPath() async throws {
        var capturedURL: URL?
        MockURLProtocol.requestHandler = { request in
            capturedURL = request.url
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            let body = "{\"response\":{\"flightroute\":{\"callsign\":\"DLH441\"}}}"
            return (response, body.data(using: .utf8)!)
        }
        let svc = RouteService(session: MockURLProtocol.makeSession())
        _ = try await svc.route(forCallsign: "DLH441")

        let url = try XCTUnwrap(capturedURL)
        XCTAssertEqual(url.host, "api.adsbdb.com")
        XCTAssertEqual(url.path, "/v0/callsign/DLH441")
    }
}
```

- [ ] **Step 3: Run, verify the tests fail with "Cannot find type 'RouteService'"**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/RouteServiceTests -quiet
```

Expected: compile error.

- [ ] **Step 4: Implement RouteService.swift**

`MenuBarADSB/Services/RouteService.swift`:

```swift
import Foundation

nonisolated protocol RouteFetching: Sendable {
    /// Returns RouteInfo for the callsign, or nil if no useful data is available.
    /// Throws ADSBError on transport/HTTP/decode failures.
    /// 404 from the API is treated as "no data" and returns nil (not thrown).
    func route(forCallsign callsign: String) async throws -> RouteInfo?
}

nonisolated final class RouteService: RouteFetching {
    private let session: URLSession
    private let userAgent = "MenuBarADSB/1.0"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func route(forCallsign callsign: String) async throws -> RouteInfo? {
        let trimmed = callsign.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.adsbdb.com/v0/callsign/\(escaped)") else {
            throw ADSBError.transport
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
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
            case 404: return nil  // adsbdb's "unknown callsign"
            case 429: throw ADSBError.rateLimited
            default: throw ADSBError.http(http.statusCode)
            }
        }

        let decoded: AdsbdbResponse
        do {
            decoded = try JSONDecoder().decode(AdsbdbResponse.self, from: data)
        } catch {
            throw ADSBError.decoding
        }

        return decoded.toRouteInfo()
    }
}

private struct AdsbdbResponse: Decodable {
    let response: ResponsePayload?

    struct ResponsePayload: Decodable {
        let flightroute: FlightRoute?
    }

    struct FlightRoute: Decodable {
        let airline: Airline?
        let origin: Airport?
        let destination: Airport?
    }

    struct Airline: Decodable {
        let name: String?
    }

    struct Airport: Decodable {
        let iata_code: String?
    }

    func toRouteInfo() -> RouteInfo? {
        guard let route = response?.flightroute else { return nil }
        let airline = route.airline?.name
        let origin = route.origin?.iata_code
        let destination = route.destination?.iata_code
        if airline == nil && origin == nil && destination == nil { return nil }
        return RouteInfo(airline: airline, originIATA: origin, destinationIATA: destination)
    }
}
```

- [ ] **Step 5: Run, verify tests pass**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/RouteServiceTests -quiet
```

Expected: 7 tests pass.

- [ ] **Step 6: Run full test suite to confirm no regressions**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' -quiet
```

Expected: prior tests + new RouteService tests all pass.

---
## Task 3: AppSettings extensions

**Files:**
- Modify: `MenuBarADSB/State/AppSettings.swift`
- Modify: `MenuBarADSBTests/AppSettingsTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `AppSettingsTests` class:

```swift
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
        // User can disable everything; that should persist as empty (not fall back to defaults).
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
```

Also extend `clearKeys` to clear the new keys:

```swift
    private let baseKeys = ["radiusKm", "updateIntervalSec", "notificationsEnabled", "launchAtLogin",
                            "menuBarFields", "dropdownFields"]
```

(Replace the existing `private let baseKeys = [...]` line.)

- [ ] **Step 2: Run, verify failure**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/AppSettingsTests -quiet
```

Expected: compile error — `Value of type 'AppSettings' has no member 'menuBarFields'`.

- [ ] **Step 3: Extend AppSettings.swift**

In `MenuBarADSB/State/AppSettings.swift`, modify the `BaseKey` enum to add the two new keys, and add the two new `@Published` properties. The init also needs to load them.

Replace `BaseKey` enum:

```swift
    private enum BaseKey {
        static let radiusKm = "radiusKm"
        static let updateIntervalSec = "updateIntervalSec"
        static let notificationsEnabled = "notificationsEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let menuBarFields = "menuBarFields"
        static let dropdownFields = "dropdownFields"
    }
```

After the existing `@Published var launchAtLogin: Bool { didSet { ... } }` block, add:

```swift
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
```

In the existing `init(defaults:keyPrefix:)`, after the existing 4 lines that load `radiusKm`/`updateIntervalSec`/`notificationsEnabled`/`launchAtLogin`, add:

```swift
        self.menuBarFields = Self.loadFields(
            defaults: defaults, key: keyPrefix + BaseKey.menuBarFields,
            fallback: [.altitude]
        )
        self.dropdownFields = Self.loadFields(
            defaults: defaults, key: keyPrefix + BaseKey.dropdownFields,
            fallback: [.aircraftType, .altitude, .speed, .distance, .heading]
        )
```

At the bottom of the class (before the closing brace), add the two helper functions:

```swift
    private static func encodeFields(_ fields: Set<DisplayField>) -> String {
        // Sort so the persisted string is stable (helps debugging, not strictly needed).
        fields.map(\.rawValue).sorted().joined(separator: ",")
    }

    private static func loadFields(defaults: UserDefaults, key: String,
                                   fallback: Set<DisplayField>) -> Set<DisplayField> {
        // Distinguish "key absent" (use fallback) from "key empty" (user disabled all).
        guard let raw = defaults.string(forKey: key) else { return fallback }
        if raw.isEmpty { return [] }
        return Set(raw.split(separator: ",").compactMap { DisplayField(rawValue: String($0)) })
    }
```

- [ ] **Step 4: Run, verify pass**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/AppSettingsTests -quiet
```

Expected: 5 tests pass (2 prior + 3 new).

---

## Task 4: MockRouteFetcher

**Files:**
- Modify: `MenuBarADSBTests/Support/Mocks.swift`

- [ ] **Step 1: Append MockRouteFetcher to Mocks.swift**

Add after the existing `MockNotifier` class:

```swift
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
```

- [ ] **Step 2: Verify compiles**

```bash
xcodebuild build-for-testing -scheme MenuBarADSB -destination 'platform=macOS' -quiet
```

Expected: build succeeds. No errors.

---

## Task 5: AircraftStore route enrichment

**Files:**
- Modify: `MenuBarADSB/State/AircraftStore.swift`
- Modify: `MenuBarADSBTests/AircraftStoreTests.swift`

This task changes the `AircraftStore` constructor signature. **All existing AircraftStore tests must be updated** to pass a `MockRouteFetcher`.

- [ ] **Step 1: Modify AircraftStore.swift**

Open `MenuBarADSB/State/AircraftStore.swift`.

(a) Add a private nested enum at the top of the class body (before `@Published private(set) var aircraft`):

```swift
    private enum RouteCacheEntry {
        case data(RouteInfo)
        case noData
    }
```

(b) Add new stored properties immediately after `private let settings: AppSettings`:

```swift
    private let routeFetcher: RouteFetching
    private var routeCache: [String: RouteCacheEntry] = [:]
    private var pendingRouteFetches: Set<String> = []
```

(c) Update the init signature. Replace the existing `init(location:fetcher:notifier:settings:)` with:

```swift
    init(location: LocationProviding, fetcher: AircraftFetching,
         routeFetcher: RouteFetching,
         notifier: Notifying, settings: AppSettings) {
        self.location = location
        self.fetcher = fetcher
        self.routeFetcher = routeFetcher
        self.notifier = notifier
        self.settings = settings
        // ... existing subscription setup unchanged ...
```

Keep all the existing Combine subscription and timer setup code in the init body.

(d) Modify `performFetch` to enrich aircraft from the cache before publishing, and trigger background route fetches for new callsigns. Replace the existing `performFetch` implementation with:

```swift
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
            failureCount += 1
            lastError = error
            if failureCount >= 3 { aircraft = [] }
        } catch {
            failureCount += 1
            lastError = .transport
            if failureCount >= 3 { aircraft = [] }
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
            // 429 from adsb.lol is silently swallowed here.
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
```

- [ ] **Step 2: Update AircraftStoreTests.swift constructor calls**

In `MenuBarADSBTests/AircraftStoreTests.swift`, every existing test calls `AircraftStore(...)` with 4 args. Add a `routeFetcher: MockRouteFetcher()` argument to each, in the right position (after `fetcher`).

Find every `AircraftStore(` call in `AircraftStoreTests.swift`. Each one needs:

```swift
AircraftStore(
    location: location, fetcher: fetcher,
    routeFetcher: MockRouteFetcher(),
    notifier: notifier, settings: settings
)
```

(Apply this change to all 8 existing test methods.)

- [ ] **Step 3: Append four new enrichment tests**

Add inside `AircraftStoreTests` class:

```swift
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
        try await Task.sleep(nanoseconds: 400_000_000)  // longer wait for route fetch

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

        _ = AircraftStore(
            location: location, fetcher: fetcher,
            routeFetcher: routeFetcher,
            notifier: notifier, settings: settings
        )

        location.emit(.available(lat: 50, lon: 8))
        try await Task.sleep(nanoseconds: 400_000_000)

        // Trigger another tick.
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

        routeFetcher.responses["UNKNOWN1"] = .success(nil)  // no data for this callsign
        fetcher.nextResult = .success([.stub(hex: "x", callsign: "UNKNOWN1")])

        _ = AircraftStore(
            location: location, fetcher: fetcher,
            routeFetcher: routeFetcher,
            notifier: notifier, settings: settings
        )

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

        // Aircraft list still populated, just without route info.
        XCTAssertEqual(store.aircraft.first?.hex, "abc")
        XCTAssertNil(store.aircraft.first?.airline)
        XCTAssertNil(store.lastError)  // route failure should not bubble up to lastError
    }
```

- [ ] **Step 4: Run all AircraftStore tests, verify pass**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/AircraftStoreTests -quiet
```

Expected: 12 tests pass (8 existing + 4 new).

If existing tests still call `AircraftStore` with 4 args (compile error), fix step 2 didn't apply to all callsites.

- [ ] **Step 5: Run full test suite**

```bash
xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' -quiet
```

Expected: all unit tests still pass. Total: 39 (Task 1) + 8 (Task 2 RouteService) + 3 (Task 3 AppSettings new) + 4 (Task 5 new) = 54 unit tests.

---

## Task 6: MenuBarLabelView dynamic rendering

**Files:**
- Modify: `MenuBarADSB/Views/MenuBarLabelView.swift`

No unit tests — manual verification later.

- [ ] **Step 1: Replace MenuBarLabelView contents**

```swift
import SwiftUI

struct MenuBarLabelView: View {
    @ObservedObject var store: AircraftStore
    @ObservedObject var settings: AppSettings

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
        for field in DisplayField.canonicalOrder where settings.menuBarFields.contains(field) {
            if let value = aircraft.formattedValue(for: field) {
                parts.append(value)
            }
        }
        return parts.joined(separator: " · ")
    }
}
```

- [ ] **Step 2: Build, verify compiles**

```bash
xcodebuild build -scheme MenuBarADSB -destination 'platform=macOS' -quiet
```

Expected: build error — `MenuBarADSBApp.swift` doesn't yet pass `settings` to `MenuBarLabelView`. That's fixed in Task 9. For now, the build will fail. **This is expected.** Continue to the next view task; we'll build at the end.

---

## Task 7: MenuBarContentView dynamic rendering

**Files:**
- Modify: `MenuBarADSB/Views/MenuBarContentView.swift`

- [ ] **Step 1: Rewrite AircraftRow inside MenuBarContentView.swift**

Replace the existing `private struct AircraftRow: View { ... }` block (and its private helpers) at the bottom of `MenuBarContentView.swift` with:

```swift
private struct AircraftRow: View {
    let aircraft: Aircraft
    let fields: Set<DisplayField>

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(aircraft.identifier)
                    .font(.system(size: 13, weight: .semibold))
                if let secondary = secondaryLine {
                    Text(secondary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if fields.contains(.distance), let distance = aircraft.formattedValue(for: .distance) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(distance)
                        .font(.system(size: 13, weight: .medium))
                    if fields.contains(.heading), let heading = aircraft.formattedValue(for: .heading) {
                        Text(heading)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// All non-right-side fields, joined with " · ".
    /// Distance and heading are rendered on the right side, so they're excluded here.
    private var secondaryLine: String? {
        let leftSideFields: [DisplayField] = [.airline, .route, .aircraftType, .altitude, .speed]
        let parts = leftSideFields
            .filter { fields.contains($0) }
            .compactMap { aircraft.formattedValue(for: $0) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
```

- [ ] **Step 2: Update the call site to pass `fields`**

In the same file, find the `ForEach(store.aircraft, id: \.hex) { ac in ... AircraftRow(aircraft: ac) ... }` block and change `AircraftRow(aircraft: ac)` to `AircraftRow(aircraft: ac, fields: settings.dropdownFields)`.

The `MenuBarContentView` already has `@ObservedObject var settings: AppSettings` so `settings.dropdownFields` is in scope.

---

## Task 8: SettingsView field sections

**Files:**
- Modify: `MenuBarADSB/Views/SettingsView.swift`

- [ ] **Step 1: Add the binding helper and two new sections**

Replace the entire body of `SettingsView` and add the helper. Full replacement of the file:

```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Radius") {
                VStack(alignment: .leading) {
                    Slider(value: $settings.radiusKm, in: 1...50, step: 0.5)
                    Text(formatRadius())
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

            Section("Menu Bar Anzeige") {
                Label("Identifier (immer aktiv)", systemImage: "checkmark.square.fill")
                    .foregroundStyle(.secondary)
                Toggle("Airline", isOn: menuBarBinding(for: .airline))
                Toggle("Route", isOn: menuBarBinding(for: .route))
                Toggle("Flugzeugtyp", isOn: menuBarBinding(for: .aircraftType))
                Toggle("Höhe", isOn: menuBarBinding(for: .altitude))
                Toggle("Geschwindigkeit", isOn: menuBarBinding(for: .speed))
                Toggle("Distanz", isOn: menuBarBinding(for: .distance))
                Toggle("Richtung", isOn: menuBarBinding(for: .heading))
            }

            Section("Dropdown-Liste") {
                Label("Identifier (immer aktiv)", systemImage: "checkmark.square.fill")
                    .foregroundStyle(.secondary)
                Toggle("Airline", isOn: dropdownBinding(for: .airline))
                Toggle("Route", isOn: dropdownBinding(for: .route))
                Toggle("Flugzeugtyp", isOn: dropdownBinding(for: .aircraftType))
                Toggle("Höhe", isOn: dropdownBinding(for: .altitude))
                Toggle("Geschwindigkeit", isOn: dropdownBinding(for: .speed))
                Toggle("Distanz", isOn: dropdownBinding(for: .distance))
                Toggle("Richtung", isOn: dropdownBinding(for: .heading))
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 540)
    }

    private func menuBarBinding(for field: DisplayField) -> Binding<Bool> {
        Binding(
            get: { settings.menuBarFields.contains(field) },
            set: { isOn in
                if isOn { settings.menuBarFields.insert(field) }
                else    { settings.menuBarFields.remove(field) }
            }
        )
    }

    private func dropdownBinding(for field: DisplayField) -> Binding<Bool> {
        Binding(
            get: { settings.dropdownFields.contains(field) },
            set: { isOn in
                if isOn { settings.dropdownFields.insert(field) }
                else    { settings.dropdownFields.remove(field) }
            }
        )
    }

    private func formatRadius() -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "de_DE")
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 1
        let s = f.string(from: NSNumber(value: settings.radiusKm)) ?? "\(settings.radiusKm)"
        return "\(s) km"
    }
}
```

---

## Task 9: App wiring

**Files:**
- Modify: `MenuBarADSB/MenuBarADSBApp.swift`

- [ ] **Step 1: Update init and body**

Replace the entire `MenuBarADSBApp.swift` with:

```swift
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
```

- [ ] **Step 2: Build & full test run**

```bash
cd "/Users/robinspeichermann/Documents/Xcode Stuff/MenuBarADSB" && \
  xcodebuild test -scheme MenuBarADSB -destination 'platform=macOS' -quiet
```

Expected: Build succeeds. All ~54 unit tests pass.

---

## Task 10: Acceptance verification

Manual verification by the user. Walk through each acceptance criterion:

- [ ] **AC1:** Build succeeds with no NEW warnings (existing `nonisolated`+`@Published` and Sendable warnings remain).

- [ ] **AC2:** All 26 prior tests + new tests pass.
   - `xcodebuild test ...` returns exit 0.

- [ ] **AC3-7:** New tests pass with the documented counts:
   - 8 RouteService tests ✓
   - 4 AircraftStore route-enrichment tests ✓
   - 3 new AppSettings field-set tests ✓
   - 13 new Aircraft formatter tests ✓

- [ ] **AC4:** Live test in real airspace.
   - Run app (⌘R), wait for an airliner with a known callsign to enter the radius.
   - Within ~2 seconds: `Lufthansa` and `FRA → MUC` (or equivalent) appear in the dropdown row.

- [ ] **AC5:** Live: open Settings, toggle "Airline" on for menu bar — see the airline name appear in the menu bar label immediately. Toggle off — disappears immediately.

- [ ] **AC6:** Live: a callsign that adsb.lol doesn't recognise (e.g., a small private aircraft starting with `D-`) appears in the list with airline/route fields silently absent — no error message, no dash, just a shorter row.

- [ ] **AC7:** Live: in Settings, disable every optional field for both menu bar and dropdown. Confirm the menu bar shows only `✈ <identifier>` and the dropdown rows show only callsigns. App still functional.

- [ ] **AC8:** Settings window remains exactly 380 × 540 pt and is not resizable. All sections fit without an internal scroll bar (or with one if the user's display is small — that's OK).

---

## Self-Review Notes

- **Spec coverage:**
  - §3.1 (Aircraft fields) → Task 1.
  - §3.2 (DisplayField enum) → Task 1.
  - §3.3 (RouteInfo struct) → Task 1.
  - §4 (RouteService) → Task 2.
  - §5 (AircraftStore integration) → Task 5.
  - §6 (AppSettings extensions) → Task 3.
  - §7 (View changes) → Tasks 6, 7, 8, 9.
  - §8 (Testing) → Tasks 1, 2, 3, 5.
  - §9 (Edge cases) → covered by tests + Task 10 manual checks.
  - §11 (Acceptance criteria) → Task 10.
- **Placeholder scan:** No "TBD"/"TODO" in code blocks. The single "if response shape differs, NEEDS_CONTEXT" guidance in Task 2 Step 1 is intentional, not a placeholder.
- **Type consistency:**
  - `RouteFetching` protocol in Task 2 used in Tasks 4, 5.
  - `RouteInfo` in Task 1 used in Tasks 2, 4, 5.
  - `RouteCacheEntry` enum in Task 5 — internal to `AircraftStore`.
  - `DisplayField.canonicalOrder` defined Task 1, used Tasks 6, 7.
  - `Aircraft.formattedValue(for:)` defined Task 1, used Tasks 6, 7.
  - Memberwise init parameters with new defaults — `Aircraft.stub` callers in `Mocks.swift` keep working without changes.
