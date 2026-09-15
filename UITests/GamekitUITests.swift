import XCTest

@MainActor
final class GamekitUITests: XCTestCase {
    func testNativeAppLaunchesWithLinkedCore() {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.windows["Gamekit"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["runtime-recipe"].exists)
        XCTAssertTrue(app.staticTexts["host-scope"].exists)
    }
}
