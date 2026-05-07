import XCTest
@testable import MenuBarADSB

final class MenuBarSelectionTests: XCTestCase {

    /// Pre-sorted by ascending distance, like AircraftStore produces.
    private let sample: [Aircraft] = [
        Aircraft(hex: "near",   callsign: "NEAR",   registration: nil, typeCode: nil,
                 altitudeFt: 5000,  groundSpeedKt: 250,  trackDeg: nil, lat: 0, lon: 0),
        Aircraft(hex: "mid",    callsign: "MID",    registration: nil, typeCode: nil,
                 altitudeFt: 36000, groundSpeedKt: 450,  trackDeg: nil, lat: 0, lon: 0),
        Aircraft(hex: "far",    callsign: "FAR",    registration: nil, typeCode: nil,
                 altitudeFt: 1500,  groundSpeedKt: 120,  trackDeg: nil, lat: 0, lon: 0),
    ]

    func testClosest_returnsFirst() {
        XCTAssertEqual(MenuBarSelection.closest.selectFeatured(from: sample)?.hex, "near")
    }

    func testHighestAltitude() {
        XCTAssertEqual(MenuBarSelection.highestAltitude.selectFeatured(from: sample)?.hex, "mid")
    }

    func testLowestAltitude() {
        XCTAssertEqual(MenuBarSelection.lowestAltitude.selectFeatured(from: sample)?.hex, "far")
    }

    func testFastest() {
        XCTAssertEqual(MenuBarSelection.fastest.selectFeatured(from: sample)?.hex, "mid")
    }

    func testHighestAltitude_fallsBackToClosestWhenNoAltitudeData() {
        let noAlt: [Aircraft] = [
            Aircraft(hex: "a", callsign: nil, registration: nil, typeCode: nil,
                     altitudeFt: nil, groundSpeedKt: nil, trackDeg: nil, lat: 0, lon: 0),
            Aircraft(hex: "b", callsign: nil, registration: nil, typeCode: nil,
                     altitudeFt: nil, groundSpeedKt: nil, trackDeg: nil, lat: 0, lon: 0),
        ]
        XCTAssertEqual(MenuBarSelection.highestAltitude.selectFeatured(from: noAlt)?.hex, "a")
    }

    func testFastest_fallsBackToClosestWhenNoSpeedData() {
        let noSpeed: [Aircraft] = [
            Aircraft(hex: "a", callsign: nil, registration: nil, typeCode: nil,
                     altitudeFt: 5000, groundSpeedKt: nil, trackDeg: nil, lat: 0, lon: 0),
            Aircraft(hex: "b", callsign: nil, registration: nil, typeCode: nil,
                     altitudeFt: 6000, groundSpeedKt: nil, trackDeg: nil, lat: 0, lon: 0),
        ]
        XCTAssertEqual(MenuBarSelection.fastest.selectFeatured(from: noSpeed)?.hex, "a")
    }

    func testEmptyList_returnsNil() {
        XCTAssertNil(MenuBarSelection.closest.selectFeatured(from: []))
        XCTAssertNil(MenuBarSelection.highestAltitude.selectFeatured(from: []))
        XCTAssertNil(MenuBarSelection.lowestAltitude.selectFeatured(from: []))
        XCTAssertNil(MenuBarSelection.fastest.selectFeatured(from: []))
    }
}
