# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Pure-SwiftUI macOS menu bar app that polls public ADS-B feeds and shows nearby aircraft. macOS 26+, Xcode 26+. Sandboxed with Hardened Runtime. No external dependencies (no SPM/Cocoapods/Carthage).

Bundle ID: `com.speichermann.MenuBarADSB`. Single Xcode project with three targets: `MenuBarADSB`, `MenuBarADSBTests`, `MenuBarADSBUITests`. Scheme `MenuBarADSB` is **shared** (`MenuBarADSB.xcodeproj/xcshareddata/xcschemes/`) — required so CI and headless `xcodebuild` invocations can resolve it.

## Common commands

Open in Xcode:
```bash
open MenuBarADSB.xcodeproj
```

Headless build (Release, ad-hoc signed — mirrors CI):
```bash
xcodebuild -project MenuBarADSB.xcodeproj -scheme MenuBarADSB -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  clean build
```

Run all tests:
```bash
xcodebuild test -project MenuBarADSB.xcodeproj -scheme MenuBarADSB \
  -destination 'platform=macOS'
```

Run a single test (class or method):
```bash
xcodebuild test -project MenuBarADSB.xcodeproj -scheme MenuBarADSB \
  -destination 'platform=macOS' \
  -only-testing:MenuBarADSBTests/AircraftStoreTests/testInitialPollPopulatesAircraft
```

List schemes/targets (sanity-check from CLI):
```bash
xcodebuild -project MenuBarADSB.xcodeproj -list
```

## Architecture

The composition root is `MenuBarADSB/MenuBarADSBApp.swift` — every service is constructed once in `init()` and injected into `AircraftStore`. **There are no singletons and no DI framework.** When adding a new service, follow the same pattern: define a `nonisolated protocol ... : Sendable`, build a concrete `nonisolated final class`, and inject it from `MenuBarADSBApp.init()`.

**`AircraftStore` (`State/AircraftStore.swift`) is the brain.** It is `@MainActor`, `ObservableObject`, and owns:
- The poll timer (interval driven by `AppSettings.updateIntervalSec`)
- Subscriptions to `LocationService.statePublisher` and to `AppSettings` Combine publishers (`radiusKm`, `updateIntervalSec`) — changing settings re-triggers polling
- The route cache (`[callsign: RouteCacheEntry]`) and de-duplication of in-flight route fetches
- Staleness detection, error state, and notification dispatch for newly-appearing aircraft

Views (`Views/`) are presentation-only and observe `AircraftStore` + `AppSettings`. Services (`Services/`) know nothing about UI state.

**Service protocols (all `nonisolated`, `Sendable`):**
- `AircraftFetching` → `ADSBService` hits `api.adsb.lol` (positions)
- `RouteFetching` → `RouteService` hits `api.adsbdb.com` (airline + origin/dest). 404 returns `nil` instead of throwing — the store caches "no data" to avoid refetch loops.
- `LocationProviding` → `LocationService` wraps `CLLocationManager`
- `Notifying` → `NotificationService` wraps `UNUserNotificationCenter`

All four are mockable. Test mocks live in `MenuBarADSBTests/Support/Mocks.swift`. Network is mocked via `MockURLProtocol` + an ephemeral `URLSession` — used to drive `ADSBService`/`RouteService` against JSON fixtures in `MenuBarADSBTests/Fixtures/`.

**`AppSettings` (`State/AppSettings.swift`)** is `UserDefaults`-backed and supports a `keyPrefix` constructor arg so tests can isolate state. Every `@Published` property has a `didSet` that writes through to `UserDefaults` — preserve that pattern when adding new settings.

**Concurrency model:** UI state and the store live on `@MainActor`. Services are `nonisolated` and expose `async throws` calls. The store wraps service calls in `Task` and assigns results on the main actor. When touching the store, keep mutations on `@MainActor`; when touching services, keep them `nonisolated` and `Sendable`.

## Tests

Uses **XCTest** (not the newer Swift Testing `@Test` macro). One test class per source file (`ADSBServiceTests`, `AircraftStoreTests`, `RouteServiceTests`, `GeoMathTests`, `AppSettingsTests`, `AircraftTests`, `MenuBarSelectionTests`). When adding tests for a new module, follow this 1-to-1 convention.

For new network code: add a JSON fixture under `MenuBarADSBTests/Fixtures/` and drive it through `MockURLProtocol.requestHandler`. For new store behavior: inject `MockLocationService` / `MockADSBFetcher` etc. and drive Combine subjects manually.

## Localization

Strings live in `Localizable.xcstrings` (UI) and `InfoPlist.xcstrings` (`NSLocationUsageDescription`), both String Catalogs with English as source and German as translation. Numeric formatting follows the user's locale (e.g. `1.5 km` vs `1,5 km`). To add a new language, add the locale to `knownRegions` in `MenuBarADSB.xcodeproj/project.pbxproj` and add the language column inside both catalogs.

## Releases

Releases are fully automated by `.github/workflows/release.yml`:
- Trigger: pushing a tag matching `v*` (e.g. `v1.0.1`)
- Runner: `macos-latest`, builds via `xcodebuild` with ad-hoc signing (`CODE_SIGN_IDENTITY="-"`) — no Developer ID, no notarization
- Output: `MenuBarADSB-<version>.zip` (the `.app` packaged via `ditto`) attached to a GitHub Release, notes auto-generated from commits
- `MARKETING_VERSION` is overridden at build time from the tag; `CURRENT_PROJECT_VERSION` is set to the workflow run number

**To cut a release:** `git tag vX.Y.Z && git push --tags`. To re-roll a failed tag: delete locally and remotely (`git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z`), then re-tag.

## Sandbox / entitlements

`MenuBarADSB/MenuBarADSB.entitlements` grants: app sandbox, `network.client`, `personal-information.location`, `files.user-selected.read-only`. Disk writes to arbitrary paths are **not** available — any new persistence must go through `UserDefaults` (current pattern) or container-scoped storage.
