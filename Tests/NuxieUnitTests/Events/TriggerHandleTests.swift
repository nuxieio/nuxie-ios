import FactoryKit
import Foundation
import Nimble
import Quick

@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

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

final class TriggerUpdateRecorder {
    private let lock = NSLock()
    private var updates: [TriggerUpdate] = []

    func append(_ update: TriggerUpdate) {
        lock.lock()
        defer { lock.unlock() }
        updates.append(update)
    }

    func snapshot() -> [TriggerUpdate] {
        lock.lock()
        defer { lock.unlock() }
        return updates
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
                    recorder.append(update)
                }

                var streamed: [TriggerUpdate] = []
                for await update in handle {
                    streamed.append(update)
                }

                expect(streamed).to(equal(updates))
                let recorded = recorder.snapshot()
                expect(recorded).to(equal(updates))
            }

            it("keeps the stream open for a gate result after suppression") {
                let updates: [TriggerUpdate] = [
                    .decision(.suppressed(.alreadyActive)),
                    .decision(.allowedImmediate)
                ]

                await mockTriggerService.setUpdates(updates)

                var streamed: [TriggerUpdate] = []
                let handle: Nuxie.TriggerHandle = NuxieSDK.shared.trigger("test_event")

                for await update in handle {
                    streamed.append(update)
                }

                expect(streamed).to(equal(updates))
            }

            it("keeps the stream open for a journey completion emitted after trigger returns") {
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

                await mockTriggerService.setUpdates(
                    [.decision(.journeyStarted(journeyRef))],
                    afterReturn: [.journey(journeyUpdate)]
                )

                var streamed: [TriggerUpdate] = []
                let handle: Nuxie.TriggerHandle = NuxieSDK.shared.trigger("test_event")

                for await update in handle {
                    streamed.append(update)
                }

                expect(streamed).to(equal([
                    .decision(.journeyStarted(journeyRef)),
                    .journey(journeyUpdate)
                ]))
            }
        }
    }
}
