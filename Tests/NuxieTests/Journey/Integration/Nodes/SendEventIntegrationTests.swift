import FactoryKit
import Foundation
import Nimble
import Quick

@testable import Nuxie

final class SendEventNodeIntegrationTests: AsyncSpec {
  override class func spec() {
    describe("SendEvent node (integration)") {
      var spy: JourneyTestSpy!

      var journeyStore: MockJourneyStore!
      var spyJourneyStore: SpyJourneyStore!
      var spyJourneyExecutor: SpyJourneyExecutor!
      var eventService: JourneyExecutorTestEventService!

      func makeCampaign() -> Campaign {
        let send = SendEventNode(
          id: "send",
          next: ["exit"],
          data: .init(
            eventName: "promo_sent",
            properties: [
              "source": AnyCodable("journey"),
              "cta": AnyCodable("open"),
            ])
        )
        let exit = ExitNode(id: "exit", next: [], data: .init(reason: "completed"))

        return Campaign(
          id: "send-campaign",
          name: "SendEvent Campaign",
          versionId: "v1",
          versionNumber: 1,
          frequencyPolicy: "every_rematch",
          frequencyInterval: nil,
          messageLimit: nil,
          publishedAt: "2024-01-01",
          trigger: .event(.init(eventName: "trigger", condition: nil)),
          entryNodeId: "send",
          workflow: Workflow(nodes: [AnyWorkflowNode(send), AnyWorkflowNode(exit)]),
          goal: nil, exitPolicy: nil, conversionAnchor: nil, campaignType: nil
        )
      }

      beforeEach {

        // Register test configuration (required for any services that depend on sdkConfiguration)
        let testConfig = NuxieConfiguration(apiKey: "test-api-key")
        Container.shared.sdkConfiguration.register { testConfig }

        Container.shared.identityService.register { MockIdentityService() }
        Container.shared.segmentService.register { MockSegmentService() }
        Container.shared.profileService.register { MockProfileService() }
        eventService = JourneyExecutorTestEventService()
        Container.shared.eventService.register { eventService }
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
        eventService.reset()
        // Don't reset container here - let beforeEach handle it
        // to avoid race conditions with background tasks accessing services
      }

      it("tracks the custom event and completes") {
        let c = makeCampaign()
        let user = "user_send"
        _ = await Container.shared.journeyService().startJourney(for: c, distinctId: user, originEventId: nil)

        // Our mock records both the custom event and the internal $event_sent
        let sent = eventService.trackedEvents.first(where: { $0.name == "promo_sent" })
        expect(sent).toNot(beNil())
        expect(sent?.properties?["nodeId"] as? String).to(equal("send"))
        expect(sent?.properties?["campaignId"] as? String).to(equal("send-campaign"))

        let active = await Container.shared.journeyService().getActiveJourneys(for: user)
        expect(active).to(beEmpty())
      }
    }
  }
}
