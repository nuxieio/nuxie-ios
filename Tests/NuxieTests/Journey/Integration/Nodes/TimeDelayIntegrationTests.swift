// Path: packages/nuxie-ios/Tests/NuxieTests/Journey/Integration/TimeDelayIntegrationTests.swift

import FactoryKit
import Foundation
import Nimble
import Quick

@testable import Nuxie

/// Integration tests focused on TimeDelay node semantics
final class TimeDelayIntegrationTests: AsyncSpec {
  override class func spec() {
    describe("TimeDelay Integration") {
      var spy: JourneyTestSpy!

      var journeyStore: MockJourneyStore!
      var spyJourneyStore: SpyJourneyStore!
      var spyJourneyExecutor: SpyJourneyExecutor!
      var profileService: MockProfileService!
      var dateProvider: MockDateProvider!

      beforeEach {

        // Register test configuration (required for any services that depend on sdkConfiguration)
        let testConfig = NuxieConfiguration(apiKey: "test-api-key")
        Container.shared.sdkConfiguration.register { testConfig }

        Container.shared.identityService.register { MockIdentityService() }
        Container.shared.segmentService.register { MockSegmentService() }
        profileService = MockProfileService()
        Container.shared.profileService.register { profileService }
        Container.shared.eventService.register { MockEventService() }
        Container.shared.nuxieApi.register { MockNuxieApi() }
        Container.shared.flowService.register { MockFlowService() }
        Container.shared.flowPresentationService.register { MockFlowPresentationService() }
        dateProvider = MockDateProvider()
        Container.shared.dateProvider.register { dateProvider }
        Container.shared.sleepProvider.register { MockSleepProvider() }
        Container.shared.productService.register { MockProductService() }

        journeyStore = MockJourneyStore()
        spy = JourneyTestSpy()
        spyJourneyStore = SpyJourneyStore(realStore: journeyStore, spy: spy)
        spyJourneyExecutor = SpyJourneyExecutor(spy: spy)

        Container.shared.journeyService.register {
          let tempDir = FileManager.default.temporaryDirectory
          let testStoragePath = tempDir.appendingPathComponent(
            "test-journey-\(UUID.v7().uuidString)")
          return JourneyService(
            journeyStore: spyJourneyStore,
            journeyExecutor: spyJourneyExecutor,
            customStoragePath: testStoragePath
          )
        }

        await Container.shared.journeyService().initialize()
      }

      afterEach {
        await Container.shared.journeyService().shutdown()
        // Don't reset container here - let beforeEach handle it
        // to avoid race conditions with background tasks accessing services
      }

      it("continues immediately for zero duration (no persistence)") {
        let campaign = TestCampaignBuilder()
          .withId("td-zero")
          .withFrequencyPolicy("every_rematch")
          .withNodes([
            AnyWorkflowNode(
              TimeDelayNode(
                id: "delay",
                next: ["show"],
                data: TimeDelayNode.TimeDelayData(duration: 0)
              )),
            AnyWorkflowNode(
              ShowFlowNode(
                id: "show",
                next: ["exit"],
                data: ShowFlowNode.ShowFlowData(flowId: "td-flow")
              )),
            AnyWorkflowNode(ExitNode(id: "exit", next: [], data: nil)),
          ])
          .withEntryNodeId("delay")
          .build()

        profileService.profileResponse = TestProfileResponseBuilder()
          .addCampaign(campaign)
          .build()

        let journey = await Container.shared.journeyService().startJourney(for: campaign, distinctId: "user_td_zero", originEventId: nil)
        expect(journey).toNot(beNil())
        expect(journey?.status).to(equal(.completed))
        expect(journey?.exitReason).to(equal(.completed))

        let jid = journey!.id
        spy.assertPath(["delay", "show", "exit"], for: jid)
        spy.assertNodeExecuted("delay", in: jid, withResult: .continue(["show"]))
        spy.assertFlowDisplayed("td-flow", for: jid)
        spy.assertNoPersistence(for: jid)
      }

      it("continues immediately for negative duration (no persistence)") {
        let campaign = TestCampaignBuilder()
          .withId("td-negative")
          .withFrequencyPolicy("every_rematch")
          .withNodes([
            AnyWorkflowNode(
              TimeDelayNode(
                id: "delay",
                next: ["show"],
                data: TimeDelayNode.TimeDelayData(duration: -10)  // negative
              )),
            AnyWorkflowNode(
              ShowFlowNode(
                id: "show",
                next: ["exit"],
                data: ShowFlowNode.ShowFlowData(flowId: "td-flow-neg")
              )),
            AnyWorkflowNode(ExitNode(id: "exit", next: [], data: nil)),
          ])
          .withEntryNodeId("delay")
          .build()

        profileService.profileResponse = TestProfileResponseBuilder()
          .addCampaign(campaign)
          .build()

        let journey = await Container.shared.journeyService().startJourney(for: campaign, distinctId: "user_td_neg", originEventId: nil)
        expect(journey).toNot(beNil())
        expect(journey?.status).to(equal(.completed))
        expect(journey?.exitReason).to(equal(.completed))

        let jid = journey!.id
        spy.assertPath(["delay", "show", "exit"], for: jid)
        spy.assertNodeExecuted("delay", in: jid, withResult: .continue(["show"]))
        spy.assertFlowDisplayed("td-flow-neg", for: jid)
        spy.assertNoPersistence(for: jid)
      }

      it("pauses and persists for positive duration (async)") {
        let duration: TimeInterval = 3600
        let campaign = TestCampaignBuilder()
          .withId("td-positive")
          .withFrequencyPolicy("every_rematch")
          .withNodes([
            AnyWorkflowNode(
              TimeDelayNode(
                id: "delay",
                next: ["show"],
                data: TimeDelayNode.TimeDelayData(duration: duration)
              )),
            AnyWorkflowNode(
              ShowFlowNode(
                id: "show",
                next: ["exit"],
                data: ShowFlowNode.ShowFlowData(flowId: "td-delayed-flow")
              )),
            AnyWorkflowNode(ExitNode(id: "exit", next: [], data: nil)),
          ])
          .withEntryNodeId("delay")
          .build()

        profileService.profileResponse = TestProfileResponseBuilder()
          .addCampaign(campaign)
          .build()

        let start = dateProvider.now()
        let journey = await Container.shared.journeyService().startJourney(for: campaign, distinctId: "user_td_pos", originEventId: nil)

        expect(journey).toNot(beNil())
        expect(journey?.status).to(equal(.paused))
        expect(journey?.currentNodeId).to(equal("delay"))

        let jid = journey!.id
        spy.assertPath(["delay"], for: jid)
        spy.assertNodeExecuted("delay", in: jid, withResult: .async(journey?.resumeAt))
        spy.assertPersistenceCount(1, for: jid)

        // No flow yet
        expect(spy.flowDisplayAttempts).to(beEmpty())

        // ResumeAt ~ now + duration
        expect(journey?.resumeAt).toNot(beNil())
        let expected = start.addingTimeInterval(duration).timeIntervalSince1970
        let actual = journey!.resumeAt!.timeIntervalSince1970
        expect(actual).to(beCloseTo(expected, within: 1.0))
      }
    }
  }
}
