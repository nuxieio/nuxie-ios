import XCTest
@testable import NuxieE2EApp

final class E2EConfigurationTests: XCTestCase {
  func testEnvironmentOverridesArtifact() {
    let environment: [String: String] = [
      E2EConfiguration.apiKeyEnvKey: "pk_env",
      E2EConfiguration.ingestUrlEnvKey: "http://env.example",
      E2EConfiguration.flowIdEnvKey: "flow_env",
      E2EConfiguration.artifactEnvKey: "/tmp/artifact.json",
    ]

    let artifactJson = """
    {
      "publicApiKey": "pk_artifact",
      "ingestUrl": "http://artifact.example",
      "flowId": "flow_artifact"
    }
    """

    let configuration = E2EConfiguration.fromEnvironment(
      environment: environment,
      fileLoader: makeLoader(json: artifactJson)
    )

    XCTAssertEqual(configuration.apiKey, "pk_env")
    XCTAssertEqual(configuration.ingestUrlString, "http://env.example")
    XCTAssertEqual(configuration.flowId, "flow_env")
  }

  func testArtifactFallbackWhenEnvironmentMissing() {
    let environment: [String: String] = [
      E2EConfiguration.artifactEnvKey: "/tmp/artifact.json",
    ]

    let artifactJson = """
    {
      "publicApiKey": "pk_artifact",
      "ingestUrl": "http://artifact.example",
      "flowId": "flow_artifact"
    }
    """

    let configuration = E2EConfiguration.fromEnvironment(
      environment: environment,
      fileLoader: makeLoader(json: artifactJson)
    )

    XCTAssertEqual(configuration.apiKey, "pk_artifact")
    XCTAssertEqual(configuration.ingestUrlString, "http://artifact.example")
    XCTAssertEqual(configuration.flowId, "flow_artifact")
  }

  func testDefaultsWhenNoEnvironmentOrArtifact() {
    let configuration = E2EConfiguration.fromEnvironment(environment: [:]) { _ in nil }

    XCTAssertEqual(configuration.apiKey, E2EConfiguration.defaultApiKey)
    XCTAssertEqual(configuration.ingestUrlString, E2EConfiguration.defaultIngestUrlString)
    XCTAssertEqual(configuration.flowId, E2EConfiguration.defaultFlowId)
  }

  private func makeLoader(json: String) -> (String) -> Data? {
    { _ in json.data(using: .utf8) }
  }
}
