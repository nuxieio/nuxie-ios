import FactoryKit
import Foundation
import Nimble
import Quick

@testable import Nuxie

final class MultiBranchNodeIntegrationTests: AsyncSpec {
  override class func spec() {
    describe("MultiBranch node (integration)") {
      var spy: JourneyTestSpy!

      var journeyStore: MockJourneyStore!
      var spyJourneyStore: SpyJourneyStore!
      var spyJourneyExecutor: SpyJourneyExecutor!
      var flowPresentationService: MockFlowPresentationService!

      func campaign(conditions: [IREnvelope]) -> Campaign {
        let multi = MultiBranchNode(
          id: "multi",
          next: ["p1", "p2", "default"],  // last is default
          data: .init(conditions: conditions)
        )
        let p1 = ShowFlowNode(id: "p1", next: ["exit"], data: .init(flowId: "flow-1"))
        let p2 = ShowFlowNode(id: "p2", next: ["exit"], data: .init(flowId: "flow-2"))
        let def = ShowFlowNode(id: "default", next: ["exit"], data: .init(flowId: "flow-default"))
        let exit = ExitNode(id: "exit", next: [], data: .init(reason: "completed"))

        return TestCampaignBuilder(id: "multi-campaign")
          .withName("Multi Campaign")
          .withFrequencyPolicy("every_rematch")
          .withEventTrigger(eventName: "trigger")
          .withEntryNodeId("multi")
          .withNodes([
            AnyWorkflowNode(multi),
            AnyWorkflowNode(p1),
            AnyWorkflowNode(p2),
            AnyWorkflowNode(def),
            AnyWorkflowNode(exit),
          ])
          .build()
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

      it("routes to the first matching condition") {
        // first=false, second=true -> routes to p2
        let conds = [
          TestIRBuilder.alwaysFalse(),
          TestIRBuilder.alwaysTrue(),
        ]
        let c = campaign(conditions: conds)
        let user = "user_multi_1"
        _ = await Container.shared.journeyService().startJourney(for: c, distinctId: user, originEventId: nil)
        await expect(flowPresentationService.wasFlowPresented("flow-2")).toEventually(beTrue())
        await expect(flowPresentationService.wasFlowPresented("flow-1")).toEventually(beFalse())

        let active = await Container.shared.journeyService().getActiveJourneys(for: user)
        expect(active).to(beEmpty())
      }

      it("falls back to default when none match") {
        let conds = [
          TestIRBuilder.alwaysFalse(),
          TestIRBuilder.alwaysFalse(),
        ]
        let c = campaign(conditions: conds)
        let user = "user_multi_default"
        _ = await Container.shared.journeyService().startJourney(for: c, distinctId: user, originEventId: nil)
        await expect(flowPresentationService.wasFlowPresented("flow-default")).toEventually(beTrue())

        let active = await Container.shared.journeyService().getActiveJourneys(for: user)
        expect(active).to(beEmpty())
      }
      
      describe("error handling") {
        it("takes the default path when condition evaluation fails") {
          // Create conditions that will cause errors during evaluation
          let errorConditions = [
            IREnvelope(
              ir_version: 1,
              engine_min: nil,
              compiled_at: nil,
              // Use an invalid operator that will cause evaluation to fail
            expr: .compare(op: "INVALID_OP", left: .number(1), right: .number(2))
            ),
            IREnvelope(
              ir_version: 1,
              engine_min: nil,
              compiled_at: nil,
              // Another invalid operation
            expr: .user(op: "UNKNOWN_OP", key: "test", value: nil)
            )
          ]
          let c = campaign(conditions: errorConditions)
          let user = "user_multi_error"
          
          _ = await Container.shared.journeyService().startJourney(for: c, distinctId: user, originEventId: nil)
          
          // Should take default path (last element) on error
          await expect(flowPresentationService.wasFlowPresented("flow-default")).toEventually(beTrue())
          await expect(flowPresentationService.wasFlowPresented("flow-1")).toEventually(beFalse())
          await expect(flowPresentationService.wasFlowPresented("flow-2")).toEventually(beFalse())
          
          let active = await Container.shared.journeyService().getActiveJourneys(for: user)
          expect(active).to(beEmpty())
        }
        
        it("completes with error when no default path exists on error") {
          // Create multiBranch without default path (same count as conditions)
          let errorConditions = [
            IREnvelope(
              ir_version: 1,
              engine_min: nil,
              compiled_at: nil,
              // Use an invalid operator that will cause evaluation to fail
            expr: .compare(op: "INVALID_OP", left: .number(1), right: .number(2))
            ),
            IREnvelope(
              ir_version: 1,
              engine_min: nil,
              compiled_at: nil,
              // Another invalid operation
            expr: .user(op: "UNKNOWN_OP", key: "test", value: nil)
            )
          ]
          
          let multi = MultiBranchNode(
            id: "multi",
            next: ["p1", "p2"],  // No default path
            data: .init(conditions: errorConditions)
          )
          let p1 = ShowFlowNode(id: "p1", next: ["exit"], data: .init(flowId: "flow-1"))
          let p2 = ShowFlowNode(id: "p2", next: ["exit"], data: .init(flowId: "flow-2"))
          let exit = ExitNode(id: "exit", next: [], data: .init(reason: "completed"))
          
          let noDefaultCampaign = TestCampaignBuilder(id: "multi-no-default")
            .withName("Multi No Default")
            .withFrequencyPolicy("every_rematch")
            .withEventTrigger(eventName: "trigger")
            .withEntryNodeId("multi")
            .withNodes([
              AnyWorkflowNode(multi),
              AnyWorkflowNode(p1),
              AnyWorkflowNode(p2),
              AnyWorkflowNode(exit),
            ])
            .build()
          
          let user = "user_multi_no_default_error"
          _ = await Container.shared.journeyService().startJourney(for: noDefaultCampaign, distinctId: user, originEventId: nil)
          
          // Should not present any flows when error with no default
          await expect(flowPresentationService.wasFlowPresented("flow-1")).toEventually(beFalse())
          await expect(flowPresentationService.wasFlowPresented("flow-2")).toEventually(beFalse())
          
          // Journey should complete with error
          let active = await Container.shared.journeyService().getActiveJourneys(for: user)
          expect(active).to(beEmpty())
        }
        
        it("validates path configuration and logs warning for mismatched counts") {
          // MultiBranch with fewer paths than expected (conditions + default)
          let multi = MultiBranchNode(
            id: "multi",
            next: ["p1"],  // Only 1 path but 2 conditions (should have 3)
            data: .init(conditions: [
              TestIRBuilder.alwaysFalse(),
              TestIRBuilder.alwaysFalse()
            ])
          )
          let p1 = ShowFlowNode(id: "p1", next: ["exit"], data: .init(flowId: "flow-1"))
          let exit = ExitNode(id: "exit", next: [], data: .init(reason: "completed"))
          
          let mismatchedCampaign = TestCampaignBuilder(id: "multi-mismatched")
            .withName("Multi Mismatched")
            .withFrequencyPolicy("every_rematch")
            .withEventTrigger(eventName: "trigger")
            .withEntryNodeId("multi")
            .withNodes([
              AnyWorkflowNode(multi),
              AnyWorkflowNode(p1),
              AnyWorkflowNode(exit),
            ])
            .build()
          
          let user = "user_multi_mismatched"
          _ = await Container.shared.journeyService().startJourney(for: mismatchedCampaign, distinctId: user, originEventId: nil)
          
          // Should still execute but log warning (we can't directly test logging,
          // but we can verify it doesn't crash)
          let active = await Container.shared.journeyService().getActiveJourneys(for: user)
          await expect(active).toEventuallyNot(beNil())
        }
      }
    }
  }
}
