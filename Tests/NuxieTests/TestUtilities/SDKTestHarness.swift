import Foundation
import FactoryKit
@testable import Nuxie

/// Shared helper for SDK-backed integration tests that need isolated storage.
struct SDKTestHarness {
    let config: NuxieConfiguration
    let storageURL: URL
    let mockApi: MockNuxieApi

    static func make(
        prefix: String,
        enablePlugins: Bool = false,
        environment: Environment = .development,
        configure: ((inout NuxieConfiguration) -> Void)? = nil
    ) throws -> SDKTestHarness {
        let testId = UUID().uuidString
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let storageURL = baseURL.appendingPathComponent("\(prefix)_\(testId)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)

        var config = NuxieConfiguration(apiKey: "test-key-\(testId)")
        config.customStoragePath = storageURL
        config.environment = environment
        config.enablePlugins = enablePlugins
        configure?(&config)

        let mockApi = MockNuxieApi()
        Container.shared.nuxieApi.register { mockApi }

        return SDKTestHarness(config: config, storageURL: storageURL, mockApi: mockApi)
    }

    func setupSDK() throws {
        try NuxieSDK.shared.setup(with: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: storageURL)
    }
}
