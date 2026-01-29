import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie

/// Comprehensive tests for journey frequency policy (reentry policy) enforcement.
///
/// These tests verify that:
/// 1. Users cannot start another journey while they are already in a campaign
/// 2. Users can only start a journey once they've exited AND one of the reentry policies allows them
///
/// Policy mapping:
/// - `once` (one_time): User can only enter the campaign once in their lifetime
/// - `every_rematch` (every_time): User can re-enter after exiting (no concurrent journeys)
/// - `fixed_interval` (once_per_window): User can re-enter after a time window
final class FrequencyPolicyTests: AsyncSpec {
    override class func spec() {
        describe("Frequency Policy Enforcement") {
            // Test dependencies
            var journeyService: JourneyService!
            var journeyStore: MockJourneyStore!
            var journeyExecutor: MockJourneyExecutor!
            var identityService: MockIdentityService!
            var segmentService: MockSegmentService!
            var profileService: MockProfileService!
            var eventService: MockEventService!
            var dateProvider: MockDateProvider!
            var sleepProvider: MockSleepProvider!
            var flowService: MockFlowService!
            var flowPresentationService: MockFlowPresentationService!
            var productService: MockProductService!
            var nuxieApi: MockNuxieApi!

            beforeEach {
                // Register test configuration
                let testConfig = NuxieConfiguration(apiKey: "test-api-key")
                Container.shared.sdkConfiguration.register { testConfig }

                // Create fresh mock instances
                journeyStore = MockJourneyStore()
                journeyExecutor = MockJourneyExecutor()
                identityService = MockIdentityService()
                segmentService = MockSegmentService()
                profileService = MockProfileService()
                eventService = MockEventService()
                dateProvider = MockDateProvider()
                sleepProvider = MockSleepProvider()
                flowService = MockFlowService()
                flowPresentationService = MockFlowPresentationService()
                productService = MockProductService()
                nuxieApi = MockNuxieApi()

                // Register mocks with container
                Container.shared.identityService.register { identityService }
                Container.shared.segmentService.register { segmentService }
                Container.shared.profileService.register { profileService }
                Container.shared.eventService.register { eventService }
                Container.shared.dateProvider.register { dateProvider }
                Container.shared.sleepProvider.register { sleepProvider }
                Container.shared.flowService.register { flowService }
                Container.shared.flowPresentationService.register { flowPresentationService }
                Container.shared.productService.register { productService }
                Container.shared.nuxieApi.register { nuxieApi }

                // Create journey service with mocks
                journeyService = JourneyService(
                    journeyStore: journeyStore,
                    journeyExecutor: journeyExecutor
                )
                Container.shared.journeyService.register { journeyService }

                // Initialize
                await journeyService.initialize()
            }

            afterEach {
                await journeyService.shutdown()
                journeyStore.reset()
                journeyExecutor.reset()
                sleepProvider.reset()
            }

            // MARK: - .once (one_time) Policy Tests

            describe(".once policy (one_time)") {
                var onceCampaign: Campaign!

                beforeEach {
                    // Create a campaign with .once frequency policy
                    // Using async node (TimeDelay) to test active journey blocking
                    onceCampaign = TestCampaignBuilder(id: "once-campaign")
                        .withName("Once Campaign")
                        .withFrequencyPolicy("once")
                        .withNodes([
                            AnyWorkflowNode(TimeDelayNode(
                                id: "delay",
                                next: ["exit"],
                                data: TimeDelayNode.TimeDelayData(duration: 3600) // 1 hour
                            )),
                            AnyWorkflowNode(ExitNode(
                                id: "exit",
                                next: [],
                                data: nil
                            ))
                        ])
                        .withEntryNodeId("delay")
                        .build()

                    // Configure mock executor to return .async for delay nodes (simulating TimeDelay behavior)
                    let resumeAt = dateProvider.now().addingTimeInterval(3600)
                    journeyExecutor.setExecuteResult(nodeId: "delay", result: .async(resumeAt))
                }

                it("should allow first journey for a user") {
                    let journey = await journeyService.startJourney(
                        for: onceCampaign,
                        distinctId: "user1"
                    )

                    expect(journey).toNot(beNil())
                    expect(journey?.campaignId).to(equal("once-campaign"))
                    expect(journey?.distinctId).to(equal("user1"))
                }

                it("should block second journey while first is still active (THE BUG FIX)") {
                    // Start first journey - it will pause at TimeDelay
                    let journey1 = await journeyService.startJourney(
                        for: onceCampaign,
                        distinctId: "user1"
                    )

                    expect(journey1).toNot(beNil())
                    expect(journey1?.status).to(equal(.paused))

                    // Attempt to start second journey while first is still active
                    // This is the bug we fixed - previously this would be allowed
                    let journey2 = await journeyService.startJourney(
                        for: onceCampaign,
                        distinctId: "user1"
                    )

                    // Should be blocked because there's already an active journey
                    expect(journey2).to(beNil())

                    // Verify only one journey exists
                    let activeJourneys = await journeyService.getActiveJourneys(for: "user1")
                    expect(activeJourneys).to(haveCount(1))
                    expect(activeJourneys.first?.id).to(equal(journey1?.id))
                }

                it("should block journey after previous one completed") {
                    // Start and complete first journey
                    let journey1 = await journeyService.startJourney(
                        for: onceCampaign,
                        distinctId: "user1"
                    )
                    expect(journey1).toNot(beNil())

                    // Simulate completion by recording in store
                    if let j1 = journey1 {
                        j1.complete(reason: .completed)
                        let record = JourneyCompletionRecord(
                            campaignId: onceCampaign.id,
                            distinctId: "user1",
                            journeyId: j1.id,
                            completedAt: dateProvider.now(),
                            exitReason: .completed
                        )
                        try? journeyStore.recordCompletion(record)
                        journeyStore.deleteJourney(id: j1.id)
                    }

                    // Attempt second journey - should be blocked by completion history
                    let journey2 = await journeyService.startJourney(
                        for: onceCampaign,
                        distinctId: "user1"
                    )

                    expect(journey2).to(beNil())
                }

                it("should allow different users to start journeys independently") {
                    let journey1 = await journeyService.startJourney(
                        for: onceCampaign,
                        distinctId: "user1"
                    )

                    let journey2 = await journeyService.startJourney(
                        for: onceCampaign,
                        distinctId: "user2"
                    )

                    expect(journey1).toNot(beNil())
                    expect(journey2).toNot(beNil())
                    expect(journey1?.id).toNot(equal(journey2?.id))
                }
            }

            // MARK: - .everyRematch (every_time) Policy Tests

            describe(".everyRematch policy (every_time)") {
                var everyTimeCampaign: Campaign!

                beforeEach {
                    everyTimeCampaign = TestCampaignBuilder(id: "every-time-campaign")
                        .withName("Every Time Campaign")
                        .withFrequencyPolicy("every_rematch")
                        .withNodes([
                            AnyWorkflowNode(TimeDelayNode(
                                id: "delay",
                                next: ["exit"],
                                data: TimeDelayNode.TimeDelayData(duration: 3600)
                            )),
                            AnyWorkflowNode(ExitNode(
                                id: "exit",
                                next: [],
                                data: nil
                            ))
                        ])
                        .withEntryNodeId("delay")
                        .build()

                    // Configure mock executor to return .async for delay nodes
                    let resumeAt = dateProvider.now().addingTimeInterval(3600)
                    journeyExecutor.setExecuteResult(nodeId: "delay", result: .async(resumeAt))
                }

                it("should allow first journey") {
                    let journey = await journeyService.startJourney(
                        for: everyTimeCampaign,
                        distinctId: "user1"
                    )

                    expect(journey).toNot(beNil())
                }

                it("should block second journey while first is still active") {
                    let journey1 = await journeyService.startJourney(
                        for: everyTimeCampaign,
                        distinctId: "user1"
                    )
                    expect(journey1).toNot(beNil())
                    expect(journey1?.status).to(equal(.paused))

                    // Try to start second while first is active
                    let journey2 = await journeyService.startJourney(
                        for: everyTimeCampaign,
                        distinctId: "user1"
                    )

                    expect(journey2).to(beNil())
                }

                it("should allow new journey after previous one completed") {
                    // Start first journey
                    let journey1 = await journeyService.startJourney(
                        for: everyTimeCampaign,
                        distinctId: "user1"
                    )
                    expect(journey1).toNot(beNil())

                    // Complete it
                    if let j1 = journey1 {
                        j1.complete(reason: .completed)
                        journeyStore.deleteJourney(id: j1.id)
                    }

                    // Start second journey - should be allowed
                    let journey2 = await journeyService.startJourney(
                        for: everyTimeCampaign,
                        distinctId: "user1"
                    )

                    expect(journey2).toNot(beNil())
                    expect(journey2?.id).toNot(equal(journey1?.id))
                }

                it("should allow multiple sequential journeys after each completion") {
                    // First journey
                    let journey1 = await journeyService.startJourney(
                        for: everyTimeCampaign,
                        distinctId: "user1"
                    )
                    expect(journey1).toNot(beNil())
                    journey1?.complete(reason: .completed)
                    journeyStore.deleteJourney(id: journey1!.id)

                    // Second journey
                    let journey2 = await journeyService.startJourney(
                        for: everyTimeCampaign,
                        distinctId: "user1"
                    )
                    expect(journey2).toNot(beNil())
                    journey2?.complete(reason: .completed)
                    journeyStore.deleteJourney(id: journey2!.id)

                    // Third journey
                    let journey3 = await journeyService.startJourney(
                        for: everyTimeCampaign,
                        distinctId: "user1"
                    )
                    expect(journey3).toNot(beNil())

                    // All different journeys
                    let ids = [journey1?.id, journey2?.id, journey3?.id].compactMap { $0 }
                    expect(Set(ids).count).to(equal(3))
                }
            }

            // MARK: - .fixedInterval (once_per_window) Policy Tests

            describe(".fixedInterval policy (once_per_window)") {
                var intervalCampaign: Campaign!
                let intervalSeconds: TimeInterval = 3600 // 1 hour

                beforeEach {
                    intervalCampaign = TestCampaignBuilder(id: "interval-campaign")
                        .withName("Interval Campaign")
                        .withFrequencyPolicy("fixed_interval")
                        .withFrequencyInterval(intervalSeconds)
                        .withNodes([
                            AnyWorkflowNode(TimeDelayNode(
                                id: "delay",
                                next: ["exit"],
                                data: TimeDelayNode.TimeDelayData(duration: 60) // Short delay
                            )),
                            AnyWorkflowNode(ExitNode(
                                id: "exit",
                                next: [],
                                data: nil
                            ))
                        ])
                        .withEntryNodeId("delay")
                        .build()

                    // Configure mock executor to return .async for delay nodes
                    let resumeAt = dateProvider.now().addingTimeInterval(60)
                    journeyExecutor.setExecuteResult(nodeId: "delay", result: .async(resumeAt))
                }

                it("should allow first journey") {
                    let journey = await journeyService.startJourney(
                        for: intervalCampaign,
                        distinctId: "user1"
                    )

                    expect(journey).toNot(beNil())
                }

                it("should block second journey while first is active and within interval") {
                    let journey1 = await journeyService.startJourney(
                        for: intervalCampaign,
                        distinctId: "user1"
                    )
                    expect(journey1).toNot(beNil())

                    // Advance time but stay within interval
                    dateProvider.advance(by: intervalSeconds / 2)

                    let journey2 = await journeyService.startJourney(
                        for: intervalCampaign,
                        distinctId: "user1"
                    )

                    expect(journey2).to(beNil())
                }

                it("should cancel old journey and allow new one when interval expires while active") {
                    let journey1 = await journeyService.startJourney(
                        for: intervalCampaign,
                        distinctId: "user1"
                    )
                    expect(journey1).toNot(beNil())
                    expect(journey1?.status).to(equal(.paused))

                    // Advance time past the interval
                    dateProvider.advance(by: intervalSeconds + 1)

                    // Should be allowed and old journey should be cancelled
                    let journey2 = await journeyService.startJourney(
                        for: intervalCampaign,
                        distinctId: "user1"
                    )

                    expect(journey2).toNot(beNil())
                    expect(journey2?.id).toNot(equal(journey1?.id))
                }

                it("should block journey within interval after completion") {
                    // Start and complete first journey
                    let journey1 = await journeyService.startJourney(
                        for: intervalCampaign,
                        distinctId: "user1"
                    )
                    expect(journey1).toNot(beNil())

                    // Complete it
                    if let j1 = journey1 {
                        j1.complete(reason: .completed)
                        let record = JourneyCompletionRecord(
                            campaignId: intervalCampaign.id,
                            distinctId: "user1",
                            journeyId: j1.id,
                            completedAt: dateProvider.now(),
                            exitReason: .completed
                        )
                        try? journeyStore.recordCompletion(record)
                        journeyStore.deleteJourney(id: j1.id)
                    }

                    // Try immediately - should be blocked
                    let journey2 = await journeyService.startJourney(
                        for: intervalCampaign,
                        distinctId: "user1"
                    )

                    expect(journey2).to(beNil())
                }

                it("should allow journey after interval expires post-completion") {
                    // Start and complete first journey
                    let journey1 = await journeyService.startJourney(
                        for: intervalCampaign,
                        distinctId: "user1"
                    )
                    expect(journey1).toNot(beNil())

                    // Complete it
                    if let j1 = journey1 {
                        j1.complete(reason: .completed)
                        let record = JourneyCompletionRecord(
                            campaignId: intervalCampaign.id,
                            distinctId: "user1",
                            journeyId: j1.id,
                            completedAt: dateProvider.now(),
                            exitReason: .completed
                        )
                        try? journeyStore.recordCompletion(record)
                        journeyStore.deleteJourney(id: j1.id)
                    }

                    // Advance time past interval
                    dateProvider.advance(by: intervalSeconds + 1)

                    // Should be allowed now
                    let journey2 = await journeyService.startJourney(
                        for: intervalCampaign,
                        distinctId: "user1"
                    )

                    expect(journey2).toNot(beNil())
                }
            }

            // MARK: - Cross-Device Sync Tests

            describe("Cross-device journey sync") {
                var campaign: Campaign!

                beforeEach {
                    campaign = TestCampaignBuilder(id: "cross-device-campaign")
                        .withName("Cross Device Campaign")
                        .withFrequencyPolicy("once")
                        .withNodes([
                            AnyWorkflowNode(TimeDelayNode(
                                id: "delay",
                                next: ["exit"],
                                data: TimeDelayNode.TimeDelayData(duration: 3600)
                            )),
                            AnyWorkflowNode(ExitNode(
                                id: "exit",
                                next: [],
                                data: nil
                            ))
                        ])
                        .withEntryNodeId("delay")
                        .build()

                    // Configure mock executor to return .async for delay nodes
                    let resumeAt = dateProvider.now().addingTimeInterval(3600)
                    journeyExecutor.setExecuteResult(nodeId: "delay", result: .async(resumeAt))
                }

                it("should block local journey start when server reports active journey") {
                    // Get the distinct ID that will be used
                    let distinctId = identityService.getDistinctId()

                    // Simulate server returning an active journey via profile response
                    let serverJourney = ActiveJourney(
                        sessionId: "server-session-123",
                        campaignId: campaign.id,
                        currentNodeId: "delay",
                        context: [:]
                    )

                    // Resume from server state - this populates inMemoryJourneysById
                    await journeyService.resumeFromServerState([serverJourney], campaigns: [campaign])

                    // Now try to start a local journey - should be blocked because server journey exists
                    let localJourney = await journeyService.startJourney(
                        for: campaign,
                        distinctId: distinctId
                    )

                    // Should be blocked because server journey is now in memory
                    expect(localJourney).to(beNil())
                }

                it("should allow local journey if no server journey exists") {
                    // Resume from server with empty journeys
                    await journeyService.resumeFromServerState([], campaigns: [campaign])

                    // Start local journey
                    let localJourney = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user1"
                    )

                    expect(localJourney).toNot(beNil())
                }

                it("should not duplicate journey if server journey already exists locally") {
                    // Start local journey first
                    let localJourney = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user1"
                    )
                    expect(localJourney).toNot(beNil())
                    expect(localJourney?.status).to(equal(.paused))

                    // Now simulate server returning the same journey (already synced)
                    let serverJourney = ActiveJourney(
                        sessionId: localJourney!.id, // Same ID
                        campaignId: campaign.id,
                        currentNodeId: "delay",
                        context: [:]
                    )

                    await journeyService.resumeFromServerState([serverJourney], campaigns: [campaign])

                    // Should still have only one journey
                    let activeJourneys = await journeyService.getActiveJourneys(for: "user1")
                    expect(activeJourneys).to(haveCount(1))
                }
            }

