import XCTest

final class LiveCameraUITests: XCTestCase {
    func testRehearseWithoutAnAccountAndReturnToTheStudio() {
        let app = XCUIApplication()
        app.launchArguments = ["-clean-camera-frame-fixture"]
        app.launch()
        app.buttons["Dance camera"].tap()
        let setup = app.buttons["TikTok LIVE setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 12))
        setup.tap()

        let clean = app.buttons["live.showCleanCamera"]
        XCTAssertTrue(clean.waitForExistence(timeout: 6))
        clean.tap()
        let controls = app.buttons["Show camera controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 6))
        XCTAssertFalse(app.buttons["Record take"].exists)
        // Leave the clean view onscreen for more than one full fixture cycle.
        let recorded = expectation(description: "Capture both camera patterns")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { recorded.fulfill() }
        wait(for: [recorded], timeout: 6)
        controls.tap()
        XCTAssertTrue(setup.waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["Record take"].exists)
    }
}
