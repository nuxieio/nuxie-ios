// Path: packages/nuxie-ios/Tests/NuxieTests/Journey/Integration/WaitUntilNodeIntegrationTests.swift

import FactoryKit
import Foundation
import Nimble
import Quick

@testable import Nuxie

/// Integration tests for WaitUntil node:
/// - Static semantics (immediate condition, timeouts, indefinite wait)
/// - Reactive resume on event (and optionally segment)
final class WaitUntilNodeIntegrationTests: AsyncSpec {
  override class func spec() {
    describe("WaitUntil Node Integration") {
      // Spy + mocks
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

      // MARK: - Static semantics

      it("continues immediately when a non-timeout path condition is true (no persistence)") {
        let immediatePath = WaitUntilNode.WaitUntilData.WaitPath(
          id: "immediate-true",
          condition: TestWaitCondition.expression("true"),
          maxTime: nil,
          next: "success"
        )

        let campaign = TestCampaignBuilder()
          .withId("wu-immediate")
          .withFrequencyPolicy("every_rematch")
          .withNodes([
            AnyWorkflowNode(
              WaitUntilNode(
                id: "wait",
                next: [],
                data: WaitUntilNode.WaitUntilData(paths: [immediatePath])
              )),
            AnyWorkflowNode(
              ShowFlowNode(
                id: "success",
                next: ["exit"],
                data: ShowFlowNode.ShowFlowData(flowId: "wu-success-flow")
              )),
            AnyWorkflowNode(ExitNode(id: "exit", next: [], data: nil)),
          ])
          .withEntryNodeId("wait")
          .build()

        profileService.profileResponse = TestProfileResponseBuilder()
          .addCampaign(campaign)
          .build()

        let journey = await Container.shared.journeyService().startJourney(for: campaign, distinctId: "user_wu1", originEventId: nil)
        expect(journey).toNot(beNil())
        expect(journey?.status).to(equal(.completed))

        let jid = journey!.id
        spy.assertPath(["wait", "success", "exit"], for: jid)
        spy.assertFlowDisplayed("wu-success-flow", for: jid)
        spy.assertNoPersistence(for: jid)
      }

      it("pauses and persists when only a timeout path exists") {
        let timeoutPath = WaitUntilNode.WaitUntilData.WaitPath(
          id: "to-1h",
          condition: TestWaitCondition.expression("false"),
          maxTime: 3600,
          next: "timeout"
        )

        let campaign = TestCampaignBuilder()
          .withId("wu-timeout-only")
          .withFrequencyPolicy("once")
          .withNodes([
            AnyWorkflowNode(
              WaitUntilNode(
                id: "wait",
                next: [],
                data: WaitUntilNode.WaitUntilData(paths: [timeoutPath])
              )),
            AnyWorkflowNode(
              ShowFlowNode(
                id: "timeout",
                next: ["exit"],
                data: ShowFlowNode.ShowFlowData(flowId: "wu-timeout-flow")
              )),
            AnyWorkflowNode(ExitNode(id: "exit", next: [], data: nil)),
          ])
          .withEntryNodeId("wait")
          .build()

        profileService.profileResponse = TestProfileResponseBuilder()
          .addCampaign(campaign)
          .build()

        let start = dateProvider.now()
        let journey = await Container.shared.journeyService().startJourney(for: campaign, distinctId: "user_wu2", originEventId: nil)

        expect(journey).toNot(beNil())
        expect(journey?.status).to(equal(.paused))
        expect(journey?.currentNodeId).to(equal("wait"))

        let jid = journey!.id
        spy.assertPath(["wait"], for: jid)
        spy.assertPersistenceCount(1, for: jid)
        expect(spy.flowDisplayAttempts).to(beEmpty())

        expect(journey?.resumeAt).toNot(beNil())
        let expected = start.addingTimeInterval(3600).timeIntervalSince1970
        expect(journey!.resumeAt!.timeIntervalSince1970).to(beCloseTo(expected, within: 1.0))
      }

      it("schedules the earliest timeout when multiple timeouts exist") {
        let short = WaitUntilNode.WaitUntilData.WaitPath(
          id: "short",
          condition: TestWaitCondition.expression("false"),
          maxTime: 600,
          next: "short-path"
        )
        let long = WaitUntilNode.WaitUntilData.WaitPath(
          id: "long",
          condition: TestWaitCondition.expression("false"),
          maxTime: 7200,
          next: "long-path"
        )

        let campaign = TestCampaignBuilder()
          .withId("wu-multi-timeout")
          .withFrequencyPolicy("every_rematch")
          .withNodes([
            AnyWorkflowNode(
              WaitUntilNode(
                id: "wait",
                next: [],
                data: WaitUntilNode.WaitUntilData(paths: [short, long])
              )),
            AnyWorkflowNode(
              ShowFlowNode(
                id: "short-path",
                next: ["exit"],
                data: ShowFlowNode.ShowFlowData(flowId: "wu-short-flow")
              )),
            AnyWorkflowNode(
              ShowFlowNode(
                id: "long-path",
                next: ["exit"],
                data: ShowFlowNode.ShowFlowData(flowId: "wu-long-flow")
              )),
            AnyWorkflowNode(ExitNode(id: "exit", next: [], data: nil)),
          ])
          .withEntryNodeId("wait")
          .build()

        profileService.profileResponse = TestProfileResponseBuilder()
          .addCampaign(campaign)
          .build()

        let start = dateProvider.now()
        let journey = await Container.shared.journeyService().startJourney(for: campaign, distinctId: "user_wu3", originEventId: nil)

        expect(journey).toNot(beNil())
        expect(journey?.status).to(equal(.paused))
        expect(journey?.currentNodeId).to(equal("wait"))
        expect(journey?.resumeAt).toNot(beNil())

        let expected = start.addingTimeInterval(600).timeIntervalSince1970
        expect(journey!.resumeAt!.timeIntervalSince1970).to(beCloseTo(expected, within: 1.0))

        let jid = journey!.id
        spy.assertPath(["wait"], for: jid)
        spy.assertPersistenceCount(1, for: jid)
      }

      it("waits indefinitely (resumeAt == nil) when no timeout paths and conditions are false") {
        let neverNow = WaitUntilNode.WaitUntilData.WaitPath(
          id: "never-now",
          condition: TestWaitCondition.expression("false"),
          maxTime: nil,
          next: "success"
        )

        let campaign = TestCampaignBuilder()
          .withId("wu-indefinite")
          .withFrequencyPolicy("every_rematch")
          .withNodes([
            AnyWorkflowNode(
              WaitUntilNode(
                id: "wait",
                next: [],
                data: WaitUntilNode.WaitUntilData(paths: [neverNow])
              )),
            AnyWorkflowNode(
              ShowFlowNode(
                id: "success",
                next: ["exit"],
                data: ShowFlowNode.ShowFlowData(flowId: "wu-indef-flow")
              )),
            AnyWorkflowNode(ExitNode(id: "exit", next: [], data: nil)),
          ])
          .withEntryNodeId("wait")
          .build()

        profileService.profileResponse = TestProfileResponseBuilder()
          .addCampaign(campaign)
          .build()

        let journey = await Container.shared.journeyService().startJourney(for: campaign, distinctId: "user_wu4", originEventId: nil)

        expect(journey).toNot(beNil())
        expect(journey?.status).to(equal(.paused))
        expect(journey?.currentNodeId).to(equal("wait"))
        expect(journey?.resumeAt).to(beNil())

        let jid = journey!.id
        spy.assertPath(["wait"], for: jid)
        spy.assertPersistenceCount(1, for: jid)
        expect(spy.flowDisplayAttempts).to(beEmpty())
      }

      // MARK: - Reactive resume

      it("reactively resumes when the waited-for event occurs before timeout") {
        // Wait for purchase_completed OR timeout in 1h
        let waitPath = WaitUntilNode.WaitUntilData.WaitPath(
          id: "purchase-path",
          condition: TestWaitCondition.event("purchase_completed"),
          maxTime: nil,
          next: "success"
        )
        let timeoutPath = WaitUntilNode.WaitUntilData.WaitPath(
          id: "timeout-path",
          condition: TestWaitCondition.expression("false"),  // never true
          maxTime: 3600,
          next: "timeout"
        )

        let campaign = TestCampaignBuilder()
          .withId("wait-event-campaign")
          .withFrequencyPolicy("once")
          .withNodes([
            AnyWorkflowNode(
              ShowFlowNode(
                id: "start",
                next: ["wait"],
                data: ShowFlowNode.ShowFlowData(flowId: "start-flow")
              )),
            AnyWorkflowNode(
              WaitUntilNode(
                id: "wait",
                next: [],
                data: WaitUntilNode.WaitUntilData(paths: [waitPath, timeoutPath])
              )),
            AnyWorkflowNode(
              ShowFlowNode(
                id: "success",
                next: ["exit"],
                data: ShowFlowNode.ShowFlowData(flowId: "success-flow")
              )),
            AnyWorkflowNode(
              ShowFlowNode(
                id: "timeout",
                next: ["exit"],
                data: ShowFlowNode.ShowFlowData(flowId: "timeout-flow")
              )),
            AnyWorkflowNode(ExitNode(id: "exit", next: [], data: nil)),
          ])
          .withEntryNodeId("start")
          .build()

        profileService.profileResponse = TestProfileResponseBuilder()
          .addCampaign(campaign)
          .build()

        // Start: should pause at wait
        let journey = await Container.shared.journeyService().startJourney(for: campaign, distinctId: "user_reactive", originEventId: nil)
        expect(journey).toNot(beNil())
        expect(journey?.status).to(equal(.paused))
        expect(journey?.currentNodeId).to(equal("wait"))
        let jid = journey!.id

        // Verify start->wait path + persistence
        spy.assertPath(["start", "wait"], for: jid)
        spy.assertFlowDisplayed("start-flow", for: jid)
        spy.assertPersistenceCount(1, for: jid)

        // Fire the event that should satisfy the wait immediately
        let event = TestEventBuilder()
          .withName("purchase_completed")
          .withDistinctId("user_reactive")
          .withProperties(["amount": 99.99])
          .build()

        await Container.shared.journeyService().handleEvent(event)

        // Journey should complete via success path immediately
        let activeJourneys = await Container.shared.journeyService().getActiveJourneys(for: "user_reactive")
        expect(activeJourneys).to(beEmpty())

        spy.assertPath(["start", "wait", "wait", "success", "exit"], for: jid)
        spy.assertFlowDisplayed("success-flow", for: jid)
        expect(spy.flowDisplayAttempts.map { $0.flowId }).toNot(contain("timeout-flow"))

        let last = spy.nodeExecutions.last { $0.journeyId == jid }
        expect(last?.nodeId).to(equal("exit"))
      }

      // Optional: enable if your MockSegmentService exposes a way to emit a segment-change result
      xit("reactively resumes when a segment-change satisfies the condition") {
        // Build a wait path that depends on membership; emit a segment change and assert resume.
      }
    }
  }
}
