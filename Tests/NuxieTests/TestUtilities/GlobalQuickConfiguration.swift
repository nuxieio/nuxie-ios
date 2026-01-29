import Foundation
import Quick
import XCTest
import FactoryKit
@testable import Nuxie

/// Global Quick configuration to centralize test setup/teardown.
final class GlobalQuickConfiguration: QuickConfiguration {
  override class func configure(_ configuration: QCKConfiguration) {
    configuration.beforeEach {
      MockFactory.resetUsageFlag()

      if NuxieSDK.shared.configuration != nil {
        runAsyncAndWait(description: "NuxieSDK.shutdown (pre)") {
          await NuxieSDK.shared.shutdown()
        }
      }
    }

    configuration.afterEach {
      // Clear any registered network stubs between examples.
      TestURLSessionProvider.reset()

      // Ensure a configuration exists so EventService resolution doesn't crash in tests
      // that don't call NuxieSDK.setup.
      if NuxieSDK.shared.configuration == nil {
        Container.shared.sdkConfiguration.register { NuxieConfiguration(apiKey: "test-api-key") }
      }

      // Drain queued event work to reduce async noise between tests.
      runAsyncAndWait(description: "EventService.drain") {
        await Container.shared.eventService().drain()
      }

      // Shut down the SDK if it was configured during the test.
      if NuxieSDK.shared.configuration != nil {
        runAsyncAndWait(description: "NuxieSDK.shutdown") {
          await NuxieSDK.shared.shutdown()
        }
      }

      if MockFactory.wasUsed {
        runAsyncAndWait(description: "MockFactory.resetAll") {
          await MockFactory.shared.resetAll()
        }
      }

      Container.shared.reset()
      Container.shared.sdkConfiguration.register { NuxieConfiguration(apiKey: "test-api-key") }
    }
  }

  private class func runAsyncAndWait(
    description: String,
    timeout: TimeInterval = 5.0,
    operation: @escaping @Sendable () async -> Void
  ) {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
      await operation()
      semaphore.signal()
    }
    let result = semaphore.wait(timeout: .now() + timeout)
    if result == .timedOut {
      print("WARN: Timed out waiting for \(description)")
    }
  }
}
