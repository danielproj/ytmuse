import XCTest
@testable import Domain
final class AppearanceTests: XCTestCase {
    func testStoredAppearanceRoundTripAndInvalidFallback() {
        for appearance in Appearance.allCases {
            XCTAssertEqual(Appearance(storedValue: appearance.rawValue), appearance)
        }
        XCTAssertEqual(Appearance(storedValue: nil), .system)
        XCTAssertEqual(Appearance(storedValue: "future-value"), .system)
        XCTAssertEqual(Appearance(storedValue: ""), .system)
    }
}
