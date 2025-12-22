import Foundation
import Nimble
import Quick

@testable import Nuxie

/// Contract under test:
/// - Unbound registration: if no flow is shown within the window, complete with `.noInteraction`.
/// - After bind (flow shown): do NOT time out; wait indefinitely for a flow-ending event.
/// - Non-terminal events (e.g., `$flow_shown`) and mismatched completions are ignored.
final class OutcomeBrokerTests: AsyncSpec {
  override class func spec() {
    describe("OutcomeBroker") {
      var broker: OutcomeBroker!

      beforeEach {
        broker = OutcomeBroker()
      }

      describe("timeout behavior") {
        it("calls completion with .noInteraction after timeout") {
          var capturedResult: EventResult?

          await broker.register(
            eventId: "test-event-1",
            timeout: 0.05,  // 50ms
            completion: { result in
              capturedResult = result
            }
          )

          // Wait for timeout to occur
          await expect(capturedResult)
            .toEventually(equal(.noInteraction), timeout: .milliseconds(100))
        }

        it("does not call completion twice if timeout occurs") {
          var callCount = 0

          await broker.register(
            eventId: "test-event-2",
            timeout: 0.05,
            completion: { _ in
              callCount += 1
            }
          )

          // Wait well past timeout
          try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms

          expect(callCount).to(equal(1))
        }

        it("cancels timeout when event is bound (and then waits indefinitely)") {
          var capturedResult: EventResult?

          await broker.register(
            eventId: "test-event-3",
            timeout: 0.1,  // 100ms
            completion: { result in
              capturedResult = result
            }
          )

          // Bind before timeout
          await broker.bind(
            eventId: "test-event-3",
            journeyId: "journey-1",
            flowId: "flow-1"
          )

          // Wait past original timeout; should NOT have timed out
          try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms
          expect(capturedResult).to(beNil())

          // Finish deterministically with a terminal event
          let completionEvent = NuxieEvent(
            name: JourneyEvents.flowDismissed,
            distinctId: "test-user",
            properties: [
              "journey_id": "journey-1",
              "flow_id": "flow-1",
            ]
          )
          await broker.observe(event: completionEvent)
          await expect(capturedResult).toEventuallyNot(beNil(), timeout: .milliseconds(100))
        }
      }

      describe("flow completion") {
        it("resolves to flow outcome when bound and completed") {
          var capturedResult: EventResult?

          await broker.register(
            eventId: "test-event-4",
            timeout: 1.0,
            completion: { result in
              capturedResult = result
            }
          )

          await broker.bind(
            eventId: "test-event-4",
            journeyId: "journey-2",
            flowId: "flow-2"
          )

          let completionEvent = NuxieEvent(
            name: JourneyEvents.flowDismissed,
            distinctId: "test-user",
            properties: [
              "journey_id": "journey-2",
              "flow_id": "flow-2",
            ]
          )

          await broker.observe(event: completionEvent)

          expect(capturedResult).toNot(beNil())

          if case .flow(let completion) = capturedResult {
            expect(completion.journeyId).to(equal("journey-2"))
            expect(completion.flowId).to(equal("flow-2"))
            expect(completion.outcome).to(equal(.dismissed))
          } else {
            fail("Expected flow result")
          }
        }

        it("maps purchase completion correctly") {
          var capturedResult: EventResult?

          await broker.register(
            eventId: "test-event-5",
            timeout: 1.0,
            completion: { capturedResult = $0 }
          )

          await broker.bind(
            eventId: "test-event-5",
            journeyId: "journey-3",
            flowId: "flow-3"
          )

          let completionEvent = NuxieEvent(
            name: JourneyEvents.flowPurchased,
            distinctId: "test-user",
            properties: [
              "journey_id": "journey-3",
              "flow_id": "flow-3",
              "product_id": "premium.monthly",
              "transaction_id": "txn_123",
            ]
          )

          await broker.observe(event: completionEvent)

          if case .flow(let completion) = capturedResult {
            if case .purchased(let productId, let transactionId) = completion.outcome {
              expect(productId).to(equal("premium.monthly"))
              expect(transactionId).to(equal("txn_123"))
            } else {
              fail("Expected purchased outcome")
            }
          } else {
            fail("Expected flow result")
          }
        }

        it("maps error completion with message") {
          var capturedResult: EventResult?

          await broker.register(
            eventId: "test-event-6",
            timeout: 1.0,
            completion: { capturedResult = $0 }
          )

          await broker.bind(
            eventId: "test-event-6",
            journeyId: "journey-4",
            flowId: "flow-4"
          )

          let completionEvent = NuxieEvent(
            name: JourneyEvents.flowErrored,
            distinctId: "test-user",
            properties: [
              "journey_id": "journey-4",
              "flow_id": "flow-4",
              "error_message": "Failed to load flow",
            ]
          )

          await broker.observe(event: completionEvent)

          if case .flow(let completion) = capturedResult {
            if case .error(let message) = completion.outcome {
              expect(message).to(equal("Failed to load flow"))
            } else {
              fail("Expected error outcome")
            }
          } else {
            fail("Expected flow result")
          }
        }
      }

      describe("edge cases") {
        it(
          "ignores events without matching binding and waits indefinitely until a correct completion arrives"
        ) {
          var capturedResult: EventResult?

          await broker.register(
            eventId: "test-event-7",
            timeout: 0.1,
            completion: { capturedResult = $0 }
          )

          // Bind to journey-5/flow-5
          await broker.bind(
            eventId: "test-event-7",
            journeyId: "journey-5",
            flowId: "flow-5"
          )

          // Send COMPLETION for a different journey (should be ignored)
          let wrongJourneyCompletion = NuxieEvent(
            name: JourneyEvents.flowDismissed,
            distinctId: "test-user",
            properties: [
              "journey_id": "journey-999",
              "flow_id": "flow-5",
            ]
          )
          await broker.observe(event: wrongJourneyCompletion)

          // Should still be pending
          expect(capturedResult).to(beNil())

          // Even after waiting, still pending (no timeout after bind)
          try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
          expect(capturedResult).to(beNil())

          // Now send the correct completion to finish deterministically
          let correctCompletion = NuxieEvent(
            name: JourneyEvents.flowDismissed,
            distinctId: "test-user",
            properties: [
              "journey_id": "journey-5",
              "flow_id": "flow-5",
            ]
          )
          await broker.observe(event: correctCompletion)
          await expect(capturedResult).toEventuallyNot(beNil(), timeout: .milliseconds(100))
        }

        it("handles multiple events independently") {
          var result1: EventResult?
          var result2: EventResult?

          await broker.register(
            eventId: "multi-1",
            timeout: 0.05,
            completion: { result1 = $0 }
          )

          await broker.register(
            eventId: "multi-2",
            timeout: 0.1,
            completion: { result2 = $0 }
          )

          // First should timeout quickly
          await expect(result1)
            .toEventually(equal(.noInteraction), timeout: .milliseconds(100))

          // Second should still be pending
          expect(result2).to(beNil())

          // Second should timeout later
          await expect(result2)
            .toEventually(equal(.noInteraction), timeout: .milliseconds(100))
        }

        it("cleans up after completion") {
          var capturedResult: EventResult?

          await broker.register(
            eventId: "cleanup-test",
            timeout: 1.0,
            completion: { capturedResult = $0 }
          )

          await broker.bind(
            eventId: "cleanup-test",
            journeyId: "journey-cleanup",
            flowId: "flow-cleanup"
          )

          let completionEvent = NuxieEvent(
            name: JourneyEvents.flowDismissed,
            distinctId: "test-user",
            properties: [
              "journey_id": "journey-cleanup",
              "flow_id": "flow-cleanup",
            ]
          )

          await broker.observe(event: completionEvent)

          // First completion should work
          expect(capturedResult).toNot(beNil())

          // Reset for second attempt
          capturedResult = nil

          // Same event again should be ignored (already cleaned up)
          await broker.observe(event: completionEvent)

          expect(capturedResult).to(beNil())
        }

        it("ignores non-flow-ending events and waits until a terminal completion arrives") {
          var capturedResult: EventResult?

          await broker.register(
            eventId: "test-ignore",
            timeout: 0.1,
            completion: { capturedResult = $0 }
          )

          await broker.bind(
            eventId: "test-ignore",
            journeyId: "journey-ignore",
            flowId: "flow-ignore"
          )

          // Send non-terminal event ($flow_shown) — should be ignored
          let otherEvent = NuxieEvent(
            name: JourneyEvents.flowShown,
            distinctId: "test-user",
            properties: [
              "journey_id": "journey-ignore",
              "flow_id": "flow-ignore",
            ]
          )
          await broker.observe(event: otherEvent)

          // Should not resolve from this event
          expect(capturedResult).to(beNil())

          // Still pending after waiting (no timeout after bind)
          try? await Task.sleep(nanoseconds: 200_000_000)
          expect(capturedResult).to(beNil())

          // Now send a terminal completion to finish deterministically
          let completionEvent = NuxieEvent(
            name: JourneyEvents.flowDismissed,
            distinctId: "test-user",
            properties: [
              "journey_id": "journey-ignore",
              "flow_id": "flow-ignore",
            ]
          )
          await broker.observe(event: completionEvent)
          await expect(capturedResult).toEventuallyNot(beNil(), timeout: .milliseconds(100))
        }
      }
    }
  }
}
