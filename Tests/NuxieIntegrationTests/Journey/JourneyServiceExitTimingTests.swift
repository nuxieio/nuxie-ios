import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie

final class JourneyServiceExitTimingTests: AsyncSpec {
    override class func spec() {
        var mocks: MockFactory!
        var journeyStore: MockJourneyStore!
        var service: JourneyService!
        var controller: MockFlowViewController!

        let distinctId = "user_1"
        let flowId = "flow-exit-timing"
        let campaignId = "camp-exit-timing"

        func makeCampaign(goal: GoalConfig?, exitPolicy: ExitPolicy?) -> Campaign {
            Campaign(
                id: campaignId,
                name: "Exit Timing Campaign",
                flowId: flowId,
                flowNumber: 1,
                flowName: nil,
                reentry: .everyTime,
                publishedAt: Date().ISO8601Format(),
                trigger: .event(EventTriggerConfig(eventName: "paywall_trigger", condition: nil)),
                goal: goal,
                exitPolicy: exitPolicy,
                conversionAnchor: nil,
                campaignType: nil
            )
        }

        func makeFlow(interactions: [String: [Interaction]] = [:]) -> Flow {
            let remoteFlow = RemoteFlow(
                id: flowId,
                bundle: FlowBundleRef(
                    url: "https://example.com/flow/\(flowId)",
                    manifest: BuildManifest(
                        totalFiles: 1,
                        totalSize: 100,
                        contentHash: "test-hash",
                        files: [BuildFile(path: "index.html", size: 100, contentType: "text/html")]
                    )
                ),
                screens: [
                    RemoteFlowScreen(
                        id: "screen-1",
                        defaultViewModelId: nil,
                        defaultInstanceId: nil
                    )
                ],
                interactions: interactions,
                viewModels: [],
                viewModelInstances: nil,
                converters: nil,
            )
            return Flow(remoteFlow: remoteFlow, products: [])
        }

        func primeProfile(campaign: Campaign, flow: Flow) async {
            mocks.identityService.setDistinctId(distinctId)
            mocks.flowService.mockFlows[flowId] = flow
            mocks.profileService.setProfileResponse(
                ResponseBuilders.buildProfileResponse(
                    campaigns: [campaign],
                    flows: [flow.remoteFlow]
                )
            )
            _ = try? await mocks.profileService.fetchProfile(distinctId: distinctId)
        }

        func startJourney() async -> Journey {
            let startEvent = NuxieEvent(
                id: "evt_origin",
                name: "paywall_trigger",
                distinctId: distinctId
            )
            let results = await service.handleEventForTrigger(startEvent)
            return results.compactMap { result -> Journey? in
                if case .started(let journey) = result {
                    return journey
                }
                return nil
            }.first!
        }

        beforeEach { @MainActor in
            mocks = MockFactory.shared
            mocks.registerAll()
            mocks.dateProvider.setCurrentDate(Date())

            journeyStore = MockJourneyStore()
            service = JourneyService(journeyStore: journeyStore)

            controller = MockFlowViewController(mockFlowId: flowId)
            mocks.flowPresentationService.defaultMockViewController = controller
        }

        describe("exit deferral during active flow presentation") {
            it("keeps goal-met journeys live until dismiss, then exits as goal_met") {
                let campaign = makeCampaign(
                    goal: GoalConfig(kind: .segmentEnter, segmentId: "goal-segment"),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                await mocks.segmentService.setMembership("goal-segment", isMember: true)
                _ = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_noop", name: "noop_event", distinctId: distinctId)
                )

                let activeJourneys = await service.getActiveJourneys(for: distinctId)
                expect(activeJourneys.map(\.id)).to(equal([journey.id]))
                expect(activeJourneys.first?.convertedAt).toNot(beNil())
                expect(journeyStore.getCompletions(for: distinctId)).to(beEmpty())

                let dismissController = controller!
                await MainActor.run {
                    dismissController.runtimeDelegate?.flowViewControllerDidRequestDismiss(
                        dismissController,
                        reason: .userDismissed
                    )
                }

                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.goalMet), timeout: .seconds(2))
                await expect {
                    await service.getActiveJourneys(for: distinctId).count
                }.toEventually(equal(0), timeout: .seconds(2))
            }

            it("reevaluates goals triggered by dismiss interactions before falling back to dismissed") {
                let dismissGoal = Interaction(
                    id: "dismiss-goal",
                    trigger: .event(eventName: SystemEventNames.screenDismissed, filter: nil),
                    actions: [
                        .updateCustomer(
                            UpdateCustomerAction(attributes: ["dismissed": AnyCodable(true)])
                        )
                    ],
                    enabled: true
                )
                let campaign = makeCampaign(
                    goal: GoalConfig(
                        kind: .attribute,
                        attributeExpr: IREnvelope(
                            ir_version: 1,
                            engine_min: nil,
                            compiled_at: nil,
                            expr: .user(op: "eq", key: "dismissed", value: .bool(true))
                        )
                    ),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeFlow(interactions: ["__global__": [dismissGoal]])
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                _ = await startJourney()
                let activeJourneys = await service.getActiveJourneys(for: distinctId)
                expect(activeJourneys.first?.convertedAt).to(beNil())

                let dismissController = controller!
                await MainActor.run {
                    dismissController.runtimeDelegate?.flowViewControllerDidRequestDismiss(
                        dismissController,
                        reason: .userDismissed
                    )
                }

                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.goalMet), timeout: .seconds(2))
                expect(journeyStore.getCompletions(for: distinctId).last?.exitReason).toNot(equal(.dismissed))
            }
        }
    }
}
