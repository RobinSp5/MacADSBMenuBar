# MenuBarADSB — Configurable Display Fields & Route Enrichment

**Date:** 2026-05-05
**Status:** Approved (brainstorming complete, ready for implementation plan)
**Builds on:** `2026-05-05-menubar-adsb-design.md`
**Scope:** Single feature extension on the existing MenuBarADSB app.

---

## 1. Overview

Two related additions:

1. **Configurable display fields**: the user picks which per-aircraft fields appear in (a) the menu bar label and (b) the dropdown list. Each is configured independently. The aircraft identifier is always shown — every other field is opt-in.

2. **Airline + route enrichment**: two new fields available for display — the operating airline (e.g., "Lufthansa") and the origin → destination IATA pair (e.g., "FRA → MUC"). Sourced from adsb.lol's `routeset` endpoint and cached per session.

Together, the user can see at a glance not just *that* a plane is overhead, but *who's flying it* and *where it's going*.

---

## 2. Locked Decisions

| # | Topic | Decision |
|---|---|---|
| 1 | Menu bar width | Free — can grow as wide as the user's selection requires. No artificial cap. |
| 2 | Available fields | All 8 (identifier, type, altitude, speed, distance, heading, airline, route) are toggleable except identifier, which is mandatory. |
| 3 | Settings UI | Two new sections in the existing Settings window (no Tab View). Order: existing controls first, then "Menu Bar Anzeige" section, then "Dropdown-Liste" section. |
| 4 | Field display order | Fixed canonical order: `Identifier · Airline · Route · Type · Altitude · Speed · Distance · Heading`. User cannot reorder. |
| 5 | Route data source | **adsbdb** at `https://api.adsbdb.com/v0/callsign/{CALLSIGN}`. (adsb.lol's routeset endpoint is currently broken — returns 201 empty for all callsigns. Verified live 2026-05-05.) |
| 6 | Route format | IATA codes joined by " → " (e.g., "FRA → MUC"). |
| 7 | Caching | In-memory `[Callsign: RouteInfo]` dictionary. Lifetime = session. Negative cache (callsign with no route) included. No eviction. |
| 8 | Missing field handling | Silently omit. No "—" placeholders, no "Unknown" strings. |
| 9 | Settings UI language | German (matches existing app). |

---

## 3. Data Model Extensions

### 3.1 `Aircraft` struct (modify `Models/Aircraft.swift`)

Add three optional properties, alphabetised among the existing ones for consistency:

```swift
nonisolated struct Aircraft: Equatable {
    // ... existing fields ...
    var airline: String? = nil       // e.g., "Lufthansa"
    var originIATA: String? = nil    // e.g., "FRA"
    var destinationIATA: String? = nil // e.g., "MUC"
}
```

These are mutated post-decoding by `AircraftStore` (just like `distanceKm`). They are NOT decoded from the main `/v2/lat/...` API response — that endpoint doesn't include route info.

The memberwise initializer (used by tests via `Aircraft.stub`) gets three new parameters with sensible defaults (`nil`).

### 3.2 `DisplayField` enum (new file: `Models/DisplayField.swift`)

```swift
nonisolated enum DisplayField: String, CaseIterable, Codable, Sendable {
    case aircraftType
    case altitude
    case speed
    case distance
    case heading
    case airline
    case route
}
```

Note: `identifier` is NOT a case — it's always shown, never optional.

### 3.3 `RouteInfo` struct (new, in `Models/Aircraft.swift` next to `Aircraft`)

```swift
nonisolated struct RouteInfo: Equatable, Sendable {
    let airline: String?
    let originIATA: String?
    let destinationIATA: String?

    /// True if at least one piece of route data was found.
    var hasAnyData: Bool { airline != nil || originIATA != nil || destinationIATA != nil }
}
```

---

## 4. Route Service

### 4.1 New file: `Services/RouteService.swift`

```swift
nonisolated protocol RouteFetching: Sendable {
    /// Returns RouteInfo for the callsign, or nil if no data is available.
    /// Throws on transport / HTTP errors so the store can decide whether to retry.
    func route(forCallsign callsign: String) async throws -> RouteInfo?
}

nonisolated final class RouteService: RouteFetching {
    private let session: URLSession
    private let userAgent = "MenuBarADSB/1.0"

    init(session: URLSession = .shared) { self.session = session }

    func route(forCallsign callsign: String) async throws -> RouteInfo? {
        // GET https://api.adsb.lol/api/0/routeset?callsign={CALLSIGN}
        // 200 → parse, return RouteInfo (may have all-nil fields if response is empty)
        // 404 / empty → return nil (no data for this callsign)
        // 429 → throw ADSBError.rateLimited (reuse existing error type)
        // other HTTP → throw ADSBError.http(code)
        // transport error → throw ADSBError.transport
        // decode error → throw ADSBError.decoding
    }
}
```

Mirrors `ADSBService` exactly in shape and error semantics. Same User-Agent, same JSON Accept header, same 10s timeout.

### 4.2 Response parsing

The exact `routeset` JSON shape needs verification at implementation time (curl the endpoint with a known callsign). Expected structure (based on VRS-standing-data convention):

```json
{
  "_AirlineCode": "DLH",
  "_AirlineName": "Lufthansa",
  "_Origin": { "Iata": "FRA", "Name": "Frankfurt" },
  "_Destination": { "Iata": "MUC", "Name": "München" }
}
```

Defensive Codable parsing — every field optional. If response shape differs from expectation, log once and return `nil` for that callsign rather than crashing.

---

## 5. AircraftStore Integration

### 5.1 New properties

```swift
private enum RouteCacheEntry {
    case data(RouteInfo)
    case noData
}
private let routeFetcher: RouteFetching
private var routeCache: [String: RouteCacheEntry] = [:]
private var pendingRouteFetches: Set<String> = []   // callsigns currently being fetched
```

We use an explicit enum rather than `RouteInfo?` because Swift's dictionary subscript with `nil` *removes* the key — that would silently destroy the negative cache. The enum makes negative-cache-entry distinct from absent-key.

Cache states:
- Key absent: never fetched (or fetch failed and was deliberately not cached).
- Key present, `.noData`: fetched, route API had nothing for this callsign.
- Key present, `.data(RouteInfo)`: fetched, data available.

### 5.2 Constructor signature changes

```swift
init(location: LocationProviding, fetcher: AircraftFetching, routeFetcher: RouteFetching,
     notifier: Notifying, settings: AppSettings) { ... }
```

The new `routeFetcher` is injected. `MenuBarADSBApp` constructs a `RouteService()` and passes it; tests inject a `MockRouteFetcher`.

### 5.3 Fetch flow (modify `performFetch`)

After the main fetch succeeds and the aircraft list is sorted, but BEFORE assigning to `self.aircraft`:

1. For each aircraft with a non-nil callsign that's already in `routeCache`: copy cached `airline`/`originIATA`/`destinationIATA` into the aircraft.
2. Assign to `self.aircraft` (UI updates immediately with whatever's known so far).
3. For each aircraft with a callsign that's NOT in `routeCache` AND NOT in `pendingRouteFetches`: kick off a parallel fetch task. Add callsign to `pendingRouteFetches`.
4. Each parallel fetch task, on completion: write to `routeCache` (success or nil), remove from `pendingRouteFetches`, then call `enrichVisibleAircraft()`.

```swift
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

The `if updated != self.aircraft` guard prevents needless `@Published` notifications when nothing changed.

### 5.4 Error handling for route fetches

A failed route fetch (transport, http error other than 429) does NOT cause cache insertion — we want to retry next tick. A successful response with no data inserts a `nil` into the cache (negative cache). A 429 is silently swallowed — try again next tick.

A failed route fetch never affects the main aircraft list visibility.

---

## 6. AppSettings Extensions

Add two new `@Published` properties:

```swift
@Published var menuBarFields: Set<DisplayField> {
    didSet { defaults.set(menuBarFields.map(\.rawValue).joined(separator: ","), forKey: ...) }
}
@Published var dropdownFields: Set<DisplayField> {
    didSet { defaults.set(dropdownFields.map(\.rawValue).joined(separator: ","), forKey: ...) }
}
```

Backed by UserDefaults as a comma-joined string of `rawValue`s. Stable across app versions: unknown rawValues on read are skipped silently.

### Defaults

| Setting | Default value |
|---|---|
| `menuBarFields` | `[.altitude]` |
| `dropdownFields` | `[.aircraftType, .altitude, .speed, .distance, .heading]` |

These match the previous fixed display, so existing users (or fresh installs) see no behavioural difference until they go change settings.

### Read/write helpers

```swift
private static func decodeFields(_ raw: String?) -> Set<DisplayField> {
    guard let raw, !raw.isEmpty else { return [] }
    return Set(raw.split(separator: ",").compactMap { DisplayField(rawValue: String($0)) })
}
```

In `init`, load via `decodeFields(defaults.string(forKey: ...))` with the default-set as fallback when the UserDefaults key is absent (not when it's empty — empty means user actively turned everything off).

---

## 7. View Changes

### 7.1 `MenuBarLabelView`

Replace the hardcoded "identifier · altitude" logic with a dynamic builder that respects `settings.menuBarFields`:

```swift
struct MenuBarLabelView: View {
    @ObservedObject var store: AircraftStore
    @ObservedObject var settings: AppSettings  // newly injected

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "airplane")
            if let nearest = store.aircraft.first {
                Text(formatLabel(for: nearest, fields: settings.menuBarFields))
                    .font(.system(size: 12))
            }
        }
    }
}
```

`formatLabel(for:fields:)` walks the canonical order `[.airline, .route, .aircraftType, .altitude, .speed, .distance, .heading]`, prepends identifier, and joins non-nil values with " · ".

### 7.2 `MenuBarContentView` and `AircraftRow`

`AircraftRow` is rewritten to render the configured `dropdownFields` rather than the fixed structure:

- **Top line**: identifier (always), bold.
- **Secondary line(s)**: comma-or-bullet-separated string of the selected fields in canonical order. May wrap to two lines via `.lineLimit(2)` + `.fixedSize(horizontal: false, vertical: true)`.
- **Right-side metadata**: a heuristic — if `distance` is selected, it stays on the right (visual alignment with the existing layout). If `distance` is not selected, the right side collapses.

Per-row tap behaviour and stale-data opacity are unchanged.

### 7.3 `SettingsView`

Add two new sections after the existing four. Each section has 7 toggles plus a non-interactive row showing "Identifier (immer aktiv)".

```swift
Section("Menu Bar Anzeige") {
    HStack {
        Image(systemName: "checkmark.square.fill").foregroundStyle(.secondary)
        Text("Identifier (immer aktiv)").foregroundStyle(.secondary)
    }
    Toggle("Airline", isOn: binding(for: .airline, in: \.menuBarFields))
    Toggle("Route", isOn: binding(for: .route, in: \.menuBarFields))
    Toggle("Flugzeugtyp", isOn: binding(for: .aircraftType, in: \.menuBarFields))
    Toggle("Höhe", isOn: binding(for: .altitude, in: \.menuBarFields))
    Toggle("Geschwindigkeit", isOn: binding(for: .speed, in: \.menuBarFields))
    Toggle("Distanz", isOn: binding(for: .distance, in: \.menuBarFields))
    Toggle("Richtung", isOn: binding(for: .heading, in: \.menuBarFields))
}
Section("Dropdown-Liste") { /* same 8 rows for `\.dropdownFields` */ }
```

Helper:
```swift
private func binding(for field: DisplayField, in keyPath: ReferenceWritableKeyPath<AppSettings, Set<DisplayField>>) -> Binding<Bool> {
    Binding(
        get: { settings[keyPath: keyPath].contains(field) },
        set: { isOn in
            if isOn { settings[keyPath: keyPath].insert(field) }
            else    { settings[keyPath: keyPath].remove(field) }
        }
    )
}
```

The Settings window grows to roughly **380 × 540 pt**. Still not resizable.

### 7.4 App wiring

`MenuBarADSBApp.init` constructs a `RouteService()` and passes it to `AircraftStore`. `MenuBarLabelView` now also receives `settings` via the existing wiring.

---

## 8. Testing

### New test files

| Subject | Test file | Approach |
|---|---|---|
| RouteService URL building, parsing, errors | `RouteServiceTests.swift` (new) | Pattern identical to `ADSBServiceTests`. Uses `MockURLProtocol`. Cases: success with full data, success with partial data (only origin), 404 → nil, 429 → throws rateLimited, decode garbage → throws decoding, transport error → throws transport. |
| AircraftStore route enrichment | New tests in `AircraftStoreTests.swift` | Mock `RouteFetching` returns predetermined `RouteInfo`. Verify `store.aircraft.first?.airline` populates after a tick + brief sleep. |
| AircraftStore route caching | New test | Two ticks with same aircraft. `MockRouteFetcher.callCount(forCallsign: "DLH441") == 1`. |
| AircraftStore negative caching | New test | Mock returns `nil`. Two ticks with same callsign. `callCount == 1`. Aircraft fields stay nil. |
| AircraftStore route failure doesn't poison main list | New test | Mock route fetcher throws. Aircraft list still populated, just without route data. |
| AppSettings field-set persistence | New tests in `AppSettingsTests.swift` | Set custom field sets, reload, assert equal. |
| AppSettings field-set defaults | New test | Fresh AppSettings has the documented default sets. |
| DisplayField round-trip via UserDefaults string | Same file | Round-trip a Set through the comma-joined string format. |

### Mocks

In `MenuBarADSBTests/Support/Mocks.swift`, add:

```swift
nonisolated final class MockRouteFetcher: RouteFetching, @unchecked Sendable {
    var responses: [String: Result<RouteInfo?, Error>] = [:]  // callsign → predetermined result
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

### View tests

None. Manual verification against the acceptance criteria below, just like before.

---

## 9. Edge Cases

1. **Aircraft has no callsign** (anonymous transmitter, military): no route lookup is attempted. Airline/route stay nil, fields silently absent in display.
2. **Route API returns no match for a callsign**: negative cache entry, no further attempts this session.
3. **Cache grows over a long-running session**: realistic upper bound a few hundred entries per day. ~100 bytes per entry × 500 = 50 KB. No eviction needed.
4. **Aircraft re-uses a callsign with different route** (extremely rare, would only happen if the airline reassigns mid-session): we'd serve stale data until next app restart. Acceptable.
5. **User toggles a field on/off**: View re-renders immediately via `@Published`. No timer disruption, no re-fetch.
6. **User disables every optional menu bar field**: label shows just airplane icon + identifier. Acceptable.
7. **User disables every optional dropdown field**: list rows are just identifiers, still tappable. Acceptable.
8. **Route fetch is slow** (1-2 seconds): the aircraft list shows immediately with whatever's already cached, route data fills in afterward. Visible "pop-in" is by design — beats blocking the whole list.
9. **adsb.lol routeset endpoint goes down entirely**: aircraft list stays functional, route fields stay nil for everyone. Fully degrades without surfacing an error to the user.

---

## 10. Out of Scope (YAGNI)

- User-configurable field order. (Canonical order is fine.)
- Per-airline icons / logos. (Just the name.)
- ICAO code preference instead of IATA. (IATA only.)
- Cache eviction policy. (No eviction.)
- Disk persistence of route cache. (In-memory only.)
- Pre-fetching routes for aircraft that aren't yet in the list.
- Configurable refresh interval for route data. (Once per session = enough.)
- "Recently spotted" history of departed aircraft.

---

## 11. Acceptance Criteria

The implementation is complete when:

1. App builds with no warnings introduced by this work (existing warnings about `@Published`+`nonisolated` and `UNUserNotificationCenter` Sendable remain as documented in prior spec).
2. All previously-passing 26 unit tests still pass.
3. New tests pass: ≥ 6 RouteService tests, ≥ 4 AircraftStore route-enrichment tests, ≥ 3 AppSettings field-set tests.
4. Live: with a known commercial callsign in range (e.g., during a real test in airspace), the dropdown row populates `Lufthansa` and `FRA → MUC` (or equivalent) within ~2 seconds of the aircraft appearing.
5. Live: toggling fields in Settings instantly updates both the menu bar label and dropdown content.
6. Live: a callsign with no route data (e.g., a private aircraft starting with `D-` or military) appears in the list with route fields silently absent — no error, no "—".
7. Live: identifier-only mode (all other fields disabled in both menu bar and dropdown) shows only the identifier, app remains usable.
8. Settings window remains non-resizable, fits all sections without scrolling.
