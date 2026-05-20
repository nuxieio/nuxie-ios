import XCTest

final class FlowRuntimeSmokeTests: XCTestCase {
    private var app: XCUIApplication!
    private let fixtureNames = [
        "layout-paint",
        "published-font",
        "pressable-interaction",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testPublishedFixturesRenderAndHandleNativeInput() throws {
        app.launchArguments = [
            "--nuxie-fixtures",
            fixtureNames.joined(separator: ","),
        ]
        app.launch()

        try selectFixture(named: "layout-paint")
        try waitForSurface()
        app.otherElements["nuxie-flow-surface"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .tap()
        try captureScreenshot(named: "layout-paint")

        try selectFixture(named: "published-font")
        try waitForSurface()

        let emailField = app.textFields["nuxie-text-input-text-input/screen_1/email_input"]
        XCTAssertTrue(
            emailField.waitForExistence(timeout: 10),
            "Expected the published editable text input overlay to mount"
        )

        emailField.tap()
        emailField.typeText("+native")

        XCTAssertTrue(
            emailField.waitForValue(containing: "+native", timeout: 5),
            "Expected typing in the native overlay to update the UIKit text input"
        )

        try captureScreenshot(named: "published-font")

        try selectFixture(named: "pressable-interaction")
        try waitForSurface()

        app.otherElements["nuxie-flow-surface"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .tap()

        let eventLog = app.staticTexts["nuxie-flow-event-log"]
        XCTAssertTrue(
            eventLog.waitForExistence(timeout: 5),
            "Expected the fixture runtime event log to mount"
        )
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "screen:screen_2", timeout: 10),
            "Expected tapping the published Pressable to emit a native interaction and reach the target screen"
        )

        try captureScreenshot(named: "pressable-interaction")
    }

    private func selectFixture(named fixtureName: String) throws {
        if app.staticTexts["nuxie-current-fixture"].label != fixtureName {
            let button = app.buttons["nuxie-fixture-\(fixtureName)"]
            XCTAssertTrue(
                button.waitForExistence(timeout: 10),
                "Expected fixture selector button for \(fixtureName)"
            )
            button.tap()
        }
        XCTAssertTrue(
            app.staticTexts["nuxie-current-fixture"].waitForLabel(containing: fixtureName, timeout: 10),
            "Expected host app to switch to fixture \(fixtureName)"
        )
    }

    private func waitForSurface() throws {
        let surface = app.otherElements["nuxie-flow-surface"]
        XCTAssertTrue(
            surface.waitForExistence(timeout: 20),
            "Expected the native Rive flow surface to mount"
        )
    }

    private func captureScreenshot(named name: String) throws {
        let screenshot = XCUIScreen.main.screenshot()

        XCTContext.runActivity(named: "Screenshot: \(name)") { activity in
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        guard let outputDirectory = ProcessInfo.processInfo.environment["NUXIE_FLOW_RUNTIME_OUTPUT_DIR"],
              !outputDirectory.isEmpty else {
            return
        }

        let screenshotsURL = URL(fileURLWithPath: outputDirectory)
            .appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(
            at: screenshotsURL,
            withIntermediateDirectories: true
        )
        try screenshot.pngRepresentation.write(
            to: screenshotsURL.appendingPathComponent("\(name).png"),
            options: .atomic
        )
    }
}

private extension XCUIElement {
    func waitForLabel(containing expectedValue: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", expectedValue)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func waitForValue(containing expectedValue: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value CONTAINS %@", expectedValue)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
