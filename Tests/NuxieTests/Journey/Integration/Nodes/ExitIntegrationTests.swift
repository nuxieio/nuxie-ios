import FactoryKit
import Foundation
import Nimble
import Quick

@testable import Nuxie

final class ExitNodeIntegrationTests: AsyncSpec {
  override class func spec() {
    describe("Exit node (integration)") {
      var spy: JourneyTestSpy!

      var journeyStore: MockJourneyStore!
      var spyJourneyStore: SpyJourneyStore!
      var spyJourneyExecutor: SpyJourneyExecutor!

      func makeCampaign(exitReason: String? = "completed") -> Campaign {
        let exit = ExitNode(id: "exit", next: [], data: .init(reason: exitReason))
        return Campaign(
          id: "exit-campaign",
          name: "Exit Campaign",
          versionId: "v1",
          versionNumber: 1,
          frequencyPolicy: "every_rematch",
          frequencyInterval: nil,
          messageLimit: nil,
          publishedAt: "2024-01-01",
          trigger: .event(.init(eventName: "trigger", condition: nil)),
          entryNodeId: "exit",
          workflow: Workflow(nodes: [AnyWorkflowNode(exit)]),
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
        Container.shared.flowPresentationService.register { MockFlowPresentationService() }
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

      it("completes immediately when entry node is exit") {
        let campaign = makeCampaign()
        let user = "user_exit"
        _ = await Container.shared.journeyService().startJourney(for: campaign, distinctId: user, originEventId: nil)

        let active = await Container.shared.journeyService().getActiveJourneys(for: user)
        expect(active).to(beEmpty())
      }
    }
  }
}
