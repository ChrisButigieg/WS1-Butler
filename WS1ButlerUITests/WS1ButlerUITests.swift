import XCTest

/// End-to-end UI tests. `-uitesting` gives each launch in-memory storage (no Keychain or
/// disk writes); `-demo` additionally wires every server to an in-process mock UEM.
final class WS1ButlerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func open(_ app: XCUIApplication, section: String) {
        let row = element(app, "nav.\(section)")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Sidebar row \(section) missing")
        row.click()
    }

    @MainActor
    private func type(_ text: String, into identifier: String, in app: XCUIApplication) {
        let field = element(app, identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Field \(identifier) missing")
        // Scroll the editor sheet until the field is on screen.
        let scroller = app.sheets.scrollViews.firstMatch
        var attempts = 0
        while !field.isHittable, scroller.exists, attempts < 8 {
            scroller.scroll(byDeltaX: 0, deltaY: -120)
            attempts += 1
        }
        field.click()
        field.typeText(text)
    }

    @MainActor
    func testLaunchShowsEmptyNativeAppsConsole() throws {
        let app = launch(["-uitesting"])
        XCTAssertTrue(element(app, "emptyQueue").waitForExistence(timeout: 10))
        let engage = element(app, "engageButton")
        XCTAssertTrue(engage.exists)
        XCTAssertFalse(engage.isEnabled, "Engage must be disabled with an empty queue")
        XCTAssertTrue(element(app, "browseIPAButton").isEnabled)
    }

    @MainActor
    func testQuickSetupCreatesDevTestProd() throws {
        let app = launch(["-uitesting"])
        open(app, section: "servers")
        let quickSetup = element(app, "quickSetupButton")
        XCTAssertTrue(quickSetup.waitForExistence(timeout: 5))
        quickSetup.click()
        for name in ["Development", "Test", "Production"] {
            XCTAssertTrue(element(app, "serverCard.\(name)").waitForExistence(timeout: 5), "\(name) card missing")
        }
    }

    @MainActor
    func testAddServerWithBasicAuthentication() throws {
        let app = launch(["-uitesting"])
        open(app, section: "servers")
        element(app, "addServerButton").click()

        type("Lab UEM", into: "serverNameField", in: app)
        type("https://lab-uem.example.mil", into: "serverURLField", in: app)
        type("570", into: "serverOGField", in: app)

        let basic = app.radioButtons["Basic"].exists ? app.radioButtons["Basic"] : app.buttons["Basic"]
        XCTAssertTrue(basic.waitForExistence(timeout: 5))
        basic.click()
        type("api-admin", into: "serverUsernameField", in: app)
        // Tab through the credential fields like an operator would (they sit below the fold).
        app.typeText("\tpassword\ttenant-key")

        element(app, "saveServerButton").click()
        XCTAssertTrue(element(app, "serverCard.Lab UEM").waitForExistence(timeout: 5))
    }

    @MainActor
    func testDemoDeploymentToThreeServersWithReview() throws {
        let app = launch(["-demo"])
        let engage = element(app, "engageButton")
        XCTAssertTrue(engage.waitForExistence(timeout: 10))
        XCTAssertTrue(engage.isEnabled, "Demo queue and servers should arm the Engage button")
        engage.click()

        // Each server pauses for operator review; approve all three.
        for server in ["Development", "Test", "Production"] {
            let review = element(app, "reviewButton.\(server)")
            XCTAssertTrue(review.waitForExistence(timeout: 30), "Review checkpoint for \(server) never appeared")
            review.click()
            let approve = element(app, "reviewApproveButton")
            XCTAssertTrue(approve.waitForExistence(timeout: 5))
            approve.click()
            XCTAssertTrue(approve.waitForNonExistence(timeout: 5))
        }

        let finished = NSPredicate(format: "label CONTAINS[c] 'complete'")
        let completeChips = app.descendants(matching: .any).matching(finished)
        let deadline = Date().addingTimeInterval(30)
        while completeChips.count < 3, Date() < deadline {
            _ = app.wait(for: .runningForeground, timeout: 0.5)
        }
        XCTAssertGreaterThanOrEqual(completeChips.count, 3, "All three servers should report complete")
    }

    @MainActor
    func testActivityLogRecordsStartup() throws {
        let app = launch(["-uitesting"])
        open(app, section: "activity")
        XCTAssertTrue(element(app, "activityLogScreen").waitForExistence(timeout: 5), "Activity log not shown")
        let entry = element(app, "logEntry")
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "No log entries rendered")
        XCTAssertTrue(entry.label.contains("WS1 Butler online") || (entry.value as? String)?.contains("WS1 Butler online") == true,
                      "Unexpected first entry: \(entry.label)")
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = ["-uitesting"]
            app.launch()
        }
    }
}
