import CoreImage
import UIKit
import XCTest

final class FlowRuntimeSmokeTests: XCTestCase {
    private var app: XCUIApplication!
    private let fixtureNames = [
        "layout-paint",
        "published-font",
        "text-input-motion",
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

        try selectFixture(named: "text-input-motion")
        try waitForSurface()

        let movingFieldIdentifier = "nuxie-text-input-text-input/screen_1/email_input"
        XCTAssertTrue(
            app.textFields[movingFieldIdentifier].waitForExistence(timeout: 10),
            "Expected the moving editable text input overlay to mount"
        )
        let initialMovingFieldFrame = app.textFields[movingFieldIdentifier].frame
        Thread.sleep(forTimeInterval: 1.4)
        let movedFieldFrame = app.textFields[movingFieldIdentifier].frame
        XCTAssertGreaterThan(
            movedFieldFrame.midX,
            initialMovingFieldFrame.midX + 16,
            "Expected the UIKit text input overlay to follow animated Rive text geometry"
        )

        try captureScreenshot(named: "text-input-motion")

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
