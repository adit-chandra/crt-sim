import XCTest

final class PlayerUITests: XCTestCase {
    @MainActor
    func testDemoTransportSettingsAndRotation() {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--demo", "--paused"]
        app.launch()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 20))
        attach(app, name: "Portrait player")
        app.buttons["CRT Settings"].tap()
        XCTAssertTrue(app.navigationBars["CRT Settings"].waitForExistence(timeout: 5))
        attach(app, name: "CRT settings")
        app.buttons["Done"].tap()
        app.buttons["Play"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        app.buttons["Pause"].tap()
        app.buttons["Forward 10 seconds"].tap()
        XCTAssertNotEqual(app.staticTexts["playbackTime"].label, "0:00")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        let landscape = NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return frame.width > frame.height
        }
        expectation(for: landscape, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        attach(app, name: "Landscape player")
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testPlaybackOptionsStayOpenWhileControlsAutoHide() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--paused"]
        app.launch()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 20))
        app.buttons["Play"].tap()
        app.buttons["Playback Options"].tap()
        let loop = app.buttons["Loop"]
        XCTAssertTrue(loop.waitForExistence(timeout: 3))
        let elapsed = expectation(description: "Pass the control auto-hide delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { elapsed.fulfill() }
        waitForExpectations(timeout: 6)
        XCTAssertTrue(loop.exists)
        loop.tap()
    }

    @MainActor
    func testEmptyStateAndFilePicker() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Try Test Pattern"].waitForExistence(timeout: 10))
        app.buttons["Open Video"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        app.buttons["Try Test Pattern"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 15))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
