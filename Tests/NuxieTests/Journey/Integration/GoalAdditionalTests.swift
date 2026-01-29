import FactoryKit
import Foundation
import Nimble
import Quick

@testable import Nuxie

final class GoalAdditionalTests: AsyncSpec {
  override class func spec() {
    describe("Additional Journey Goal Scenarios") {
      // Test spy for monitoring journey execution (only needed if you want to assert paths/flows)
      var spy: JourneyTestSpy!

      // Core services
      var journeyService: JourneyService!

      // Mock services
      var mockIdentityService: MockIdentityService!
      var mockSegmentService: MockSegmentService!
      var mockJourneyStore: MockJourneyStore!
      var spyJourneyStore: SpyJourneyStore!
      var spyJourneyExecutor: SpyJourneyExecutor!
      var mockProfileService: MockProfileService!
      var mockEventService: MockEventService!
      var mockEventStore: MockEventStore!
      var mockNuxieApi: MockNuxieApi!
      var mockFlowService: MockFlowService!
      var mockFlowPresentationService: MockFlowPresentationService!
      var mockDateProvider: MockDateProvider!
      var mockSleepProvider: MockSleepProvider!
      var mockProductService: MockProductService!

      beforeEach {

        // Register test configuration (required for any services that depend on sdkConfiguration)
        let testConfig = NuxieConfiguration(apiKey: "test-api-key")
        Container.shared.sdkConfiguration.register { testConfig }

        // Fresh mocks
        mockIdentityService = MockIdentityService()
        mockSegmentService = MockSegmentService()
        mockJourneyStore = MockJourneyStore()
        mockProfileService = MockProfileService()
        mockEventService = MockEventService()
        mockEventStore = MockEventStore()
        mockNuxieApi = MockNuxieApi()
        mockFlowService = MockFlowService()
        mockFlowPresentationService = MockFlowPresentationService()
        mockDateProvider = MockDateProvider()
        mockSleepProvider = MockSleepProvider()
        mockProductService = MockProductService()
        spy = JourneyTestSpy()

        // Register mocks FIRST
        Container.shared.identityService.register { mockIdentityService }
        Container.shared.segmentService.register { mockSegmentService }
        Container.shared.profileService.register { mockProfileService }
        Container.shared.eventService.register { mockEventService }
        Container.shared.nuxieApi.register { mockNuxieApi }
        Container.shared.flowService.register { mockFlowService }
        Container.shared.flowPresentationService.register { mockFlowPresentationService }
        Container.shared.dateProvider.register { mockDateProvider }
        Container.shared.sleepProvider.register { mockSleepProvider }
        Container.shared.productService.register { mockProductService }

        // Wrap spies
        spyJourneyStore = SpyJourneyStore(realStore: mockJourneyStore, spy: spy)
        spyJourneyExecutor = SpyJourneyExecutor(spy: spy)

        // Create JourneyService with injected dependencies
        mockIdentityService.setDistinctId("test-user")
        journeyService = JourneyService(
          journeyStore: spyJourneyStore,
          journeyExecutor: spyJourneyExecutor
        )
        Container.shared.journeyService.register { journeyService }

        await journeyService.initialize()
      }

      afterEach {
        await journeyService.shutdown()
        mockSleepProvider.reset()
      }

      // -------------------------------------------------------------
      // 1) Event inside window, later event outside window → goal stays latched
      // -------------------------------------------------------------
      describe("Event goal latching robustness") {
        var campaign: Campaign!

        beforeEach {
          // Campaign: never exit early; wait-until has only a long timeout path
          // so the journey remains paused and reactive resumes won't auto-complete.
          let longTimeout: TimeInterval = 365 * 24 * 60 * 60  // 1 year
          campaign = TestCampaignBuilder(id: "latch-robustness-campaign")
            .withName("Latch Robustness")
            .withFrequencyPolicy("every_rematch")
            .withEventTrigger(eventName: "start")
            .withEntryNodeId("show")
            .withNodes([
              AnyWorkflowNode(
                ShowFlowNode(
                  id: "show",
                  next: ["wait"],
                  data: ShowFlowNode.ShowFlowData(flowId: "dummy-flow")
                )
              ),
              AnyWorkflowNode(
                WaitUntilNode(
                  id: "wait",
                  next: [],
                  data: WaitUntilNode.WaitUntilData(
                    paths: [
                      // Timeout-only path; condition false; very long maxTime.
                      WaitUntilNode.WaitUntilData.WaitPath(
                        id: "timeout",
                        condition: IREnvelope(
                          ir_version: 1,
                          engine_min: nil,
                          compiled_at: nil,
                          expr: IRExpr.bool(false)
                        ),
                        maxTime: longTimeout,
                        next: "exit"
                      )
                    ]
                  )
                )
              ),
              AnyWorkflowNode(
                ExitNode(
                  id: "exit",
                  next: [],
                  data: nil
                )
              ),
            ])
            // 21-day conversion window for purchase
            .withEventGoal(eventName: "purchase", window: 21 * 24 * 60 * 60)
            .withExitPolicy(.never)  // <-- do not exit early on goal
            .withCampaignType("paywall")  // irrelevant, but keeps parity with defaults
            .build()

          mockProfileService.setCampaigns([campaign])
        }

        it("keeps conversion latched even if later 'last event' is outside the window") {
          // Start journey directly
          let journey = await journeyService.startJourney(for: campaign, distinctId: "test-user")
          await expect(journey).toNot(beNil())
          await expect(journey?.status).to(equal(.paused))

          // Advance a bit and fire first purchase INSIDE the window
          mockDateProvider.advance(by: 60)  // +60s
          let t1 = mockDateProvider.now()  // event-time within window
          mockEventService.setLastEventTime(
            name: "purchase",
            distinctId: "test-user",
            time: t1
          )
          let firstPurchase = TestEventBuilder(name: "purchase")
            .withDistinctId("test-user")
            .build()
          await journeyService.handleEvent(firstPurchase)

          // Journey should still be active (exit policy .never), but conversion must be latched
          var active = await journeyService.getActiveJourneys(for: "test-user")
          await expect(active).to(haveCount(1))
          await expect(active.first?.convertedAt).toNot(beNil())
          // Be tolerant with timing comparisons
          await expect(active.first?.convertedAt).to(beCloseTo(t1, within: 0.01))

          // Advance beyond window and fire another purchase OUTSIDE the window
          mockDateProvider.advance(by: 22 * 24 * 60 * 60)  // +22 days (outside 21-day window)
          let t2 = mockDateProvider.now()
          mockEventService.setLastEventTime(
            name: "purchase",
            distinctId: "test-user",
            time: t2
          )
          let latePurchase = TestEventBuilder(name: "purchase")
            .withDistinctId("test-user")
            .build()
          await journeyService.handleEvent(latePurchase)

          // Journey remains active (because .never), and convertedAt must remain the EARLY time (t1)
          active = await journeyService.getActiveJourneys(for: "test-user")
          await expect(active).to(haveCount(1))
          await expect(active.first?.convertedAt).to(beCloseTo(t1, within: 0.01))

          // Sanity: convertedAt must definitely be earlier than t2
          await expect(active.first?.convertedAt?.timeIntervalSince(t2)).to(beLessThan(0))
        }
      }

      // -------------------------------------------------------------
      // 4) Conversion anchor update (enable when anchor is updated to last_flow_shown)
      // -------------------------------------------------------------
      describe("Conversion anchor update (last_flow_shown)") {
        xit("re-anchors window to last_flow_shown and only converts within the new window") {
          // TODO: enable after wiring conversionAnchor updates inside FlowPresentationService presentation callbacks
          // Sketch:
          // 1) Start campaign with conversionAnchor = .last_flow_shown
          // 2) Show flow -> anchorAt := now
          // 3) Fire event outside OLD anchor but inside NEW anchor; assert conversion occurs
        }
      }
    }
  }
}
