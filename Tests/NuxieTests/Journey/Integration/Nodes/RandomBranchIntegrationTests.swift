import FactoryKit
import Foundation
import Nimble
import Quick

@testable import Nuxie

final class RandomBranchNodeIntegrationTests: AsyncSpec {
  override class func spec() {
    describe("RandomBranch node (integration)") {
      var spy: JourneyTestSpy!

      var journeyStore: MockJourneyStore!
      var spyJourneyStore: SpyJourneyStore!
      var spyJourneyExecutor: SpyJourneyExecutor!
      var flowPresentationService: MockFlowPresentationService!

      func makeCampaign() -> Campaign {
        let random = RandomBranchNode(
          id: "rnd",
          next: ["A"],
          data: .init(branches: [
            .init(percentage: 100.0, name: "AllA")
          ])
        )
        let showA = ShowFlowNode(id: "A", next: ["exit"], data: .init(flowId: "flow-A"))
        let exit = ExitNode(id: "exit", next: [], data: .init(reason: "completed"))

        return Campaign(
          id: "random-campaign",
          name: "Random Campaign",
          versionId: "v1",
          versionNumber: 1,
          frequencyPolicy: "every_rematch",
          frequencyInterval: nil,
          messageLimit: nil,
          publishedAt: "2024-01-01",
          trigger: .event(.init(eventName: "trigger", condition: nil)),
          entryNodeId: "rnd",
          workflow: Workflow(nodes: [
            AnyWorkflowNode(random), AnyWorkflowNode(showA), AnyWorkflowNode(exit),
          ]),
          goal: nil, exitPolicy: nil, conversionAnchor: nil, campaignType: nil
        )
      }

      beforeEach {
        Container.shared.identityService.register { MockIdentityService() }
        Container.shared.segmentService.register { MockSegmentService() }
        Container.shared.profileService.register { MockProfileService() }
        Container.shared.eventService.register { MockEventService() }
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
        Container.shared.reset()
      }

      it("follows the single 100% branch and completes") {
        let c = makeCampaign()
        let user = "user_random"
        _ = await Container.shared.journeyService().startJourney(for: c, distinctId: user, originEventId: nil)

        await expect(flowPresentationService.wasFlowPresented("flow-A")).toEventually(beTrue())

        let active = await Container.shared.journeyService().getActiveJourneys(for: user)
        expect(active).to(beEmpty())
      }
    }
  }
}
