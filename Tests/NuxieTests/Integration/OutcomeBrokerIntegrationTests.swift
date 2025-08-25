import FactoryKit
import Foundation
import Nimble
import Quick

@testable import Nuxie

final class OutcomeBrokerIntegrationTests: AsyncSpec {
  override class func spec() {
    describe("Outcome Broker Integration") {
      // Services and mocks
      var identityService: MockIdentityService!
      var segmentService: MockSegmentService!
      var journeyStore: MockJourneyStore!
      var profileService: MockProfileService!
      var eventStore: MockEventStore!
      var nuxieApi: MockNuxieApi!
      var flowService: MockFlowService!
      var flowPresentationService: MockFlowPresentationService!
      var dateProvider: MockDateProvider!
      var sleepProvider: MockSleepProvider!

      var eventService: EventService!
      var journeyService: JourneyService!
      var journeyExecutor: JourneyExecutor!
      var outcomeBroker: OutcomeBroker!

      beforeEach {
        // Reset container for clean state
        Container.shared.reset()

        // Create all required mocks
        identityService = MockIdentityService()
        segmentService = MockSegmentService()
        journeyStore = MockJourneyStore()
        profileService = MockProfileService()
        eventStore = MockEventStore()
        nuxieApi = MockNuxieApi()
        flowService = MockFlowService()
        flowPresentationService = MockFlowPresentationService()
        dateProvider = MockDateProvider()
        sleepProvider = MockSleepProvider()

        // Create and register OutcomeBroker FIRST (before services with @Injected properties)
        outcomeBroker = OutcomeBroker()
        Container.shared.outcomeBroker.register { outcomeBroker }

        // Register all mocks with container
        Container.shared.identityService.register { identityService }
        Container.shared.segmentService.register { segmentService }
        // journeyStore is no longer registered in container - injected directly
        Container.shared.profileService.register { profileService }
        Container.shared.nuxieApi.register { nuxieApi }
        Container.shared.flowService.register { flowService }
        Container.shared.flowPresentationService.register { flowPresentationService }
        Container.shared.dateProvider.register { dateProvider }
        Container.shared.sleepProvider.register { sleepProvider }

        // Create real services (after OutcomeBroker is registered)
        eventService = EventService()
        Container.shared.eventService.register { eventService }

        journeyExecutor = JourneyExecutor()
        // journeyExecutor is no longer registered in container - injected directly

        journeyService = JourneyService(
          journeyStore: journeyStore,
          journeyExecutor: journeyExecutor
        )
        Container.shared.journeyService.register { journeyService }

        // Configure event service
        let config = NuxieConfiguration(apiKey: "test")
        config.immediateOutcomeWindowSeconds = 0.1  // 100ms for faster tests

        try await eventService.configure(
          networkQueue: nil,
          journeyService: journeyService,
          contextBuilder: nil,
          configuration: config
        )

        // Initialize journey service
        await journeyService.initialize()
      }

      afterEach {
        Container.shared.reset()
      }

      describe("immediate flow completion") {
        it("returns .flow(.purchased) when purchase completes immediately") {
          // Create campaign that shows flow immediately
          let showFlowNode = ShowFlowNode(
            id: "show-1",
            next: [],
            data: ShowFlowNode.ShowFlowData(flowId: "premium-flow")
          )

          let campaign = TestCampaignBuilder()
            .withId("campaign-1")
            .withName("Test Campaign")
            .withEventTrigger(eventName: "purchase_trigger")
            .withNodes([AnyWorkflowNode(showFlowNode)])
            .withEntryNodeId("show-1")
            .withFrequencyPolicy("everyRematch")
            .build()

          profileService.setCampaigns([campaign])

          // Track event with completion handler
          var capturedResult: EventResult?

          eventService.track(
            "purchase_trigger",
            properties: [:],
            completion: { result in
              capturedResult = result
            }
          )

          // Allow journey to start and bind
          await expect(flowPresentationService.presentFlowCallCount)
            .toEventually(beGreaterThan(0), timeout: .milliseconds(100))

          // Use the journey captured by the presentation service (doesn't depend on journey still being active)
          await expect(flowPresentationService.lastPresentedJourney)
            .toEventuallyNot(beNil(), timeout: .milliseconds(100))
          let journey = flowPresentationService.lastPresentedJourney!

          // Simulate flow completion with purchase
          let flowCompleted = NuxieEvent(
            name: JourneyEvents.flowCompleted,
            distinctId: identityService.getDistinctId(),
            properties: [
              "journey_id": journey.id,
              "flow_id": "premium-flow",
              "completion_type": "purchase",
              "product_id": "premium.monthly",
              "transaction_id": "txn_123",
            ]
          )

          eventService.track(
            flowCompleted.name,
            properties: flowCompleted.properties,
            userProperties: nil,
            userPropertiesSetOnce: nil,
            completion: nil
          )
          await eventService.drain()

          // Verify result
          await expect(capturedResult).toEventuallyNot(beNil(), timeout: .milliseconds(100))

          if case .flow(let completion) = capturedResult {
            expect(completion.flowId).to(equal("premium-flow"))
            if case .purchased(let productId, let transactionId) = completion.outcome {
              expect(productId).to(equal("premium.monthly"))
              expect(transactionId).to(equal("txn_123"))
            } else {
              fail("Expected purchased outcome")
            }
          } else {
            fail("Expected flow result, got \(String(describing: capturedResult))")
          }
        }

        it("returns .flow(.dismissed) when user dismisses flow") {
          // Create campaign that shows flow
          let showFlowNode = ShowFlowNode(
            id: "show-2",
            next: [],
            data: ShowFlowNode.ShowFlowData(flowId: "dismissable-flow")
          )

          let campaign = TestCampaignBuilder()
            .withId("campaign-2")
            .withName("Dismissable Campaign")
            .withEventTrigger(eventName: "show_flow_event")
            .withNodes([AnyWorkflowNode(showFlowNode)])
            .withEntryNodeId("show-2")
            .withFrequencyPolicy("everyRematch")
            .build()

          profileService.setCampaigns([campaign])

          var capturedResult: EventResult?

          eventService.track(
            "show_flow_event",
            properties: [:],
            completion: { capturedResult = $0 }
          )

          // Wait for flow to be presented
          await expect(flowPresentationService.presentFlowCallCount)
            .toEventually(beGreaterThan(0), timeout: .milliseconds(100))

          // Use the journey captured by the presentation service (doesn't depend on journey still being active)
          await expect(flowPresentationService.lastPresentedJourney)
            .toEventuallyNot(beNil(), timeout: .milliseconds(100))
          let journey = flowPresentationService.lastPresentedJourney!

          // Simulate dismissal
          let flowCompleted = NuxieEvent(
            name: JourneyEvents.flowCompleted,
            distinctId: identityService.getDistinctId(),
            properties: [
              "journey_id": journey.id,
              "flow_id": "dismissable-flow",
              "completion_type": "dismissed",
            ]
          )

          eventService.track(
            flowCompleted.name,
            properties: flowCompleted.properties,
            userProperties: nil,
            userPropertiesSetOnce: nil,
            completion: nil
          )
          await eventService.drain()

          await expect(capturedResult).toEventuallyNot(beNil())

          if case .flow(let completion) = capturedResult {
            expect(completion.outcome).to(equal(.dismissed))
          } else {
            fail("Expected flow result")
          }
        }
      }

      describe("timeout behavior") {
        it("returns .noInteraction when no flow shows within window") {
          // No campaigns configured
          profileService.setCampaigns([])

          var capturedResult: EventResult?

          eventService.track(
            "non_triggering_event",
            properties: [:],
            completion: { capturedResult = $0 }
          )

          // Should timeout after 100ms
          await expect(capturedResult)
            .toEventually(equal(.noInteraction), timeout: .milliseconds(200))

          // Verify no flow was presented
          expect(flowPresentationService.presentFlowCallCount).to(equal(0))
        }

        it("returns .noInteraction when campaign doesn't match trigger") {
          let campaign = TestCampaignBuilder()
            .withId("campaign-3")
            .withName("Different Trigger")
            .withEventTrigger(eventName: "different_event")
            .withFrequencyPolicy("everyRematch")
            .build()

          profileService.setCampaigns([campaign])

          var capturedResult: EventResult?

          eventService.track(
            "wrong_event",
            properties: [:],
            completion: { capturedResult = $0 }
          )

          await expect(capturedResult)
            .toEventually(equal(.noInteraction), timeout: .milliseconds(200))
        }
      }

      describe("wait-until journeys") {
        it("does not fire callback when journey resumes later") {
          // Create campaign with wait-until then show-flow
          // Use a condition that will never be true to simulate indefinite wait
          let falseCondition = TestWaitCondition.expression("false")

          let waitNode = WaitUntilNode(
            id: "wait-1",
            next: [],
            data: WaitUntilNode.WaitUntilData(paths: [
              WaitUntilNode.WaitUntilData.WaitPath(
                id: "path-1",
                condition: falseCondition,  // Will never be true
                maxTime: nil,
                next: "show-3"
              )
            ])
          )

          let showNode = ShowFlowNode(
            id: "show-3",
            next: [],
            data: ShowFlowNode.ShowFlowData(flowId: "delayed-flow")
          )

          let campaign = TestCampaignBuilder()
            .withId("campaign-wait")
            .withName("Wait Campaign")
            .withEventTrigger(eventName: "wait_trigger")
            .withNodes([
              AnyWorkflowNode(waitNode),
              AnyWorkflowNode(showNode),
            ])
            .withEntryNodeId("wait-1")
            .withFrequencyPolicy("everyRematch")
            .build()

          profileService.setCampaigns([campaign])

          var callbackCount = 0
          var lastResult: EventResult?

          eventService.track(
            "wait_trigger",
            properties: [:],
            completion: { result in
              callbackCount += 1
              lastResult = result
            }
          )

          // Should get .noInteraction after timeout
          await expect(callbackCount)
            .toEventually(equal(1), timeout: .milliseconds(200))

          expect(lastResult).to(equal(.noInteraction))

          // Even if we wait longer, callback should NOT fire again
          try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
          expect(callbackCount).to(equal(1))  // Still just 1
        }
      }

      describe("error handling") {
        it("maps flow error to .flow(.error)") {
          let showNode = ShowFlowNode(
            id: "show-error",
            next: [],
            data: ShowFlowNode.ShowFlowData(flowId: "error-flow")
          )

          let campaign = TestCampaignBuilder()
            .withId("campaign-error")
            .withName("Error Campaign")
            .withEventTrigger(eventName: "error_trigger")
            .withNodes([AnyWorkflowNode(showNode)])
            .withEntryNodeId("show-error")
            .withFrequencyPolicy("everyRematch")
            .build()

          profileService.setCampaigns([campaign])

          var capturedResult: EventResult?

          eventService.track(
            "error_trigger",
            properties: [:],
            completion: { capturedResult = $0 }
          )

          // Allow journey to start and bind
          await expect(flowPresentationService.presentFlowCallCount)
            .toEventually(beGreaterThan(0), timeout: .milliseconds(100))

          // Use the journey captured by the presentation service (doesn't depend on journey still being active)
          await expect(flowPresentationService.lastPresentedJourney)
            .toEventuallyNot(beNil(), timeout: .milliseconds(100))
          let journey = flowPresentationService.lastPresentedJourney!

          // Simulate error completion
          let flowCompleted = NuxieEvent(
            name: JourneyEvents.flowCompleted,
            distinctId: identityService.getDistinctId(),
            properties: [
              "journey_id": journey.id,
              "flow_id": "error-flow",
              "completion_type": "error",
              "error_message": "Network connection failed",
            ]
          )

          eventService.track(
            flowCompleted.name,
            properties: flowCompleted.properties,
            userProperties: nil,
            userPropertiesSetOnce: nil,
            completion: nil
          )
          await eventService.drain()

          await expect(capturedResult).toEventuallyNot(beNil())

          if case .flow(let completion) = capturedResult {
            if case .error(let message) = completion.outcome {
              expect(message).to(equal("Network connection failed"))
            } else {
              fail("Expected error outcome")
            }
          } else {
            fail("Expected flow result")
          }
        }
      }
    }
  }
}
