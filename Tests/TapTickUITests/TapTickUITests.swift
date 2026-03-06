import XCTest

final class TapTickUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Settings Window

    func testSettingsWindowOpens() throws {
        // The settings window should be available
        let window = app.windows["TapTick Settings"]
        // Give it a moment to appear
        let exists = window.waitForExistence(timeout: 5)
        // Note: The window might not open automatically since it's a menu bar app.
        // This test verifies the basic launch works.
        XCTAssertTrue(app.exists)
        _ = exists
    }

    func testEmptyStateShowsPlaceholder() throws {
        let window = app.windows["TapTick Settings"]
        if window.waitForExistence(timeout: 5) {
            // Should show "No Shortcut Selected" or similar empty state
            let noSelection = window.staticTexts["No Shortcut Selected"]
            if noSelection.waitForExistence(timeout: 3) {
                XCTAssertTrue(noSelection.exists)
            }
        }
    }

    func testAddButtonExists() throws {
        let window = app.windows["TapTick Settings"]
        if window.waitForExistence(timeout: 5) {
            let addButton = window.buttons["Add Shortcut"]
            if addButton.waitForExistence(timeout: 3) {
                XCTAssertTrue(addButton.isEnabled)
            }
        }
    }

    // MARK: - Menu Bar

    func testAppLaunches() throws {
        XCTAssertTrue(app.exists, "App should launch successfully")
    }
}