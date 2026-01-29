import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie

final class CrossDeviceResumeIntegrationTests: AsyncSpec {
    override class func spec() {
        describe("Cross-Device Journey Resume") {
            var profileService: ProfileService!
            var mockJourneyService: MockJourneyService!
            var mockApi: MockNuxieApi!
            var mockFlowService: MockFlowService!
            var mockSegmentService: JourneyExecutorTestSegmentService!
            var mockIdentityService: JourneyExecutorTestIdentityService!
            var campaign: Campaign!

            beforeEach {

                // Register test configuration (required for any services that depend on sdkConfiguration)
                let testConfig = NuxieConfiguration(apiKey: "test-api-key")
                Container.shared.sdkConfiguration.register { testConfig }

                // Create mock services
                mockJourneyService = MockJourneyService()
                mockApi = MockNuxieApi()
                mockFlowService = MockFlowService()
                mockSegmentService = JourneyExecutorTestSegmentService()
                mockIdentityService = JourneyExecutorTestIdentityService()

                // Register mocks with DI container
                Container.shared.journeyService.register { mockJourneyService }
                Container.shared.nuxieApi.register { mockApi }
                Container.shared.flowService.register { mockFlowService }
                Container.shared.segmentService.register { mockSegmentService }
                Container.shared.identityService.register { mockIdentityService }
                Container.shared.dateProvider.register { MockDateProvider() }
                Container.shared.sleepProvider.register { MockSleepProvider() }

                // Create test campaign
                let showFlowNode = TestNodeBuilder.showFlow(id: "show-1", flowId: "test-flow")
                    .withNext(["exit-1"])
                    .build()

                let exitNode = TestNodeBuilder.exit(id: "exit-1").build()

                campaign = TestCampaignBuilder()
                    .withId("campaign-1")
                    .withName("Test Campaign")
                    .withNodes([showFlowNode, exitNode])
                    .withEntryNodeId("show-1")
                    .build()

                // Create profile service
                profileService = ProfileService()
            }

            afterEach {
                await mockJourneyService?.reset()
                // Don't reset container here - let beforeEach handle it
                // to avoid race conditions with background tasks accessing services
            }

            // MARK: - Resume from Profile Tests

            context("when profile contains active journeys") {
                it("calls resumeFromServerState with journeys and campaigns") {
                    // Given
                    let activeJourney = ActiveJourney(
                        sessionId: "session-123",
                        campaignId: "campaign-1",
                        currentNodeId: "show-1",
                        context: [:]
                    )

                    let profile = TestProfileResponseBuilder()
                        .withCampaigns([campaign])
                        .addJourney(activeJourney)
                        .build()

                    await mockApi.setProfileResponse(profile)

                    // When - use the public API
                    _ = try? await profileService.fetchProfile(distinctId: "user-1")

                    // Then
                    let calls = await mockJourneyService.resumeFromServerStateCalls
                    expect(calls).to(haveCount(1))
                    expect(calls.first?.journeys).to(haveCount(1))
                    expect(calls.first?.journeys.first?.sessionId).to(equal("session-123"))
                    expect(calls.first?.campaigns).to(haveCount(1))
                    expect(calls.first?.campaigns.first?.id).to(equal("campaign-1"))
                }

                it("resumes multiple journeys from server state") {
                    // Given
                    let campaign2 = TestCampaignBuilder()
                        .withId("campaign-2")
                        .withName("Campaign 2")
                        .withEntryNodeId("entry-2")
                        .build()

                    let journey1 = ActiveJourney(
                        sessionId: "session-1",
                        campaignId: "campaign-1",
                        currentNodeId: "show-1",
                        context: [:]
                    )

                    let journey2 = ActiveJourney(
                        sessionId: "session-2",
                        campaignId: "campaign-2",
                        currentNodeId: "entry-2",
                        context: [:]
                    )

                    let profile = TestProfileResponseBuilder()
                        .withCampaigns([campaign, campaign2])
                        .withJourneys([journey1, journey2])
                        .build()

                    await mockApi.setProfileResponse(profile)

                    // When
                    _ = try? await profileService.fetchProfile(distinctId: "user-1")

                    // Then
                    let calls = await mockJourneyService.resumeFromServerStateCalls
                    expect(calls).to(haveCount(1))
                    expect(calls.first?.journeys).to(haveCount(2))
                }

                it("passes journey context from server") {
                    // Given
                    let context: [String: AnyCodable] = [
                        "discount": AnyCodable(0.25),
                        "selectedPlan": AnyCodable("premium")
                    ]

                    let activeJourney = ActiveJourney(
                        sessionId: "session-123",
                        campaignId: "campaign-1",
                        currentNodeId: "show-1",
                        context: context
                    )

                    let profile = TestProfileResponseBuilder()
                        .withCampaigns([campaign])
                        .addJourney(activeJourney)
                        .build()

                    await mockApi.setProfileResponse(profile)

                    // When
                    _ = try? await profileService.fetchProfile(distinctId: "user-1")

                    // Then
                    let calls = await mockJourneyService.resumeFromServerStateCalls
                    expect(calls.first?.journeys.first?.context["discount"]?.value as? Double).to(equal(0.25))
                    expect(calls.first?.journeys.first?.context["selectedPlan"]?.value as? String).to(equal("premium"))
                }
            }

            // MARK: - No Resume Cases

            context("when profile has no active journeys") {
                it("does not call resumeFromServerState with empty array") {
                    // Given
                    let profile = TestProfileResponseBuilder()
                        .withCampaigns([campaign])
                        .withJourneys([])
                        .build()

                    await mockApi.setProfileResponse(profile)

                    // When
                    _ = try? await profileService.fetchProfile(distinctId: "user-1")

                    // Then
                    let calls = await mockJourneyService.resumeFromServerStateCalls
                    expect(calls).to(beEmpty())
                }

                it("does not call resumeFromServerState with nil journeys") {
                    // Given
                    let profile = TestProfileResponseBuilder()
                        .withCampaigns([campaign])
                        .build() // journeys is nil by default

                    await mockApi.setProfileResponse(profile)

                    // When
                    _ = try? await profileService.fetchProfile(distinctId: "user-1")

                    // Then
                    let calls = await mockJourneyService.resumeFromServerStateCalls
                    expect(calls).to(beEmpty())
                }
            }
        }
    }
}
