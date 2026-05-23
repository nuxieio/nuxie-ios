import CoreImage
import UIKit
import XCTest

final class FlowRuntimeSmokeTests: XCTestCase {
    private var app: XCUIApplication!
    private let fixtureNames = [
        "layout-paint",
        "published-font",
        "pressable-interaction",
    ]
    private let transitionEventName = "__nuxie_test_run_transition"

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

        let surface = app.otherElements["nuxie-flow-surface"]
        let pressPoint = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let releasePoint = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.22))
        let samplePoint = CGPoint(x: surface.frame.midX, y: surface.frame.midY)

        Thread.sleep(forTimeInterval: 0.3)
        let releasedBeforePressScreenshot = try captureScreenshot(named: "pressable-interaction-released-before")
        let releasedBeforePressPixel = try samplePixel(
            in: releasedBeforePressScreenshot,
            atScreenPoint: samplePoint
        )

        let pressedScreenshot = try captureScreenshotDuringGesture(
            named: "pressable-interaction-pressed",
            after: 0.35
        ) {
            pressPoint.press(forDuration: 0.8, thenDragTo: releasePoint)
        }
        let pressedPixel = try samplePixel(
            in: pressedScreenshot,
            atScreenPoint: samplePoint
        )

        Thread.sleep(forTimeInterval: 0.25)
        let releasedAfterPressScreenshot = try captureScreenshot(named: "pressable-interaction-released-after")
        let releasedAfterPressPixel = try samplePixel(
            in: releasedAfterPressScreenshot,
            atScreenPoint: samplePoint
        )

        XCTAssertGreaterThan(
            pressedPixel.distance(to: releasedBeforePressPixel),
            70,
            "Expected authored pressedStyle to visibly change the published Pressable fill while the touch is held"
        )
        XCTAssertLessThan(
            releasedAfterPressPixel.distance(to: releasedBeforePressPixel),
            35,
            "Expected dragging out/releasing the Pressable to restore the base visual state"
        )

        pressPoint.tap()

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

    func testTextInputMotionMovesWholeEditableField() throws {
        try launchFixture(
            named: "text-input-motion",
            scenarioTitle: "Animated TextInput follows its rendered field",
            scenarioExpectation: "The entire TextInput node moves to the right; the native editor overlay should stay aligned with the Rive field background."
        )

        try waitForSurface()
        let movingFieldIdentifier = "nuxie-text-input-text-input/screen_1/email_input"
        let emailField = app.textFields[movingFieldIdentifier]
        XCTAssertTrue(
            emailField.waitForExistence(timeout: 10),
            "Expected the moving editable text input overlay to mount"
        )

        let initialMovingFieldFrame = emailField.frame
        try captureScreenshot(named: "text-input-motion-before")

        Thread.sleep(forTimeInterval: 1.4)
        let movedFieldFrame = emailField.frame
        XCTAssertGreaterThan(
            abs(movedFieldFrame.midX - initialMovingFieldFrame.midX),
            16,
            "Expected the UIKit text input overlay to follow the animated TextInput node"
        )

        try captureScreenshot(named: "text-input-motion-after")
        pauseForRecordedReview()
    }

    func testSystemPushTransitionUsesTwoLiveRiveSurfacesUntilCompletion() throws {
        try launchFixture(
            named: "screen-transition-push",
            manualEventName: transitionEventName,
            scenarioTitle: "System push: screen_1 -> screen_2",
            scenarioExpectation: "Tap Run transition; screen_2 should push in as a second live Rive surface, then become current."
        )

        try waitForSurface()
        let eventLog = app.staticTexts["nuxie-flow-event-log"]
        XCTAssertTrue(
            eventLog.waitForExistence(timeout: 10),
            "Expected the fixture runtime event log to mount"
        )

        pauseForRecordedReview()
        try captureScreenshot(named: "screen-transition-push-before")
        tapManualStart()

        XCTAssertTrue(
            eventLog.waitForLabel(containing: "navigated:screen_2", timeout: 10),
            "Expected the fixture start action to request a push transition"
        )
        pauseForRecordedReview(0.2)
        try captureScreenshot(named: "screen-transition-push-during")

        XCTAssertTrue(
            eventLog.waitForLabel(containing: "screen:screen_2", timeout: 10),
            "Expected screen_shown to arrive after the push transition completes"
        )
        pauseForRecordedReview()
        try captureScreenshot(named: "screen-transition-push-after")
    }

    func testSystemPresentTransitionReachesDestinationScreen() throws {
        try launchFixture(
            named: "screen-transition-push",
            variant: "present",
            manualEventName: transitionEventName,
            scenarioTitle: "System present: screen_1 presents screen_2",
            scenarioExpectation: "Tap Run transition; UIKit should present screen_2 as a native sheet modal with its own live Rive surface."
        )

        try waitForSurface()
        pauseForRecordedReview()
        tapManualStart()
        pauseForRecordedReview(0.2)
        try captureScreenshot(named: "screen-transition-present-during")

        XCTAssertTrue(
            waitForSurfaceLabel(containing: "screen_2", timeout: 10),
            "Expected the presented sheet controller to mount a live screen_2 Rive surface"
        )

        let presentedSurface = surfaceElement(containing: "screen_2")
        XCTAssertTrue(
            presentedSurface.exists,
            "Expected to locate the presented screen_2 surface"
        )
        XCTAssertGreaterThan(
            presentedSurface.frame.minY,
            app.windows.element(boundBy: 0).frame.minY + 1,
            "Expected present transition to use a sheet modal, not a full-screen cover"
        )
        pauseForRecordedReview()
        try captureScreenshot(named: "screen-transition-present-after")
    }

    func testSystemPresentSwipeDismissReturnsToPresentingScreen() throws {
        try launchFixture(
            named: "screen-transition-push",
            variant: "present",
            manualEventName: transitionEventName,
            scenarioTitle: "System present dismissal: screen_2 -> screen_1",
            scenarioExpectation: "Tap Run transition; swipe down the sheet. The coordinator should report screen_2 dismissed and the journey should return to screen_1."
        )

        try waitForSurface()
        let eventLog = app.staticTexts["nuxie-flow-event-log"]
        XCTAssertTrue(
            eventLog.waitForExistence(timeout: 10),
            "Expected the fixture runtime event log to mount"
        )

        pauseForRecordedReview()
        tapManualStart()
        XCTAssertTrue(
            waitForSurfaceLabel(containing: "screen_2", timeout: 10),
            "Expected the presented sheet controller to mount a live screen_2 Rive surface"
        )
        pauseForRecordedReview()
        try captureScreenshot(named: "screen-transition-present-dismissible-before")

        let presentedSurface = surfaceElement(containing: "screen_2")
        let start = presentedSurface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        let end = app.windows.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
        start.press(forDuration: 0.1, thenDragTo: end)

        XCTAssertTrue(
            eventLog.waitForLabel(containing: "screen_dismissed:screen_2", timeout: 10),
            "Expected native sheet dismissal to be reported to the fixture runner"
        )
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "screen:screen_1", timeout: 10),
            "Expected native sheet dismissal to reveal and re-enter screen_1"
        )
        XCTAssertTrue(
            waitForSurfaceLabel(containing: "screen_1", timeout: 10),
            "Expected the underlying screen_1 Rive surface to be current after sheet dismissal"
        )
        pauseForRecordedReview()
        try captureScreenshot(named: "screen-transition-present-dismissible-after")
    }

    func testBackTransitionReturnsWithReversePushPayload() throws {
        try launchFixture(
            named: "screen-transition-push",
            variant: "back-push",
            initialNavigationStack: ["screen_1"],
            manualEventName: transitionEventName,
            scenarioTitle: "Back transition: screen_2 -> screen_1",
            scenarioExpectation: "Tap Run transition; screen_2 pushes in, then its screen_shown action backs out with a reverse push to screen_1."
        )

        try waitForSurface()
        let eventLog = app.staticTexts["nuxie-flow-event-log"]
        XCTAssertTrue(
            eventLog.waitForExistence(timeout: 10),
            "Expected the fixture runtime event log to mount"
        )

        pauseForRecordedReview()
        tapManualStart()

        XCTAssertTrue(
            eventLog.waitForLabel(containing: "navigated:screen_2", timeout: 10),
            "Expected the fixture start action to push to screen_2"
        )
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "screen:screen_2", timeout: 10),
            "Expected the destination screen to be shown before the back action runs"
        )
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "navigated:screen_1", timeout: 10),
            "Expected the screen_2 screen_shown interaction to request back with a reverse push transition"
        )
        pauseForRecordedReview(0.2)
        try captureScreenshot(named: "screen-transition-back-push-during")

        XCTAssertTrue(
            eventLog.waitForLabel(containing: "screen:screen_1", timeout: 10),
            "Expected the reverse push back transition to complete on screen_1"
        )
        pauseForRecordedReview()
        try captureScreenshot(named: "screen-transition-back-push-after")
    }

    func testReduceMotionFallsBackToInstantReplacement() throws {
        try launchFixture(
            named: "screen-transition-push",
            variant: "reduce-motion-dissolve",
            forceReduceMotion: true,
            manualEventName: transitionEventName,
            scenarioTitle: "Reduce motion: skip authored dissolve",
            scenarioExpectation: "Tap Run transition; the fixture asks for a 5s dissolve, but forced reduce motion should replace it immediately."
        )

        try waitForSurface()
        let eventLog = app.staticTexts["nuxie-flow-event-log"]
        XCTAssertTrue(
            eventLog.waitForExistence(timeout: 10),
            "Expected the fixture runtime event log to mount"
        )

        pauseForRecordedReview()
        let startButton = waitForManualStartButton()
        let startedAt = Date()
        startButton.tap()
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "screen:screen_2", timeout: 3.5),
            "Expected forced reduce motion to skip the authored 5s dissolve and show screen_2 quickly"
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            3.5,
            "Expected reduce motion replacement to complete without waiting for the authored dissolve duration"
        )
        pauseForRecordedReview()
        try captureScreenshot(named: "screen-transition-reduce-motion-after")
    }

    func testTextInputOverlayRebindsAfterBackTransition() throws {
        try launchFixture(
            named: "screen-transition-push",
            variant: "back-push",
            initialNavigationStack: ["screen_1"],
            manualEventName: transitionEventName,
            scenarioTitle: "Static native text input survives screen transitions",
            scenarioExpectation: "Tap Run transition; after push and back, the UIKit text input overlay should remount on screen_1 and remain editable."
        )

        try waitForSurface()
        let eventLog = app.staticTexts["nuxie-flow-event-log"]
        XCTAssertTrue(
            eventLog.waitForExistence(timeout: 10),
            "Expected the fixture runtime event log to mount"
        )
        pauseForRecordedReview()
        tapManualStart()
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "navigated:screen_2", timeout: 10),
            "Expected the fixture to navigate away from the input-owning screen"
        )
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "screen:screen_2", timeout: 10),
            "Expected the destination screen to be shown before the back action runs"
        )
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "navigated:screen_1", timeout: 10),
            "Expected the screen_2 screen_shown interaction to request the back transition"
        )
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "screen:screen_1", timeout: 10),
            "Expected the fixture to complete back on the input-owning screen"
        )

        let emailField = app.textFields["nuxie-text-input-text-input/screen_1/email_input"]
        XCTAssertTrue(
            emailField.waitForExistence(timeout: 10),
            "Expected the screen_1 editable text input overlay to remount after the back transition"
        )
        XCTAssertTrue(
            emailField.isHittable,
            "Expected the remounted text input overlay to be active on the current screen"
        )

        emailField.tap()
        emailField.typeText("+afterback")
        XCTAssertTrue(
            emailField.waitForValue(containing: "+afterback", timeout: 5),
            "Expected typing after the transition to update the rebound UIKit text input"
        )
        pauseForRecordedReview()
        try captureScreenshot(named: "screen-transition-text-input-after-back")
    }

    private func launchFixture(
        named fixtureName: String,
        variant: String? = nil,
        initialNavigationStack: [String] = [],
        forceReduceMotion: Bool = false,
        manualEventName: String? = nil,
        scenarioTitle: String? = nil,
        scenarioExpectation: String? = nil
    ) throws {
        var arguments = [
            "--nuxie-fixture",
            fixtureName,
        ]
        if let variant {
            arguments.append(contentsOf: [
                "--nuxie-flow-description-variant",
                variant,
            ])
        }
        if forceReduceMotion {
            arguments.append("--nuxie-force-reduce-motion")
        }
        if let manualEventName {
            arguments.append(contentsOf: [
                "--nuxie-manual-event",
                manualEventName,
                "--nuxie-show-screen-debug-badges",
            ])
        }
        if !initialNavigationStack.isEmpty {
            arguments.append(contentsOf: [
                "--nuxie-initial-navigation-stack",
                initialNavigationStack.joined(separator: ","),
            ])
        }
        if let scenarioTitle {
            arguments.append(contentsOf: [
                "--nuxie-scenario-title",
                scenarioTitle,
            ])
        }
        if let scenarioExpectation {
            arguments.append(contentsOf: [
                "--nuxie-scenario-expectation",
                scenarioExpectation,
            ])
        }
        app.launchArguments = arguments
        app.launch()
        try selectFixture(named: fixtureName)
    }

    private func selectFixture(named fixtureName: String) throws {
        let currentFixtureLabel = app.staticTexts["nuxie-current-fixture"]
        if currentFixtureLabel.exists && currentFixtureLabel.label == fixtureName {
            return
        }

        if currentFixtureLabel.exists {
            let backButton = app.navigationBars.buttons["Fixtures"]
            XCTAssertTrue(
                backButton.waitForExistence(timeout: 10),
                "Expected navigation back button to return to the fixture list"
            )
            backButton.tap()
        }

        let fixtureRow = app.cells["nuxie-fixture-\(fixtureName)"]
        XCTAssertTrue(
            fixtureRow.waitForExistence(timeout: 10),
            "Expected fixture table row for \(fixtureName)"
        )
        fixtureRow.tap()

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

    private func waitForSurfaceLabel(containing expectedValue: String, timeout: TimeInterval) -> Bool {
        let query = app.otherElements.matching(identifier: "nuxie-flow-surface")
        let predicate = NSPredicate { _, _ in
            guard query.count > 0 else { return false }
            for index in 0..<query.count {
                if query.element(boundBy: index).label.contains(expectedValue) {
                    return true
                }
            }
            return false
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func surfaceElement(containing expectedValue: String) -> XCUIElement {
        let query = app.otherElements.matching(identifier: "nuxie-flow-surface")
        for index in 0..<query.count {
            let element = query.element(boundBy: index)
            if element.label.contains(expectedValue) {
                return element
            }
        }
        return query.element(boundBy: 0)
    }

    private func tapManualStart() {
        waitForManualStartButton().tap()
    }

    private func waitForManualStartButton() -> XCUIElement {
        let button = app.buttons["nuxie-flow-manual-start"]
        XCTAssertTrue(
            button.waitForExistence(timeout: 10),
            "Expected the fixture harness to show the manual start control"
        )
        return button
    }

    private func pauseForRecordedReview(_ duration: TimeInterval = 0.45) {
        Thread.sleep(forTimeInterval: duration)
    }

    @discardableResult
    private func captureScreenshot(named name: String) throws -> XCUIScreenshot {
        let screenshot = XCUIScreen.main.screenshot()
        try recordScreenshot(screenshot, named: name)
        return screenshot
    }

    private func captureScreenshotDuringGesture(
        named name: String,
        after delay: TimeInterval,
        gesture: () -> Void
    ) throws -> XCUIScreenshot {
        let expectation = expectation(description: "capture \(name)")
        let lock = NSLock()
        var capturedScreenshot: XCUIScreenshot?

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
            let screenshot = XCUIScreen.main.screenshot()
            lock.lock()
            capturedScreenshot = screenshot
            lock.unlock()
            expectation.fulfill()
        }

        gesture()

        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: delay + 2),
            .completed,
            "Expected to capture \(name) while the gesture was still active"
        )

        lock.lock()
        let screenshot = capturedScreenshot
        lock.unlock()

        guard let screenshot else {
            throw FlowRuntimeUITestError.missingScreenshot(name)
        }

        try recordScreenshot(screenshot, named: name)
        return screenshot
    }

    private func recordScreenshot(_ screenshot: XCUIScreenshot, named name: String) throws {
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

    private func samplePixel(
        in screenshot: XCUIScreenshot,
        atScreenPoint point: CGPoint
    ) throws -> ScreenshotPixel {
        guard let image = UIImage(data: screenshot.pngRepresentation),
              let cgImage = image.cgImage else {
            throw FlowRuntimeUITestError.invalidScreenshot
        }

        let windowFrame = app.windows.element(boundBy: 0).frame
        let normalizedX = (point.x - windowFrame.minX) / max(windowFrame.width, 1)
        let normalizedY = (point.y - windowFrame.minY) / max(windowFrame.height, 1)
        let pixelX = min(
            max(Int((normalizedX * CGFloat(cgImage.width)).rounded()), 0),
            cgImage.width - 1
        )
        let pixelY = min(
            max(Int((normalizedY * CGFloat(cgImage.height)).rounded()), 0),
            cgImage.height - 1
        )

        let sampleSize = 5
        let sampleX = min(max(pixelX - sampleSize / 2, 0), cgImage.width - sampleSize)
        let sampleYFromTop = min(max(pixelY - sampleSize / 2, 0), cgImage.height - sampleSize)
        let sampleY = cgImage.height - sampleYFromTop - sampleSize
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CIContext(options: [.workingColorSpace: colorSpace])
        let ciImage = CIImage(cgImage: cgImage)
        var bitmap = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        context.render(
            ciImage,
            toBitmap: &bitmap,
            rowBytes: sampleSize * 4,
            bounds: CGRect(x: sampleX, y: sampleY, width: sampleSize, height: sampleSize),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        var red = 0
        var green = 0
        var blue = 0
        var alpha = 0
        for offset in stride(from: 0, to: bitmap.count, by: 4) {
            red += Int(bitmap[offset])
            green += Int(bitmap[offset + 1])
            blue += Int(bitmap[offset + 2])
            alpha += Int(bitmap[offset + 3])
        }
        let count = sampleSize * sampleSize
        return ScreenshotPixel(
            red: red / count,
            green: green / count,
            blue: blue / count,
            alpha: alpha / count
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

private struct ScreenshotPixel {
    let red: Int
    let green: Int
    let blue: Int
    let alpha: Int

    func distance(to other: ScreenshotPixel) -> Double {
        let redDelta = Double(red - other.red)
        let greenDelta = Double(green - other.green)
        let blueDelta = Double(blue - other.blue)
        return sqrt(redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta)
    }
}

private enum FlowRuntimeUITestError: Error {
    case invalidScreenshot
    case missingScreenshot(String)
}
