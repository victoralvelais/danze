import XCTest

final class LiveCameraUITests: XCTestCase {
    func testFullscreenHostingAndReturningToStudio() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-clean-camera-frame-fixture", "-live-overlay-song-fixture", "-live-picker-capture-fixture"]
        app.launch()
        app.buttons["Dance camera"].tap()

        let fullscreen = app.buttons["live.fullscreen"]
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 12))
        fullscreen.tap()
        let reveal = app.buttons["live.reveal"]
        let exit = app.buttons["live.exit"]
        let song = app.descendants(matching: .any).matching(identifier: "live.nowPlaying").firstMatch

        func hostButton(_ id: String) -> XCUIElement {
            let button = app.buttons[id]
            if !button.exists { reveal.tap() }
            XCTAssertTrue(button.waitForExistence(timeout: 4))
            return button
        }

        XCTAssertTrue(reveal.waitForExistence(timeout: 6))
        XCTAssertFalse(app.buttons["Record take"].exists)
        XCTAssertFalse(exit.exists)
        XCTAssertFalse(song.exists)
        let framing = hostButton("live.framing")
        XCTAssertEqual(framing.value as? String, "Fill")
        let songSwitch = hostButton("live.toggleSong")
        XCTAssertEqual(songSwitch.value as? String, "Off")
        songSwitch.tap()
        XCTAssertTrue(song.waitForExistence(timeout: 10))
        XCTAssertTrue(song.label.contains("Live Rehearsal"), song.label)

        // The ticker stays on the audience picture when the host panel times out.
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: exit)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 14), .completed)
        XCTAssertTrue(song.exists)

        hostButton("live.playback").tap()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS[c] 'paused'"), object: song)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 8), .completed)
        hostButton("live.playback").tap()

        hostButton("live.framing").tap()
        XCTAssertEqual(framing.value as? String, "Fit")
        hostButton("live.toggleSong").tap()
        XCTAssertFalse(song.exists)
        hostButton("live.hide").tap()
        // The system screen recording must see both moving patterns even in Fit.
        let painted = expectation(description: "Capture two alternating camera frames")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { painted.fulfill() }
        wait(for: [painted], timeout: 5)

        hostButton("live.microphone").tap()
        XCTAssertTrue(app.navigationBars["Microphone"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "live.systemMicPicker").firstMatch.exists)
        app.buttons["live.closeMic"].tap()
        XCTAssertTrue(reveal.waitForExistence(timeout: 6))
        hostButton("live.exit").tap()
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["Record take"].exists)

        // Exercise the original entry point and the reachable system broadcast control.
        app.buttons["TikTok LIVE setup"].tap()
        let picker = app.descendants(matching: .any).matching(identifier: "live.startBroadcast").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 6))
        // A broadcast extension can stop immediately after the iOS screen capture
        // starts. The setup must keep its picker mounted and give the host a retry path.
        let recovery = app.descendants(matching: .any).matching(identifier: "live.captureRecovery").firstMatch
        XCTAssertTrue(recovery.waitForExistence(timeout: 12))
        XCTAssertTrue(picker.exists)
        XCTAssertFalse(reveal.exists)
        app.buttons["live.showCleanCamera"].tap()
        XCTAssertTrue(reveal.waitForExistence(timeout: 6))
        XCTAssertEqual(hostButton("live.framing").value as? String, "Fit")
    }
}
