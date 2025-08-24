import FactoryKit
import Foundation
import Nimble
import Quick

@testable import Nuxie

final class ShowFlowIntegrationTests: AsyncSpec {
  override class func spec() {
    describe("ShowFlow node (integration)") {
      var spy: JourneyTestSpy!

      var journeyStore: MockJourneyStore!
      var spyJourneyStore: SpyJourneyStore!
      var spyJourneyExecutor: SpyJourneyExecutor!
      var eventService: JourneyExecutorTestEventService!
      var flowPresentationService: MockFlowPresentationService!

      func makeCampaign() -> Campaign {
        let show = ShowFlowNode(
          id: "show",
          next: ["exit"],
          data: .init(flowId: "sf-flow")
        )
        let exit = ExitNode(id: "exit", next: [], data: .init(reason: "completed"))

        return Campaign(
          id: "sf-campaign",
          name: "ShowFlow Campaign",
          versionId: "v1",
          versionNumber: 1,
          frequencyPolicy: "every_rematch",
          frequencyInterval: nil,
          messageLimit: nil,
          publishedAt: "2024-01-01",
          trigger: .event(.init(eventName: "trigger", condition: nil)),
          entryNodeId: "show",
          workflow: Workflow(nodes: [AnyWorkflowNode(show), AnyWorkflowNode(exit)]),
          goal: nil, exitPolicy: nil, conversionAnchor: nil, campaignType: nil
        )
      }

      beforeEach {
        Container.shared.identityService.register { MockIdentityService() }
        Container.shared.segmentService.register { MockSegmentService() }
        Container.shared.profileService.register { MockProfileService() }
        eventService = JourneyExecutorTestEventService()
        Container.shared.eventService.register { eventService }
        Container.shared.nuxieApi.register { MockNuxieApi() }
        Container.shared.flowService.register { MockFlowService() }
        flowPresentationService = MockFlowPresentationService()
        Container.shared.flowPresentationService.register { flowPresentationService }
        Container.shared.dateProvider.register { MockDateProvider() }
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
        flowPresentationService.reset()
        eventService.reset()
        Container.shared.reset()
      }

      it("presents the requested flow and completes") {
        let campaign = makeCampaign()
        let user = "user_show"

        _ = await Container.shared.journeyService().startJourney(for: campaign, distinctId: user, originEventId: nil)

        // Present happens via an async @MainActor call inside the executor
        await expect(flowPresentationService.wasFlowPresented("sf-flow")).toEventually(beTrue())

        // Journey should be completed and removed
        let active = await Container.shared.journeyService().getActiveJourneys(for: user)
        expect(active).to(beEmpty())

        // We also track $flow_shown
        let shown = eventService.trackedEvents.contains { $0.name == JourneyEvents.flowShown }
        expect(shown).to(beTrue())
      }
    }
  }
}
