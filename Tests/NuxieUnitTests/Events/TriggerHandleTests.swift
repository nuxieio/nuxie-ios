import FactoryKit
import Foundation
import Nimble
import Quick

@testable import Nuxie

private func runAsyncAndWait(
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

actor TriggerUpdateRecorder {
    private(set) var updates: [TriggerUpdate] = []

    func append(_ update: TriggerUpdate) {
        updates.append(update)
    }
}

final class TriggerHandleTests: AsyncSpec {
    override class func spec() {
        var harness: SDKTestHarness!
        var mockTriggerService: MockTriggerService!

        beforeEach {
            Container.shared.reset()

            mockTriggerService = MockTriggerService()
            Container.shared.triggerService.register { mockTriggerService }

            harness = try! SDKTestHarness.make(prefix: "trigger-handle")
            try! harness.setupSDK()
        }

        afterEach {
            runAsyncAndWait(description: "NuxieSDK.shutdown") {
                await NuxieSDK.shared.shutdown()
            }
            harness.cleanup()
        }

        describe("trigger handle") {
            it("streams updates from the trigger handle") {
                let journeyRef = JourneyRef(journeyId: "journey-1", campaignId: "campaign-1", flowId: "flow-1")
                let journeyUpdate = JourneyUpdate(
                    journeyId: "journey-1",
                    campaignId: "campaign-1",
                    flowId: "flow-1",
                    exitReason: .completed,
                    goalMet: false,
                    goalMetAt: nil,
                    durationSeconds: 1.25,
                    flowExitReason: nil
                )
                let updates: [TriggerUpdate] = [
                    .decision(.flowShown(journeyRef)),
                    .journey(journeyUpdate)
                ]

                await mockTriggerService.setUpdates(updates)

                var streamed: [TriggerUpdate] = []
                let handle: Nuxie.TriggerHandle = NuxieSDK.shared.trigger("test_event")

                for await update in handle {
                    streamed.append(update)
                }

                expect(streamed).to(equal(updates))
            }

            it("invokes the handler and the async stream") {
                let updates: [TriggerUpdate] = [
                    .decision(.allowedImmediate)
                ]

                await mockTriggerService.setUpdates(updates)

                let recorder = TriggerUpdateRecorder()
                let handle: Nuxie.TriggerHandle = NuxieSDK.shared.trigger("test_event") { update in
                    Task { await recorder.append(update) }
                }

                var streamed: [TriggerUpdate] = []
                for await update in handle {
                    streamed.append(update)
                }

                expect(streamed).to(equal(updates))
                let recorded = await recorder.updates
                expect(recorded).to(equal(updates))
            }
        }
    }
}
