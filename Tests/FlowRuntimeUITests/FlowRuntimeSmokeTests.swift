import XCTest

final class FlowRuntimeSmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testLayoutFixtureRendersAndCanReceiveATap() throws {
        app.launchArguments = [
            "--nuxie-fixture",
            "layout-paint",
        ]
        try launchAndCapture(fixtureName: "layout-paint")
    }

    func testPublishedFontFixtureRendersWithExternalAssets() throws {
        app.launchArguments = [
            "--nuxie-fixture",
            "published-font",
        ]
        try launchAndCapture(fixtureName: "published-font")
    }

    func testPublishedPressableFixtureRunsNativeInteractionAction() throws {
        app.launchArguments = [
            "--nuxie-fixture",
            "pressable-interaction",
        ]
        app.launch()

        let surface = app.otherElements["nuxie-flow-surface"]
        XCTAssertTrue(
            surface.waitForExistence(timeout: 20),
            "Expected the native Rive flow surface to mount"
        )

        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let eventLog = app.staticTexts["nuxie-flow-event-log"]
        XCTAssertTrue(
            eventLog.waitForExistence(timeout: 5),
            "Expected the fixture runtime event log to mount"
        )
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "navigated:screen_2", timeout: 10),
            "Expected tapping the published Pressable to emit a native interaction and run the flow navigate action"
        )

        try captureScreenshot(named: "pressable-interaction")
    }

    private func launchAndCapture(fixtureName: String) throws {
        app.launch()
        let surface = app.otherElements["nuxie-flow-surface"]
        XCTAssertTrue(
            surface.waitForExistence(timeout: 20),
            "Expected the native Rive flow surface to mount"
        )

        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try captureScreenshot(named: fixtureName)
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
}
