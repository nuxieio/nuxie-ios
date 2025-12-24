import FactoryKit
import Foundation
import Nimble
import Quick

@testable import Nuxie

final class BranchNodeIntegrationTests: AsyncSpec {
  override class func spec() {
    describe("Branch node (integration)") {
      var spy: JourneyTestSpy!

      var journeyStore: MockJourneyStore!
      var spyJourneyStore: SpyJourneyStore!
      var spyJourneyExecutor: SpyJourneyExecutor!

      func campaign(condition: IREnvelope) -> Campaign {
        let branch = BranchNode(
          id: "branch",
          next: ["delegate_true", "delegate_false"],
          data: .init(condition: condition)
        )
        let delegateTrue = CallDelegateNode(
          id: "delegate_true",
          next: ["exit"],
          data: .init(message: "true-branch-taken", payload: .init(["branch": "true"]))
        )
        let delegateFalse = CallDelegateNode(
          id: "delegate_false",
          next: ["exit"],
          data: .init(message: "false-branch-taken", payload: .init(["branch": "false"]))
        )
        let exit = ExitNode(id: "exit", next: [], data: .init(reason: "completed"))

        return TestCampaignBuilder(id: "branch-campaign")
          .withName("Branch Campaign")
          .withFrequencyPolicy("every_rematch")
          .withEventTrigger(eventName: "trigger")
          .withEntryNodeId("branch")
          .withNodes([
            AnyWorkflowNode(branch),
            AnyWorkflowNode(delegateTrue),
            AnyWorkflowNode(delegateFalse),
            AnyWorkflowNode(exit),
          ])
          .build()
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

      it("takes the true path when condition is true") {
        let cond = TestIRBuilder.alwaysTrue()
        let campaign = campaign(condition: cond)
        let user = "user_branch_true"

        let journey = await Container.shared.journeyService().startJourney(
          for: campaign, distinctId: user, originEventId: nil)
        await Task.yield()

        expect(journey).toNot(beNil())
        let journeyId = journey!.id

        // Verify the journey executed the expected path through spy introspection
        spy.assertPath(["branch", "delegate_true", "exit"], for: journeyId)

        // Verify specific node executions and their results
        spy.assertNodeExecuted("branch", in: journeyId, withResult: .continue(["delegate_true"]))
        spy.assertNodeExecuted("delegate_true", in: journeyId)
        spy.assertNodeExecuted("exit", in: journeyId, withResult: .complete(.completed))

        // Verify delegate was called with correct message
        spy.assertDelegateCalled("true-branch-taken", for: journeyId)

        // Verify the false branch was not taken
        expect(spy.wasNodeExecuted("delegate_false", in: journeyId)).to(beFalse())

        // Verify journey completed successfully by checking the journey object directly
        expect(journey!.status).to(equal(.completed))
        expect(journey!.exitReason).to(equal(.completed))
      }

      it("takes the false path when condition is false") {
        let cond = TestIRBuilder.alwaysFalse()
        let campaign = campaign(condition: cond)
        let user = "user_branch_false"

        let journey = await Container.shared.journeyService().startJourney(
          for: campaign, distinctId: user, originEventId: nil)
        await Task.yield()

        expect(journey).toNot(beNil())
        let journeyId = journey!.id

        // Verify the journey executed the expected path through spy introspection
        spy.assertPath(["branch", "delegate_false", "exit"], for: journeyId)

        // Verify specific node executions and their results
        spy.assertNodeExecuted("branch", in: journeyId, withResult: .continue(["delegate_false"]))
        spy.assertNodeExecuted("delegate_false", in: journeyId)
        spy.assertNodeExecuted("exit", in: journeyId, withResult: .complete(.completed))

        // Verify delegate was called with correct message
        spy.assertDelegateCalled("false-branch-taken", for: journeyId)

        // Verify the true branch was not taken
        expect(spy.wasNodeExecuted("delegate_true", in: journeyId)).to(beFalse())

        // Verify journey completed successfully by checking the journey object directly
        expect(journey!.status).to(equal(.completed))
        expect(journey!.exitReason).to(equal(.completed))
      }

      describe("error handling") {
        it("takes the false path when condition evaluation fails") {
          // Create a condition that will cause an error during evaluation
          let errorCondition = IREnvelope(
            ir_version: 1,
            engine_min: nil,
            compiled_at: nil,
            // Use an invalid operator that will cause evaluation to fail
            expr: .compare(op: "INVALID_OP", left: .bool(true), right: .bool(false))
          )
          let campaign = campaign(condition: errorCondition)
          let user = "user_branch_error"

          let journey = await Container.shared.journeyService().startJourney(
            for: campaign, distinctId: user, originEventId: nil)
          await Task.yield()

          expect(journey).toNot(beNil())
          let journeyId = journey!.id

          // Verify the journey executed the expected error path through spy introspection
          spy.assertPath(["branch", "delegate_false", "exit"], for: journeyId)

          // Verify branch node execution - should default to false path on error
          spy.assertNodeExecuted("branch", in: journeyId, withResult: .continue(["delegate_false"]))
          spy.assertNodeExecuted("delegate_false", in: journeyId)
          spy.assertNodeExecuted("exit", in: journeyId, withResult: .complete(.completed))

          // Verify delegate was called for the false branch (error default)
          spy.assertDelegateCalled("false-branch-taken", for: journeyId)

          // Verify the true branch was not taken
          expect(spy.wasNodeExecuted("delegate_true", in: journeyId)).to(beFalse())

          // Verify journey completed successfully despite evaluation error by checking the journey object directly
          expect(journey!.status).to(equal(.completed))
          expect(journey!.exitReason).to(equal(.completed))
        }
      }
    }
  }
}
