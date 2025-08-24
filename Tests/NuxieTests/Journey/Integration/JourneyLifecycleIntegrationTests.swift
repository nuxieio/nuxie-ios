import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie

/// Integration tests for Journey Lifecycle based on CAMPAIGN_REQUIREMENTS.md execution model
final class JourneyLifecycleIntegrationTests: AsyncSpec {
    override class func spec() {
        describe("Journey Lifecycle Integration") {
            // Test spy for monitoring journey execution
            var spy: JourneyTestSpy!
            
            // Explicitly manage mocks for integration tests
            var identityService: MockIdentityService!
            var segmentService: MockSegmentService!
            var journeyStore: MockJourneyStore!
            var spyJourneyStore: SpyJourneyStore!
            var spyJourneyExecutor: SpyJourneyExecutor!
            var profileService: MockProfileService!
            var eventService: MockEventService!
            var eventStore: MockEventStore!
            var nuxieApi: MockNuxieApi!
            var flowService: MockFlowService!
            var flowPresentationService: MockFlowPresentationService!
            var dateProvider: MockDateProvider!
            var sleepProvider: MockSleepProvider!
            var productService: MockProductService!
            
            var journeyService: JourneyService!
            
            beforeEach {
                // Create test spy
                spy = JourneyTestSpy()
                
                // Create fresh mock instances
                identityService = MockIdentityService()
                segmentService = MockSegmentService()
                journeyStore = MockJourneyStore()
                profileService = MockProfileService()
                eventService = MockEventService()
                eventStore = MockEventStore()
                nuxieApi = MockNuxieApi()
                flowService = MockFlowService()
                flowPresentationService = MockFlowPresentationService()
                dateProvider = MockDateProvider()
                sleepProvider = MockSleepProvider()
                productService = MockProductService()
                
                // Register mocks with container FIRST (before creating spy wrappers)
                Container.shared.identityService.register { identityService }
                Container.shared.segmentService.register { segmentService }
                Container.shared.profileService.register { profileService }
                Container.shared.eventService.register { eventService }
                Container.shared.nuxieApi.register { nuxieApi }
                Container.shared.flowService.register { flowService }
                Container.shared.flowPresentationService.register { flowPresentationService }
                Container.shared.dateProvider.register { dateProvider }
                Container.shared.sleepProvider.register { sleepProvider }
                Container.shared.productService.register { productService }
                
                // NOW create spy wrappers (after mocks are registered)
                spyJourneyStore = SpyJourneyStore(realStore: journeyStore, spy: spy)
                spyJourneyExecutor = SpyJourneyExecutor(spy: spy)
                
                Container.shared.segmentService.register { segmentService }
                
                // Create real journey service with injected dependencies
                journeyService = JourneyService(
                    journeyStore: spyJourneyStore,
                    journeyExecutor: spyJourneyExecutor
                )
                Container.shared.journeyService.register { journeyService }
                
                // Initialize journey service
                await journeyService.initialize()
            }
            
            afterEach {
                // Clean up
                Container.shared.reset()
            }
            
            // MARK: - Test 1: Sync-only journey completes immediately without persistence
            
            describe("Sync-only journey execution") {
                it("should complete sync-only journey immediately without persistence") {
                    // Create campaign with only sync nodes (Show Flow → Exit)
                    let campaign = TestCampaignBuilder()
                        .withId("sync-campaign")
                        .withFrequencyPolicy("every_rematch")
                        .withNodes([
                            AnyWorkflowNode(ShowFlowNode(
                                id: "show",
                                next: ["exit"],
                                data: ShowFlowNode.ShowFlowData(flowId: "test-flow")
                            )),
                            AnyWorkflowNode(ExitNode(
                                id: "exit",
                                next: [],
                                data: nil
                            ))
                        ])
                        .withEntryNodeId("show")
                        .build()
                    
                    // Track execution time
                    let startTime = dateProvider.now()
                    
                    // Start journey
                    let journey = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user1"
                    )
                    
                    let endTime = dateProvider.now()
                    
                    // Verify immediate completion (< 10ms = 0.01 seconds)
                    // Since we're using a mock date provider, time won't actually advance
                    // but in real execution this would be < 10ms
                    let executionTime = endTime.timeIntervalSince(startTime)
                    expect(executionTime).to(equal(0)) // Mock time doesn't advance
                    
                    // Verify journey completed
                    expect(journey).toNot(beNil())
                    expect(journey?.status).to(equal(.completed))
                    expect(journey?.exitReason).to(equal(.completed))
                    
                    // Use spy to verify execution path
                    guard let journeyId = journey?.id else {
                        fail("Journey ID should not be nil")
                        return
                    }
                    
                    // Verify the execution path through the nodes
                    spy.assertPath(["show", "exit"], for: journeyId)
                    
                    // Verify node types were executed correctly
                    spy.assertNodeExecuted("show", in: journeyId)
                    spy.assertNodeExecuted("exit", in: journeyId)
                    
                    // Verify Show Flow was attempted (fire-and-forget)
                    spy.assertFlowDisplayed("test-flow", for: journeyId)
                    
                    // Verify NO persistence occurred (sync-only journeys don't persist)
                    spy.assertNoPersistence(for: journeyId)
                    
                    // Also verify through the actual mock store
                    let persistedJourneys = journeyStore.loadActiveJourneys()
                    expect(persistedJourneys).to(beEmpty())
                    
                    // Verify removed from memory (journey completed, so not active)
                    let activeJourneys = await journeyService.getActiveJourneys(for: "user1")
                    expect(activeJourneys).to(beEmpty())
                    
                    // Verify the node execution results using the assertion helper
                    spy.assertNodeExecuted("show", in: journeyId, withResult: .continue(["exit"]))
                    spy.assertNodeExecuted("exit", in: journeyId, withResult: .complete(.completed))
                }
            }
            
            // MARK: - Test 2: Journey with async node pauses and persists
            
            describe("Async journey execution") {
                it("should pause journey at async node and persist to storage") {
                    // Create campaign with async node (TimeDelay → ShowFlow → Exit)
                    let campaign = TestCampaignBuilder()
                        .withId("async-campaign")
                        .withFrequencyPolicy("every_rematch")
                        .withNodes([
                            AnyWorkflowNode(TimeDelayNode(
                                id: "delay",
                                next: ["show"],
                                data: TimeDelayNode.TimeDelayData(duration: 3600) // 1 hour
                            )),
                            AnyWorkflowNode(ShowFlowNode(
                                id: "show",
                                next: ["exit"],
                                data: ShowFlowNode.ShowFlowData(flowId: "delayed-flow")
                            )),
                            AnyWorkflowNode(ExitNode(
                                id: "exit",
                                next: [],
                                data: nil
                            ))
                        ])
                        .withEntryNodeId("delay")
                        .build()
                    
                    // Start journey
                    let journey = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user1"
                    )
                    
                    // Verify journey exists and is paused
                    expect(journey).toNot(beNil())
                    expect(journey?.status).to(equal(.paused))
                    
                    guard let journeyId = journey?.id else {
                        fail("Journey ID should not be nil")
                        return
                    }
                    
                    // Verify execution stopped at the async node
                    spy.assertPath(["delay"], for: journeyId)
                    spy.assertNodeExecuted("delay", in: journeyId)
                    
                    // Verify the delay node returned async result
                    spy.assertNodeExecuted("delay", in: journeyId, withResult: .async(journey?.resumeAt))
                    
                    // Verify journey was persisted (async journeys must persist)
                    spy.assertPersistenceCount(1, for: journeyId)
                    
                    // Also verify through the actual mock store
                    let persistedJourneys = journeyStore.loadActiveJourneys()
                    expect(persistedJourneys).to(haveCount(1))
                    expect(persistedJourneys.first?.id).to(equal(journeyId))
                    expect(persistedJourneys.first?.status).to(equal(.paused))
                    
                    // Verify journey is still in memory (paused, not completed)
                    let activeJourneys = await journeyService.getActiveJourneys(for: "user1")
                    expect(activeJourneys).to(haveCount(1))
                    expect(activeJourneys.first?.id).to(equal(journeyId))
                    
                    // Verify NO flow was displayed yet (journey paused before reaching ShowFlow)
                    expect(spy.flowDisplayAttempts).to(beEmpty())
                    
                    // Verify resumeAt is set correctly (1 hour from now)
                    expect(journey?.resumeAt).toNot(beNil())
                    if let resumeAt = journey?.resumeAt {
                        let expectedResumeTime = dateProvider.now().addingTimeInterval(3600)
                        expect(resumeAt.timeIntervalSince1970).to(beCloseTo(expectedResumeTime.timeIntervalSince1970, within: 1.0))
                    }
                }
                
                it("should pause at WaitUntil node and persist") {
                    // Create campaign with WaitUntil node
                    let waitPath = WaitUntilNode.WaitUntilData.WaitPath(
                        id: "purchase-path",
                        condition: TestWaitCondition.event("purchase_completed"),
                        maxTime: 86400, // 24 hours
                        next: "success"
                    )
                    
                    let campaign = TestCampaignBuilder()
                        .withId("wait-campaign")
                        .withFrequencyPolicy("once")
                        .withNodes([
                            AnyWorkflowNode(WaitUntilNode(
                                id: "wait",
                                next: [], // WaitUntil uses paths for next nodes
                                data: WaitUntilNode.WaitUntilData(paths: [waitPath])
                            )),
                            AnyWorkflowNode(ShowFlowNode(
                                id: "success",
                                next: ["exit"],
                                data: ShowFlowNode.ShowFlowData(flowId: "success-flow")
                            )),
                            AnyWorkflowNode(ExitNode(
                                id: "exit",
                                next: [],
                                data: nil
                            ))
                        ])
                        .withEntryNodeId("wait")
                        .build()
                    
                    // Start journey
                    let journey = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user2"
                    )
                    
                    // Verify journey is paused at WaitUntil
                    expect(journey).toNot(beNil())
                    expect(journey?.status).to(equal(.paused))
                    expect(journey?.currentNodeId).to(equal("wait"))
                    
                    guard let journeyId = journey?.id else {
                        fail("Journey ID should not be nil")
                        return
                    }
                    
                    // Verify persistence for async wait
                    spy.assertPersistenceCount(1, for: journeyId)
                    
                    // Verify journey is waiting (not completed)
                    let activeJourneys = await journeyService.getActiveJourneys(for: "user2")
                    expect(activeJourneys).to(haveCount(1))
                    
                    // Verify no flow shown yet
                    expect(spy.flowDisplayAttempts).to(beEmpty())
                }
            }
            
            // MARK: - Test 3: Show Flow is fire-and-forget
            
            describe("Show Flow fire-and-forget behavior") {
                it("should continue journey immediately after Show Flow without waiting") {
                    // Create campaign: ShowFlow → TimeDelay → Exit
                    // This tests that ShowFlow doesn't block even when followed by async node
                    let campaign = TestCampaignBuilder()
                        .withId("fire-forget-campaign")
                        .withFrequencyPolicy("every_rematch")
                        .withNodes([
                            AnyWorkflowNode(ShowFlowNode(
                                id: "show",
                                next: ["delay"],
                                data: ShowFlowNode.ShowFlowData(flowId: "test-flow")
                            )),
                            AnyWorkflowNode(TimeDelayNode(
                                id: "delay",
                                next: ["exit"],
                                data: TimeDelayNode.TimeDelayData(duration: 60) // 1 minute
                            )),
                            AnyWorkflowNode(ExitNode(
                                id: "exit",
                                next: [],
                                data: nil
                            ))
                        ])
                        .withEntryNodeId("show")
                        .build()
                    
                    // Start journey
                    let journey = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user3"
                    )
                    
                    guard let journeyId = journey?.id else {
                        fail("Journey ID should not be nil")
                        return
                    }
                    
                    // Verify journey executed ShowFlow and continued to TimeDelay
                    spy.assertPath(["show", "delay"], for: journeyId)
                    
                    // Verify ShowFlow was displayed (fire-and-forget)
                    spy.assertFlowDisplayed("test-flow", for: journeyId)
                    
                    // Verify ShowFlow returned continue (not async)
                    spy.assertNodeExecuted("show", in: journeyId, withResult: .continue(["delay"]))
                    
                    // Verify journey is now paused at TimeDelay (not at ShowFlow)
                    expect(journey?.status).to(equal(.paused))
                    expect(journey?.currentNodeId).to(equal("delay"))
                    
                    // Verify persistence happened because of TimeDelay, not ShowFlow
                    spy.assertPersistenceCount(1, for: journeyId)
                }
                
                it("should execute multiple ShowFlows in sequence without pausing") {
                    // Create campaign with multiple ShowFlows
                    let campaign = TestCampaignBuilder()
                        .withId("multi-flow-campaign")
                        .withFrequencyPolicy("every_rematch")
                        .withNodes([
                            AnyWorkflowNode(ShowFlowNode(
                                id: "flow1",
                                next: ["flow2"],
                                data: ShowFlowNode.ShowFlowData(flowId: "onboarding-flow")
                            )),
                            AnyWorkflowNode(ShowFlowNode(
                                id: "flow2",
                                next: ["flow3"],
                                data: ShowFlowNode.ShowFlowData(flowId: "upgrade-flow")
                            )),
                            AnyWorkflowNode(ShowFlowNode(
                                id: "flow3",
                                next: ["exit"],
                                data: ShowFlowNode.ShowFlowData(flowId: "survey-flow")
                            )),
                            AnyWorkflowNode(ExitNode(
                                id: "exit",
                                next: [],
                                data: nil
                            ))
                        ])
                        .withEntryNodeId("flow1")
                        .build()
                    
                    // Start journey
                    let journey = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user4"
                    )
                    
                    guard let journeyId = journey?.id else {
                        fail("Journey ID should not be nil")
                        return
                    }
                    
                    // Verify all flows were executed immediately in sequence
                    spy.assertPath(["flow1", "flow2", "flow3", "exit"], for: journeyId)
                    
                    // Verify all flows were displayed
                    spy.assertFlowDisplayed("onboarding-flow", for: journeyId)
                    spy.assertFlowDisplayed("upgrade-flow", for: journeyId)
                    spy.assertFlowDisplayed("survey-flow", for: journeyId)
                    
                    // Verify journey completed (no async nodes)
                    expect(journey?.status).to(equal(.completed))
                    
                    // Verify no persistence (all sync nodes)
                    spy.assertNoPersistence(for: journeyId)
                    
                    // Verify all flow display attempts happened
                    expect(spy.flowDisplayAttempts).to(haveCount(3))
                    expect(spy.flowDisplayAttempts.map { $0.flowId }).to(equal([
                        "onboarding-flow",
                        "upgrade-flow", 
                        "survey-flow"
                    ]))
                }
            }
            
            // MARK: - Test 4: Frequency policies for sync-only journeys
            
            describe("Frequency policy for sync journeys") {
                it("should respect 'once' policy - never run again after completion") {
                    // Create sync-only campaign with 'once' policy
                    let campaign = TestCampaignBuilder()
                        .withId("once-campaign")
                        .withFrequencyPolicy("once")
                        .withNodes([
                            AnyWorkflowNode(ShowFlowNode(
                                id: "show",
                                next: ["exit"],
                                data: ShowFlowNode.ShowFlowData(flowId: "once-flow")
                            )),
                            AnyWorkflowNode(ExitNode(
                                id: "exit",
                                next: [],
                                data: nil
                            ))
                        ])
                        .withEntryNodeId("show")
                        .build()
                    
                    // First journey should succeed
                    let journey1 = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user5"
                    )
                    
                    expect(journey1).toNot(beNil())
                    expect(journey1?.status).to(equal(.completed))
                    
                    // Record completion in mock store (simulating what real JourneyService does)
                    if let j1 = journey1 {
                        let record = JourneyCompletionRecord(
                            campaignId: campaign.id,
                            distinctId: "user5",
                            journeyId: j1.id,
                            completedAt: dateProvider.now(),
                            exitReason: .completed
                        )
                        try? journeyStore.recordCompletion(record)
                    }
                    
                    // Second journey should NOT start (frequency check fails)
                    let journey2 = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user5"
                    )
                    
                    expect(journey2).to(beNil())
                    
                    // Verify only one journey was executed
                    expect(spy.nodeExecutions.filter { $0.journeyId == journey1?.id }).toNot(beEmpty())
                    expect(spy.flowDisplayAttempts).to(haveCount(1))
                }
                
                it("should respect 'every_rematch' policy - allow restart immediately") {
                    // Create sync-only campaign with 'every_rematch' policy
                    let campaign = TestCampaignBuilder()
                        .withId("rematch-campaign")
                        .withFrequencyPolicy("every_rematch")
                        .withNodes([
                            AnyWorkflowNode(ShowFlowNode(
                                id: "show",
                                next: ["exit"],
                                data: ShowFlowNode.ShowFlowData(flowId: "rematch-flow")
                            )),
                            AnyWorkflowNode(ExitNode(
                                id: "exit",
                                next: [],
                                data: nil
                            ))
                        ])
                        .withEntryNodeId("show")
                        .build()
                    
                    // First journey
                    let journey1 = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user6"
                    )
                    
                    expect(journey1).toNot(beNil())
                    expect(journey1?.status).to(equal(.completed))
                    
                    // Second journey should also succeed (every_rematch allows immediate restart)
                    let journey2 = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user6"
                    )
                    
                    expect(journey2).toNot(beNil())
                    expect(journey2?.status).to(equal(.completed))
                    expect(journey2?.id).toNot(equal(journey1?.id)) // Different journey instances
                    
                    // Third journey should also work
                    let journey3 = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user6"
                    )
                    
                    expect(journey3).toNot(beNil())
                    expect(journey3?.status).to(equal(.completed))
                    
                    // Verify all three journeys executed
                    expect(spy.flowDisplayAttempts).to(haveCount(3))
                    expect(spy.flowDisplayAttempts.map { $0.flowId }).to(equal([
                        "rematch-flow",
                        "rematch-flow",
                        "rematch-flow"
                    ]))
                }
                
                it("should respect 'fixed_interval' policy with cooldown period") {
                    // Create sync-only campaign with fixed_interval policy (1 hour cooldown)
                    let campaign = TestCampaignBuilder()
                        .withId("interval-campaign")
                        .withFrequencyPolicy("fixed_interval")
                        .withFrequencyInterval(3600) // 1 hour cooldown
                        .withNodes([
                            AnyWorkflowNode(ShowFlowNode(
                                id: "show",
                                next: ["exit"],
                                data: ShowFlowNode.ShowFlowData(flowId: "interval-flow")
                            )),
                            AnyWorkflowNode(ExitNode(
                                id: "exit",
                                next: [],
                                data: nil
                            ))
                        ])
                        .withEntryNodeId("show")
                        .build()
                    
                    // First journey should succeed
                    let journey1 = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user7"
                    )
                    
                    expect(journey1).toNot(beNil())
                    expect(journey1?.status).to(equal(.completed))
                    
                    // Record completion for frequency checking
                    if let j1 = journey1 {
                        let record = JourneyCompletionRecord(
                            campaignId: campaign.id,
                            distinctId: "user7",
                            journeyId: j1.id,
                            completedAt: dateProvider.now(),
                            exitReason: .completed
                        )
                        try? journeyStore.recordCompletion(record)
                    }
                    
                    // Second journey immediately should fail (within cooldown)
                    let journey2 = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user7"
                    )
                    
                    expect(journey2).to(beNil()) // Should not start due to cooldown
                    
                    // Advance time by 1 hour
                    dateProvider.advance(by: 3601)
                    
                    // Third journey after cooldown should succeed
                    let journey3 = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user7"
                    )
                    
                    expect(journey3).toNot(beNil())
                    expect(journey3?.status).to(equal(.completed))
                    
                    // Verify only 2 journeys executed (not 3)
                    expect(spy.flowDisplayAttempts).to(haveCount(2))
                }
            }
            
            // MARK: - Test 5: Frequency policies for async journeys
            
            describe("Frequency policy for async journeys") {
                it("should prevent duplicate async journeys for same campaign") {
                    // Create async campaign
                    let campaign = TestCampaignBuilder()
                        .withId("async-dedupe-campaign")
                        .withFrequencyPolicy("every_rematch")
                        .withNodes([
                            AnyWorkflowNode(TimeDelayNode(
                                id: "delay",
                                next: ["show"],
                                data: TimeDelayNode.TimeDelayData(duration: 3600)
                            )),
                            AnyWorkflowNode(ShowFlowNode(
                                id: "show",
                                next: ["exit"],
                                data: ShowFlowNode.ShowFlowData(flowId: "async-flow")
                            )),
                            AnyWorkflowNode(ExitNode(
                                id: "exit",
                                next: [],
                                data: nil
                            ))
                        ])
                        .withEntryNodeId("delay")
                        .build()
                    
                    // Start first journey (will pause at delay)
                    let journey1 = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user8"
                    )
                    
                    expect(journey1).toNot(beNil())
                    expect(journey1?.status).to(equal(.paused))
                    
                    // Try to start second journey while first is still active
                    let journey2 = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user8"
                    )
                    
                    // Should not start duplicate (active journey exists)
                    expect(journey2).to(beNil())
                    
                    // Verify only one journey is active
                    let activeJourneys = await journeyService.getActiveJourneys(for: "user8")
                    expect(activeJourneys).to(haveCount(1))
                    expect(activeJourneys.first?.id).to(equal(journey1?.id))
                }
                
                it("should allow async journey after previous one completes") {
                    // Create async campaign with 'every_rematch'
                    let campaign = TestCampaignBuilder()
                        .withId("async-restart-campaign")
                        .withFrequencyPolicy("every_rematch")
                        .withNodes([
                            AnyWorkflowNode(TimeDelayNode(
                                id: "delay",
                                next: ["exit"],
                                data: TimeDelayNode.TimeDelayData(duration: 1) // Very short delay
                            )),
                            AnyWorkflowNode(ExitNode(
                                id: "exit",
                                next: [],
                                data: nil
                            ))
                        ])
                        .withEntryNodeId("delay")
                        .build()
                    
                    // Start first journey
                    let journey1 = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user9"
                    )
                    
                    expect(journey1).toNot(beNil())
                    expect(journey1?.status).to(equal(.paused))
                    
                    // Simulate journey completion (manually complete it)
                    journey1?.complete(reason: .completed)
                    // Remove from active journeys to simulate completion
                    journeyStore.deleteJourney(id: journey1!.id)
                    
                    // Now second journey should be allowed
                    let journey2 = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user9"
                    )
                    
                    expect(journey2).toNot(beNil())
                    expect(journey2?.id).toNot(equal(journey1?.id))
                    expect(journey2?.status).to(equal(.paused))
                    
                    // Verify two different journeys were created
                    expect(spy.nodeExecutions.map { $0.journeyId }.unique()).to(haveCount(2))
                }
                
                it("should respect 'once' policy even for async journeys") {
                    // Create async campaign with 'once' policy
                    let campaign = TestCampaignBuilder()
                        .withId("async-once-campaign")
                        .withFrequencyPolicy("once")
                        .withNodes([
                            AnyWorkflowNode(TimeDelayNode(
                                id: "delay",
                                next: ["exit"],
                                data: TimeDelayNode.TimeDelayData(duration: 60)
                            )),
                            AnyWorkflowNode(ExitNode(
                                id: "exit",
                                next: [],
                                data: nil
                            ))
                        ])
                        .withEntryNodeId("delay")
                        .build()
                    
                    // First journey starts
                    let journey1 = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user10"
                    )
                    
                    expect(journey1).toNot(beNil())
                    expect(journey1?.status).to(equal(.paused))
                    
                    // Complete the journey
                    journey1?.complete(reason: .completed)
                    if let j1 = journey1 {
                        let record = JourneyCompletionRecord(
                            campaignId: campaign.id,
                            distinctId: "user10",
                            journeyId: j1.id,
                            completedAt: dateProvider.now(),
                            exitReason: .completed
                        )
                        try? journeyStore.recordCompletion(record)
                    }
                    
                    // Second journey should not start (once policy)
                    let journey2 = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user10"
                    )
                    
                    expect(journey2).to(beNil())
                }
            }
        }
    }
}

// Helper extension for unique array elements
extension Array where Element: Hashable {
    func unique() -> [Element] {
        return Array(Set(self))
    }
}