import XCTest

final class E2EAppUITests: XCTestCase {
  func testSetupTransitionsToReady() {
    let app = XCUIApplication()
    let env = ProcessInfo.processInfo.environment

    if let apiKey = env["NUXIE_E2E_API_KEY"], !apiKey.isEmpty {
      app.launchEnvironment["NUXIE_E2E_API_KEY"] = apiKey
    } else {
      app.launchEnvironment["NUXIE_E2E_API_KEY"] = "pk_test_e2e"
    }

    if let ingestUrl = env["NUXIE_E2E_INGEST_URL"], !ingestUrl.isEmpty {
      app.launchEnvironment["NUXIE_E2E_INGEST_URL"] = ingestUrl
    } else {
      app.launchEnvironment["NUXIE_E2E_INGEST_URL"] = "http://127.0.0.1:8084"
    }

    if let flowId = env["NUXIE_E2E_FLOW_ID"], !flowId.isEmpty {
      app.launchEnvironment["NUXIE_E2E_FLOW_ID"] = flowId
    } else {
      app.launchEnvironment["NUXIE_E2E_FLOW_ID"] = "flow_test"
    }

    if let artifactPath = env["NUXIE_E2E_ARTIFACT_PATH"], !artifactPath.isEmpty {
      app.launchEnvironment["NUXIE_E2E_ARTIFACT_PATH"] = artifactPath
    }
    app.launch()

    var setupButton = app.buttons["setup-button"]
    if !setupButton.exists {
      setupButton = app.buttons["Setup SDK"]
    }

    var attempts = 0
    while !setupButton.exists && attempts < 5 {
      app.swipeUp()
      setupButton = app.buttons["setup-button"]
      if !setupButton.exists {
        setupButton = app.buttons["Setup SDK"]
      }
      attempts += 1
    }
    XCTAssertTrue(setupButton.waitForExistence(timeout: 15))
    setupButton.tap()

    var setupState = app.staticTexts["setup-state"]
    if !setupState.waitForExistence(timeout: 5) {
      setupState = app.staticTexts["ready"]
    }
    XCTAssertTrue(setupState.waitForExistence(timeout: 15))

    let readyPredicate = NSPredicate(format: "label == %@", "ready")
    expectation(for: readyPredicate, evaluatedWith: setupState)
    waitForExpectations(timeout: 15)
  }
}
