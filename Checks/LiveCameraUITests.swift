import XCTest

final class LiveCameraUITests: XCTestCase {
    func testOpenPreviewAndChangeModesWithTheSamePlayingOrPausedSong() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-live-overlay-song-fixture", "-inspect-camera-continuity"]
        app.launch()
        let entry = app.buttons["camera.openStudio"]
        XCTAssertTrue(entry.waitForExistence(timeout: 12))
        let libraryTrack = app.staticTexts["music.track"]
        let studioTrack = app.staticTexts["studio.track"]
        func clock(on track: XCUIElement) -> (session: String, frame: Int64)? {
            guard track.exists, let value = track.value as? String else { return nil }
            let parts = value.split(separator: "|")
            guard parts.count == 2, let frame = Int64(parts[1]) else { return nil }
            return (String(parts[0]), frame)
        }
        func waitForFrame(on track: XCUIElement, after previous: Int64) {
            let nextFrame = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (clock(on: track)?.frame ?? -1) > previous
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [nextFrame], timeout: 15), .completed)
        }
        func savePreview(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        waitForFrame(on: libraryTrack, after: 0)
        guard let before = clock(on: libraryTrack) else { XCTFail("The playing WAV has no node clock."); return }
        XCTAssertTrue(app.buttons["music.next"].exists)
        entry.tap()
        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 8))
        XCTAssertEqual(shutter.label, "Record take")
        XCTAssertFalse(app.switches["Finish at original song tempo"].exists)
        XCTAssertEqual(app.buttons["camera.tempo"].value as? String, "0.75×")
        XCTAssertFalse(libraryTrack.exists)
        waitForFrame(on: studioTrack, after: before.frame)
        XCTAssertEqual(clock(on: studioTrack)?.session, before.session)
        savePreview("dance-camera-record-preview")

        let modes = app.segmentedControls["camera.mode"]
        modes.buttons["Stream"].tap()
        XCTAssertTrue(app.buttons["live.fullscreen"].exists)
        XCTAssertTrue(app.buttons["camera.streamSetup"].exists)
        XCTAssertFalse(app.buttons["live.reveal"].exists)
        XCTAssertFalse(shutter.exists)
        XCTAssertTrue(app.buttons["studio.next"].exists)
        XCTAssertEqual(clock(on: studioTrack)?.session, before.session)
        savePreview("dance-camera-stream-preview")

        app.buttons["camera.backToMusic"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["music.transport"].label, "Pause")
        app.buttons["music.transport"].tap()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Play'"),
                                               object: app.buttons["music.transport"])
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 8), .completed)
        entry.tap()
        XCTAssertEqual(shutter.label, "Record take")
        XCTAssertEqual(app.buttons["studio.transport"].label, "Play")
        XCTAssertTrue(app.buttons["studio.next"].exists)
        XCTAssertEqual(clock(on: studioTrack)?.session, before.session)
        app.buttons["camera.details"].tap()
        XCTAssertTrue(app.switches["Finish at original song tempo"].waitForExistence(timeout: 8))
        app.buttons["Done"].tap()
        app.buttons["camera.backToMusic"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["music.transport"].label, "Play")
    }

    func testFullscreenControlsHideAfterInactivity() {
        let app = XCUIApplication()
        app.launchArguments = ["-clean-camera-frame-fixture"]
        app.launch()
        app.buttons["camera.openStudio"].tap()
        app.segmentedControls["camera.mode"].buttons["Stream"].tap()
        app.buttons["live.fullscreen"].tap()
        app.buttons["live.reveal"].tap()
        let exit = app.buttons["live.exit"]
        XCTAssertTrue(exit.exists)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: exit)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 18), .completed)
        XCTAssertTrue(app.buttons["live.reveal"].exists)
        XCTAssertFalse(app.buttons["camera.shutter"].exists)
    }

    func testFullscreenHostingAndReturningToStudio() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-clean-camera-frame-fixture", "-live-overlay-song-fixture",
                               "-live-picker-capture-fixture", "-inspect-live-host-controls"]
        app.launch()
        app.buttons["camera.openStudio"].tap()
        let modes = app.segmentedControls["camera.mode"]
        XCTAssertEqual(app.buttons["camera.shutter"].label, "Record take")
        modes.buttons["Stream"].tap()

        let fullscreen = app.buttons["live.fullscreen"]
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 12))
        fullscreen.tap()
        let reveal = app.buttons["live.reveal"]
        let exit = app.buttons["live.exit"]
        let song = app.descendants(matching: .any).matching(identifier: "live.nowPlaying").firstMatch

        func hostButton(_ id: String) -> XCUIElement {
            let button = app.buttons[id]
            if !button.exists {
                reveal.tap()
                XCTAssertTrue(button.waitForExistence(timeout: 8), id)
            }
            return button
        }

        XCTAssertTrue(reveal.waitForExistence(timeout: 6))
        XCTAssertFalse(app.buttons["camera.shutter"].exists)
        XCTAssertFalse(exit.exists)
        XCTAssertFalse(song.exists)
        let framing = hostButton("live.framing")
        XCTAssertEqual(framing.value as? String, "Fill")
        let songSwitch = hostButton("live.toggleSong")
        XCTAssertEqual(songSwitch.value as? String, "Off")
        songSwitch.tap()
        XCTAssertTrue(song.waitForExistence(timeout: 10))
        XCTAssertTrue(song.label.contains("Live Rehearsal"), song.label)

        // The ticker remains on the audience picture with the host panel hidden.
        hostButton("live.hide").tap()
        XCTAssertFalse(exit.exists)
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
        modes.buttons["Record"].tap()
        XCTAssertEqual(app.buttons["camera.shutter"].label, "Record take")
        modes.buttons["Stream"].tap()

        // Exercise the original entry point and the reachable system broadcast control.
        app.buttons["camera.streamSetup"].tap()
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