            // MARK: - Edge Cases

            describe("Edge cases") {
                it("should use everyRematch as default for unknown policy") {
                    // Configure mock executor to return .async for delay nodes
                    let resumeAt = dateProvider.now().addingTimeInterval(3600)
                    journeyExecutor.setExecuteResult(nodeId: "delay", result: .async(resumeAt))

                    let unknownPolicyCampaign = TestCampaignBuilder(id: "unknown-policy")
                        .withFrequencyPolicy("some_invalid_policy")
                        .withNodes([
                            AnyWorkflowNode(TimeDelayNode(
                                id: "delay",
                                next: ["exit"],
                                data: TimeDelayNode.TimeDelayData(duration: 3600)
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
                        for: unknownPolicyCampaign,
                        distinctId: "user1"
                    )
                    expect(journey1).toNot(beNil())
                    expect(journey1?.status).to(equal(.paused))

                    // Second should be blocked (everyRematch behavior)
                    let journey2 = await journeyService.startJourney(
                        for: unknownPolicyCampaign,
                        distinctId: "user1"
                    )
                    expect(journey2).to(beNil())

                    // After completion, should be allowed
                    journey1?.complete(reason: .completed)
                    journeyStore.deleteJourney(id: journey1!.id)

                    let journey3 = await journeyService.startJourney(
                        for: unknownPolicyCampaign,
                        distinctId: "user1"
                    )
                    expect(journey3).toNot(beNil())
                }

                it("should handle paused journeys as live for blocking") {
                    // Configure mock executor to return .async for delay nodes
                    let resumeAt = dateProvider.now().addingTimeInterval(3600)
                    journeyExecutor.setExecuteResult(nodeId: "delay", result: .async(resumeAt))

                    let campaign = TestCampaignBuilder(id: "paused-test")
                        .withFrequencyPolicy("once")
                        .withNodes([
                            AnyWorkflowNode(TimeDelayNode(
                                id: "delay",
                                next: ["exit"],
                                data: TimeDelayNode.TimeDelayData(duration: 3600)
                            )),
                            AnyWorkflowNode(ExitNode(
                                id: "exit",
                                next: [],
                                data: nil
                            ))
                        ])
                        .withEntryNodeId("delay")
                        .build()

                    // Start journey - it will pause at delay
                    let journey1 = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user1"
                    )
                    expect(journey1).toNot(beNil())
                    expect(journey1?.status).to(equal(.paused))

                    // Paused journey should still block new starts
                    let journey2 = await journeyService.startJourney(
                        for: campaign,
                        distinctId: "user1"
                    )
                    expect(journey2).to(beNil())
                }

                it("should handle active journeys as live for blocking") {
                    // Create sync-only campaign that completes immediately
                    let syncCampaign = TestCampaignBuilder(id: "sync-campaign")
                        .withFrequencyPolicy("once")
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

                    // Start journey - will complete immediately
                    let journey1 = await journeyService.startJourney(
                        for: syncCampaign,
                        distinctId: "user1"
                    )
                    expect(journey1).toNot(beNil())
                    expect(journey1?.status).to(equal(.completed))

                    // Record completion
                    if let j1 = journey1 {
                        let record = JourneyCompletionRecord(
                            campaignId: syncCampaign.id,
                            distinctId: "user1",
                            journeyId: j1.id,
                            completedAt: dateProvider.now(),
                            exitReason: .completed
                        )
                        try? journeyStore.recordCompletion(record)
                    }

                    // After completion, .once policy should still block
                    let journey2 = await journeyService.startJourney(
                        for: syncCampaign,
                        distinctId: "user1"
                    )
                    expect(journey2).to(beNil())
                }

                it("should not block journeys for different campaigns") {
                    // Configure mock executor to return .async for delay nodes
                    let resumeAt = dateProvider.now().addingTimeInterval(3600)
                    journeyExecutor.setExecuteResult(nodeId: "delay", result: .async(resumeAt))

                    let campaign1 = TestCampaignBuilder(id: "campaign-1")
                        .withFrequencyPolicy("once")
                        .withNodes([
                            AnyWorkflowNode(TimeDelayNode(
                                id: "delay",
                                next: ["exit"],
                                data: TimeDelayNode.TimeDelayData(duration: 3600)
                            )),
                            AnyWorkflowNode(ExitNode(
                                id: "exit",
                                next: [],
                                data: nil
                            ))
                        ])
                        .withEntryNodeId("delay")
                        .build()

                    let campaign2 = TestCampaignBuilder(id: "campaign-2")
                        .withFrequencyPolicy("once")
                        .withNodes([
                            AnyWorkflowNode(TimeDelayNode(
                                id: "delay",
                                next: ["exit"],
                                data: TimeDelayNode.TimeDelayData(duration: 3600)
                            )),
                            AnyWorkflowNode(ExitNode(
                                id: "exit",
                                next: [],
                                data: nil
                            ))
                        ])
                        .withEntryNodeId("delay")
                        .build()

                    // Start journey for campaign 1
                    let journey1 = await journeyService.startJourney(
                        for: campaign1,
                        distinctId: "user1"
                    )
                    expect(journey1).toNot(beNil())
                    expect(journey1?.status).to(equal(.paused))

                    // Should be able to start journey for campaign 2
                    let journey2 = await journeyService.startJourney(
                        for: campaign2,
                        distinctId: "user1"
                    )
                    expect(journey2).toNot(beNil())
                    expect(journey2?.campaignId).to(equal("campaign-2"))
                    expect(journey2?.status).to(equal(.paused))
                }
            }
        }
    }
}
