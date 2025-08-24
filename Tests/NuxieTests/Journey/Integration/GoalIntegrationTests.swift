import FactoryKit
import Foundation
import Nimble
import Quick

@testable import Nuxie

final class GoalIntegrationTests: AsyncSpec {
  override class func spec() {
    describe("Journey Goals Integration") {
      // Test spy for monitoring journey execution
      var spy: JourneyTestSpy!

      // Core services
      var journeyService: JourneyService!
      var goalEvaluator: GoalEvaluator!

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
        // 1) Fresh mocks
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

        // 2) Register mocks FIRST
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

        // 3) Wrap spies
        spyJourneyStore = SpyJourneyStore(realStore: mockJourneyStore, spy: spy)
        spyJourneyExecutor = SpyJourneyExecutor(spy: spy)

        // 4) Create JourneyService with injected dependencies
        mockIdentityService.setDistinctId("test-user")
        journeyService = JourneyService(
          journeyStore: spyJourneyStore,
          journeyExecutor: spyJourneyExecutor
        )
        Container.shared.journeyService.register { journeyService }

        await journeyService.initialize()
      }

      afterEach {
        // Clean up
        Container.shared.reset()
      }

      describe("Paywall Journey with Purchase Goal") {
        var paywallCampaign: Campaign!

        beforeEach {
          // Create paywall campaign with purchase goal using builder
          // Uses WaitUntil node to keep journey active until purchase or timeout
          paywallCampaign = TestCampaignBuilder(id: "paywall-campaign")
            .withName("Premium Paywall")
            .withFrequencyPolicy("every_rematch")
            .withSegmentTrigger(segmentId: "free-users")
            .withEntryNodeId("show-paywall")
            .withNodes([
              AnyWorkflowNode(
                ShowFlowNode(
                  id: "show-paywall",
                  next: ["wait-for-purchase"],
                  data: ShowFlowNode.ShowFlowData(flowId: "premium-paywall")
                )),
              AnyWorkflowNode(
                WaitUntilNode(
                  id: "wait-for-purchase",
                  next: [],
                  data: WaitUntilNode.WaitUntilData(
                    paths: [
                      WaitUntilNode.WaitUntilData.WaitPath(
                        id: "purchased",
                        condition: IREnvelope(
                          ir_version: 1,
                          engine_min: nil,
                          compiled_at: nil,
                          expr: IRExpr.compare(
                            op: "gt",
                            left: IRExpr.eventsCount(
                              name: "purchase",
                              since: IRExpr.timeAgo(duration: IRExpr.number(3600)),
                              until: nil,
                              within: nil,
                              where_: nil
                            ),
                            right: IRExpr.number(0)
                          )
                        ),
                        maxTime: 3600,
                        next: "exit"
                      )
                    ]
                  )
                )),
              AnyWorkflowNode(
                ExitNode(
                  id: "exit",
                  next: [],
                  data: nil
                )),
            ])
            .withEventGoal(eventName: "purchase", window: 21 * 24 * 60 * 60)
            .withExitPolicy(.onGoal)
            .withCampaignType("paywall")
            .build()

          // Set up profile service to return this campaign
          mockProfileService.setCampaigns([paywallCampaign])
        }

        it("should exit with goalMet when purchase occurs") {
          // User enters free segment
          await mockSegmentService.setMembership("free-users", isMember: true)

          // Start journey via segment trigger
          let journey = await journeyService.startJourney(
            for: paywallCampaign,
            distinctId: "test-user"
          )

          // Journey should be paused at WaitUntil node
          await expect(journey).toNot(beNil())
          await expect(journey?.status).to(equal(.paused))

          guard let journeyId = journey?.id else {
            fail("Journey ID should not be nil")
            return
          }

          // Verify initial execution path
          spy.assertPath(["show-paywall", "wait-for-purchase"], for: journeyId)
          spy.assertFlowDisplayed("premium-paywall", for: journeyId)

          // Now simulate purchase event
          let purchaseEvent = TestEventBuilder(name: "purchase")
            .withDistinctId("test-user")
            .withProperties(["product_id": "premium_monthly"])
            .build()

          // Set up event service to return purchase
          mockEventService.setLastEventTime(
            name: "purchase",
            distinctId: "test-user",
            time: mockDateProvider.now()
          )

          // Handle the event - this should trigger goal evaluation
          await journeyService.handleEvent(purchaseEvent)

          // Journey should now be completed with goalMet
          let activeJourneys = await journeyService.getActiveJourneys(for: "test-user")
          await expect(activeJourneys).to(beEmpty())

          // Check that journey exited with goalMet
          let completions = mockJourneyStore.getCompletions(for: "test-user")
          await expect(completions).to(haveCount(1))
          await expect(completions.first?.exitReason).to(equal(.goalMet))

          // Should not have executed the exit node since we exited early
          await expect(spy.wasNodeExecuted("exit", in: journeyId)).to(beFalse())
        }

        it("should not exit if purchase is outside window") {
          LogDebug("\n=== TEST START: should not exit if purchase is outside window ===")
          LogDebug("Starting fresh test with new mocks")
          
          // Start journey
          let journey = await journeyService.startJourney(
            for: paywallCampaign,
            distinctId: "test-user"
          )

          await expect(journey).toNot(beNil())

          // Advance time beyond 21-day window
          mockDateProvider.advance(by: 22 * 24 * 60 * 60)

          // Simulate purchase event
          let purchaseEvent = TestEventBuilder(name: "purchase")
            .withDistinctId("test-user")
            .withProperties(["product_id": "premium_monthly"])
            .build()

          mockEventService.setLastEventTime(
            name: "purchase",
            distinctId: "test-user",
            time: mockDateProvider.now()
          )

          await journeyService.handleEvent(purchaseEvent)

          // Journey should still be active
          let activeJourneys = await journeyService.getActiveJourneys(for: "test-user")
          await expect(activeJourneys).to(haveCount(1))
        }
      }

      describe("Onboarding Journey with Attribute Goal") {
        var onboardingCampaign: Campaign!

        beforeEach {
          // Create onboarding campaign with attribute goal using builder
          onboardingCampaign = TestCampaignBuilder(id: "onboarding-campaign")
            .withName("User Onboarding")
            .withFrequencyPolicy("once")
            .withEventTrigger(eventName: "$app_installed")
            .withEntryNodeId("welcome")
            .withNodes([
              AnyWorkflowNode(
                ShowFlowNode(
                  id: "welcome",
                  next: ["wait-for-completion"],
                  data: ShowFlowNode.ShowFlowData(flowId: "welcome-flow")
                )),
              AnyWorkflowNode(
                WaitUntilNode(
                  id: "wait-for-completion",
                  next: [],
                  data: WaitUntilNode.WaitUntilData(
                    paths: [
                      WaitUntilNode.WaitUntilData.WaitPath(
                        id: "onboarding-done",
                        condition: IREnvelope(
                          ir_version: 1,
                          engine_min: nil,
                          compiled_at: nil,
                          expr: IRExpr.user(
                            op: "eq", key: "onboarding_completed", value: IRExpr.bool(true))
                        ),
                        maxTime: 3600,
                        next: "exit"
                      )
                    ]
                  )
                )),
              AnyWorkflowNode(
                ExitNode(
                  id: "exit",
                  next: [],
                  data: nil
                )),
            ])
            .withAttributeGoal(
              expr: IREnvelope(
                ir_version: 1,
                engine_min: nil,
                compiled_at: nil,
                expr: IRExpr.user(op: "eq", key: "onboarding_completed", value: IRExpr.bool(true))
              ),
              window: 10 * 24 * 60 * 60  // 10 days
            )
            .withExitPolicy(.onGoal)
            .withCampaignType("onboarding")
            .build()

          mockProfileService.setCampaigns([onboardingCampaign])
        }

        it("should exit when onboarding is completed") {
          LogDebug("\n=== TEST START: should exit when onboarding is completed ===")
          LogDebug("Starting fresh test with new mocks")
          
          // Start journey
          let journey = await journeyService.startJourney(
            for: onboardingCampaign,
            distinctId: "test-user"
          )

          await expect(journey).toNot(beNil())

          // Set onboarding completed attribute
          mockIdentityService.setUserProperty("onboarding_completed", value: true)

          // Trigger any event to check goals
          let event = TestEventBuilder(name: "screen_viewed")
            .withDistinctId("test-user")
            .build()
          await journeyService.handleEvent(event)

          // Journey should be completed
          let activeJourneys = await journeyService.getActiveJourneys(for: "test-user")
          await expect(activeJourneys).to(beEmpty())

          let completions = mockJourneyStore.getCompletions(for: "test-user")
          await expect(completions.first?.exitReason).to(equal(.goalMet))
        }
      }

      describe("Segment-Triggered Journey with Stop-Matching") {
        var segmentCampaign: Campaign!

        beforeEach {
          // Create campaign with stop-matching exit policy using builder
          segmentCampaign = TestCampaignBuilder(id: "segment-campaign")
            .withName("VIP Features")
            .withFrequencyPolicy("every_rematch")
            .withSegmentTrigger(segmentId: "vip-users")
            .withEntryNodeId("vip-flow")
            .withNodes([
              AnyWorkflowNode(
                ShowFlowNode(
                  id: "vip-flow",
                  next: ["wait-for-event"],
                  data: ShowFlowNode.ShowFlowData(flowId: "vip-features")
                )),
              AnyWorkflowNode(
                WaitUntilNode(
                  id: "wait-for-event",
                  next: [],
                  data: WaitUntilNode.WaitUntilData(
                    paths: [
                      WaitUntilNode.WaitUntilData.WaitPath(
                        id: "timeout",
                        condition: IREnvelope(
                          ir_version: 1,
                          engine_min: nil,
                          compiled_at: nil,
                          expr: IRExpr.bool(false)  // Never true, just wait
                        ),
                        maxTime: 86400,  // 24 hour timeout
                        next: "exit"
                      )
                    ]
                  )
                )),
              AnyWorkflowNode(
                ExitNode(
                  id: "exit",
                  next: [],
                  data: nil
                )),
            ])
            .withExitPolicy(.onStopMatching)
            .build()

          mockProfileService.setCampaigns([segmentCampaign])
        }

        it("should exit when user leaves segment") {
          // User enters VIP segment
          await mockSegmentService.setMembership("vip-users", isMember: true)

          // Start journey
          let journey = await journeyService.startJourney(
            for: segmentCampaign,
            distinctId: "test-user"
          )

          await expect(journey).toNot(beNil())

          // User leaves VIP segment
          await mockSegmentService.setMembership("vip-users", isMember: false)

          // Handle segment change
          await journeyService.handleSegmentChange(
            distinctId: "test-user",
            segments: Set<String>()
          )

          // Journey should be completed with triggerUnmatched
          let activeJourneys = await journeyService.getActiveJourneys(for: "test-user")
          await expect(activeJourneys).to(beEmpty())

          let completions = mockJourneyStore.getCompletions(for: "test-user")
          await expect(completions.first?.exitReason).to(equal(.triggerUnmatched))
        }
      }

      describe("Journey with Goal OR Stop-Matching Policy") {
        var hybridCampaign: Campaign!

        beforeEach {
          // Create campaign with hybrid exit policy using builder
          hybridCampaign = TestCampaignBuilder(id: "hybrid-campaign")
            .withName("Trial Conversion")
            .withFrequencyPolicy("once")
            .withSegmentTrigger(segmentId: "trial-users")
            .withEntryNodeId("trial-flow")
            .withNodes([
              AnyWorkflowNode(
                ShowFlowNode(
                  id: "trial-flow",
                  next: ["wait-for-conversion"],
                  data: ShowFlowNode.ShowFlowData(flowId: "trial-upgrade")
                )),
              AnyWorkflowNode(
                WaitUntilNode(
                  id: "wait-for-conversion",
                  next: [],
                  data: WaitUntilNode.WaitUntilData(
                    paths: [
                      WaitUntilNode.WaitUntilData.WaitPath(
                        id: "converted",
                        condition: IREnvelope(
                          ir_version: 1,
                          engine_min: nil,
                          compiled_at: nil,
                          expr: IRExpr.compare(
                            op: "gt",
                            left: IRExpr.eventsCount(
                              name: "subscription_started",
                              since: IRExpr.timeAgo(duration: IRExpr.number(604800)),
                              until: nil,
                              within: nil,
                              where_: nil
                            ),
                            right: IRExpr.number(0)
                          )
                        ),
                        maxTime: 604800,  // 7 days
                        next: "exit"
                      )
                    ]
                  )
                )),
              AnyWorkflowNode(
                ExitNode(
                  id: "exit",
                  next: [],
                  data: nil
                )),
            ])
            .withEventGoal(eventName: "subscription_started", window: 7 * 24 * 60 * 60)
            .withExitPolicy(.onGoalOrStop)
            .build()

          mockProfileService.setCampaigns([hybridCampaign])
        }

        it("should exit on goal achievement") {
          await mockSegmentService.setMembership("trial-users", isMember: true)

          let journey = await journeyService.startJourney(
            for: hybridCampaign,
            distinctId: "test-user"
          )

          // Check journey status after start
          await expect(journey).toNot(beNil())

          // Achieve goal
          mockEventService.setLastEventTime(
            name: "subscription_started",
            distinctId: "test-user",
            time: mockDateProvider.now()
          )

          let event = TestEventBuilder(name: "subscription_started")
            .withDistinctId("test-user")
            .build()
          await journeyService.handleEvent(event)

          let activeJourneys = await journeyService.getActiveJourneys(for: "test-user")
          await expect(activeJourneys).to(beEmpty())

          let completions = mockJourneyStore.getCompletions(for: "test-user")
          LogDebug("Test: Completion reason: \(String(describing: completions.first?.exitReason))")
          LogDebug("Test: Journey had goal: \(hybridCampaign.goal != nil)")
          await expect(completions.first?.exitReason).to(equal(.goalMet))
        }

        it("should exit on stop-matching") {
          LogDebug("\n=== TEST START: should exit on stop-matching ===")
          LogDebug("Starting fresh test with new mocks")
          
          await mockSegmentService.setMembership("trial-users", isMember: true)

          let journey = await journeyService.startJourney(
            for: hybridCampaign,
            distinctId: "test-user"
          )

          // Leave segment (trial ended)
          await mockSegmentService.setMembership("trial-users", isMember: false)

          await journeyService.handleSegmentChange(
            distinctId: "test-user",
            segments: Set<String>()
          )

          let activeJourneys = await journeyService.getActiveJourneys(for: "test-user")
          await expect(activeJourneys).to(beEmpty())

          let completions = mockJourneyStore.getCompletions(for: "test-user")
          await expect(completions.first?.exitReason).to(equal(.triggerUnmatched))
        }
      }

      describe("Journey with Never Exit Policy") {
        var neverExitCampaign: Campaign!

        beforeEach {
          // Create campaign that never exits early using builder
          neverExitCampaign = TestCampaignBuilder(id: "never-exit-campaign")
            .withName("Complete Tutorial")
            .withFrequencyPolicy("once")
            .withEventTrigger(eventName: "tutorial_started")
            .withEntryNodeId("step1")
            .withNodes([
              AnyWorkflowNode(
                ShowFlowNode(
                  id: "step1",
                  next: ["wait-for-completion"],
                  data: ShowFlowNode.ShowFlowData(flowId: "tutorial-step-1")
                )),
              AnyWorkflowNode(
                WaitUntilNode(
                  id: "wait-for-completion",
                  next: [],
                  data: WaitUntilNode.WaitUntilData(
                    paths: [
                      WaitUntilNode.WaitUntilData.WaitPath(
                        id: "completed",
                        condition: IREnvelope(
                          ir_version: 1,
                          engine_min: nil,
                          compiled_at: nil,
                          expr: IRExpr.compare(
                            op: "gt",
                            left: IRExpr.eventsCount(
                              name: "tutorial_completed",
                              since: IRExpr.timeAgo(duration: IRExpr.number(3600)),
                              until: nil,
                              within: nil,
                              where_: nil
                            ),
                            right: IRExpr.number(0)
                          )
                        ),
                        maxTime: 3600,
                        next: "exit"
                      )
                    ]
                  )
                )),
              AnyWorkflowNode(
                ExitNode(
                  id: "exit",
                  next: [],
                  data: nil
                )),
            ])
            .withEventGoal(eventName: "tutorial_completed")
            .withExitPolicy(.never)
            .build()

          mockProfileService.setCampaigns([neverExitCampaign])
        }

        it("should track conversion but not exit early") {
          let journey = await journeyService.startJourney(
            for: neverExitCampaign,
            distinctId: "test-user"
          )

          await expect(journey).toNot(beNil())

          // Complete tutorial (achieve goal)
          mockEventService.setLastEventTime(
            name: "tutorial_completed",
            distinctId: "test-user",
            time: mockDateProvider.now()
          )

          let event = TestEventBuilder(name: "tutorial_completed")
            .withDistinctId("test-user")
            .build()
          await journeyService.handleEvent(event)

          // Journey should still be active
          let activeJourneys = await journeyService.getActiveJourneys(for: "test-user")
          await expect(activeJourneys).to(haveCount(1))

          // But conversion should be tracked
          await expect(activeJourneys.first?.convertedAt).toNot(beNil())
        }
      }
    }
  }
}
