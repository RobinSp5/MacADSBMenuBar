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
        XCTAssertEqual(ac.formattedValue(for: .altitude), "10.973 m")
    }

    func testFormattedSpeed() {
        let ac = makeAircraft()
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
}
