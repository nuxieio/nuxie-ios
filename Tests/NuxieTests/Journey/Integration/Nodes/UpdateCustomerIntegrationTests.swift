import FactoryKit
import Foundation
import Nimble
import Quick

@testable import Nuxie

final class UpdateCustomerNodeIntegrationTests: AsyncSpec {
  override class func spec() {
    describe("UpdateCustomer node (integration)") {
      var spy: JourneyTestSpy!

      var journeyStore: MockJourneyStore!
      var spyJourneyStore: SpyJourneyStore!
      var spyJourneyExecutor: SpyJourneyExecutor!
      var identityService: JourneyExecutorTestIdentityService!

      func makeCampaign() -> Campaign {
        let update = UpdateCustomerNode(
          id: "update",
          next: ["exit"],
          data: .init(attributes: [
            "vip": AnyCodable(true),
            "plan": AnyCodable("pro"),
            "score": AnyCodable(7),
          ])
        )
        let exit = ExitNode(id: "exit", next: [], data: .init(reason: "completed"))

        return Campaign(
          id: "update-campaign",
          name: "Update Campaign",
          versionId: "v1",
          versionNumber: 1,
          frequencyPolicy: "every_rematch",
          frequencyInterval: nil,
          messageLimit: nil,
          publishedAt: "2024-01-01",
          trigger: .event(.init(eventName: "trigger", condition: nil)),
          entryNodeId: "update",
          workflow: Workflow(nodes: [AnyWorkflowNode(update), AnyWorkflowNode(exit)]),
          goal: nil, exitPolicy: nil, conversionAnchor: nil, campaignType: nil
        )
      }

      beforeEach {

        // Register test configuration (required for any services that depend on sdkConfiguration)
        let testConfig = NuxieConfiguration(apiKey: "test-api-key")
        Container.shared.sdkConfiguration.register { testConfig }

        identityService = JourneyExecutorTestIdentityService()
        Container.shared.identityService.register { identityService }
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
        identityService.reset()
        // Don't reset container here - let beforeEach handle it
        // to avoid race conditions with background tasks accessing services
      }

      it("updates user properties and completes") {
        let c = makeCampaign()
        let user = "user_update"
        _ = await Container.shared.journeyService().startJourney(for: c, distinctId: user, originEventId: nil)

        let props = identityService.getUserProperties()
        expect(props["vip"] as? Bool).to(equal(true))
        expect(props["plan"] as? String).to(equal("pro"))
        expect(props["score"] as? Int).to(equal(7))

        let active = await Container.shared.journeyService().getActiveJourneys(for: user)
        expect(active).to(beEmpty())
      }
    }
  }
}
