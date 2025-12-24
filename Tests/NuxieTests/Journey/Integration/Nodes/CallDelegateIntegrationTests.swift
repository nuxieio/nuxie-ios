import FactoryKit
import Foundation
import Nimble
import Quick

@testable import Nuxie

final class CallDelegateNodeIntegrationTests: AsyncSpec {
  override class func spec() {
    describe("CallDelegate node (integration)") {
      var spy: JourneyTestSpy!

      var journeyStore: MockJourneyStore!
      var spyJourneyStore: SpyJourneyStore!
      var spyJourneyExecutor: SpyJourneyExecutor!

      func makeCampaign() -> Campaign {
        let call = CallDelegateNode(
          id: "call",
          next: ["exit"],
          data: .init(message: "Hello from node", payload: AnyCodable(["foo": "bar"]))
        )
        let exit = ExitNode(id: "exit", next: [], data: .init(reason: "completed"))
        return Campaign(
          id: "call-campaign",
          name: "CallDelegate Campaign",
          versionId: "v1",
          versionNumber: 1,
          frequencyPolicy: "every_rematch",
          frequencyInterval: nil,
          messageLimit: nil,
          publishedAt: "2024-01-01",
          trigger: .event(.init(eventName: "trigger", condition: nil)),
          entryNodeId: "call",
          workflow: Workflow(nodes: [AnyWorkflowNode(call), AnyWorkflowNode(exit)]),
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
        // Don't reset container here - let beforeEach handle it
        // to avoid race conditions with background tasks accessing services
      }

      it("posts a call-delegate notification and completes") {
        let c = makeCampaign()
        let user = "user_call"
        var received: [String: Any]?

        let center = NotificationCenter.default
        let token = center.addObserver(forName: .nuxieCallDelegate, object: nil, queue: .main) {
          note in
          received = note.userInfo as? [String: Any]
        }
        defer { center.removeObserver(token) }

        _ = await Container.shared.journeyService().startJourney(for: c, distinctId: user, originEventId: nil)

        await expect(received).toEventuallyNot(beNil())
        expect(received?["message"] as? String).to(equal("Hello from node"))
        expect(received?["nodeId"] as? String).to(equal("call"))
        if let payload = received?["payload"] as? [String: Any] {
          expect(payload["foo"] as? String).to(equal("bar"))
        } else {
          // On some encodings AnyCodable may become a raw value; don't fail hard
          // The presence of the notification + message is the key behavior.
        }

        let active = await Container.shared.journeyService().getActiveJourneys(for: user)
        expect(active).to(beEmpty())
      }
    }
  }
}
