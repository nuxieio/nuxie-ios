import Foundation

private struct E2EArtifact: Decodable {
  let publicApiKey: String?
  let ingestUrl: String?
  let flowId: String?
}

struct E2EConfiguration: Equatable {
  static let apiKeyEnvKey = "NUXIE_E2E_API_KEY"
  static let ingestUrlEnvKey = "NUXIE_E2E_INGEST_URL"
  static let flowIdEnvKey = "NUXIE_E2E_FLOW_ID"
  static let artifactEnvKey = "NUXIE_E2E_ARTIFACT_PATH"

  static let defaultApiKey = "pk_test_placeholder"
  static let defaultIngestUrlString = "http://127.0.0.1:8084"
  static let defaultFlowId = "flow_placeholder"

  let apiKey: String
  let ingestUrl: URL
  let flowId: String

  var ingestUrlString: String {
    ingestUrl.absoluteString
  }

  static func fromProcessInfo(_ processInfo: ProcessInfo = .processInfo) -> E2EConfiguration {
    fromEnvironment(environment: processInfo.environment)
  }

  static func fromEnvironment(
    environment: [String: String],
    fileLoader: (String) -> Data? = { path in
      try? Data(contentsOf: URL(fileURLWithPath: path))
    }
  ) -> E2EConfiguration {
    let apiKeyOverride = nonEmpty(environment[apiKeyEnvKey])
    let ingestUrlOverride = nonEmpty(environment[ingestUrlEnvKey])
    let flowIdOverride = nonEmpty(environment[flowIdEnvKey])

    var artifact: E2EArtifact?
    if let artifactPath = nonEmpty(environment[artifactEnvKey]),
       let data = fileLoader(artifactPath) {
      artifact = try? JSONDecoder().decode(E2EArtifact.self, from: data)
    }

    let apiKey = apiKeyOverride
      ?? nonEmpty(artifact?.publicApiKey)
      ?? defaultApiKey

    let ingestUrlString = ingestUrlOverride
      ?? nonEmpty(artifact?.ingestUrl)
      ?? defaultIngestUrlString

    let flowId = flowIdOverride
      ?? nonEmpty(artifact?.flowId)
      ?? defaultFlowId

    let ingestUrl = URL(string: ingestUrlString)
      ?? URL(string: defaultIngestUrlString)!

    return E2EConfiguration(apiKey: apiKey, ingestUrl: ingestUrl, flowId: flowId)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }
}
