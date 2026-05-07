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
}
