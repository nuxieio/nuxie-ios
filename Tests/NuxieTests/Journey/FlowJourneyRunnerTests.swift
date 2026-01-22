import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie

final class FlowJourneyRunnerTests: AsyncSpec {
    override class func spec() {
        var mocks: MockFactory!

        beforeEach {
            mocks = MockFactory.shared
            mocks.registerAll()
        }

        func makeCampaign(flowId: String) -> Campaign {
            let publishedAt = ISO8601DateFormatter().string(from: Date())
            return Campaign(
                id: "camp-1",
                name: "Test Campaign",
                versionId: "v1",
                versionNumber: 1,
                versionName: nil,
                reentry: .oneTime,
                publishedAt: publishedAt,
                trigger: .event(EventTriggerConfig(eventName: "test_event", condition: nil)),
                flowId: flowId,
                goal: nil,
                exitPolicy: nil,
                conversionAnchor: nil,
                campaignType: nil
            )
        }

        func makeFlowDescription(
            flowId: String,
            entryActions: [InteractionAction]? = nil,
            interactionsByScreen: [String: [Interaction]] = [:],
            viewModels: [ViewModel] = [],
            viewModelInstances: [ViewModelInstance]? = nil
        ) -> FlowDescription {
            return FlowDescription(
                id: flowId,
                version: "v1",
                bundle: FlowBundleRef(
                    url: "https://example.com/flow/\(flowId)",
                    manifest: BuildManifest(
                        totalFiles: 1,
                        totalSize: 100,
                        contentHash: "test-hash",
                        files: [BuildFile(path: "index.html", size: 100, contentType: "text/html")]
                    )
                ),
                entryScreenId: "screen-1",
                entryActions: entryActions,
                screens: [
                    FlowDescriptionScreen(
                        id: "screen-1",
                        name: nil,
                        locale: nil,
                        route: nil,
                        defaultViewModelId: viewModels.first?.id,
                        defaultInstanceId: nil
                    )
                ],
                interactions: FlowDescriptionInteractions(
                    screens: interactionsByScreen,
                    components: nil
                ),
                viewModels: viewModels,
                viewModelInstances: viewModelInstances,
                converters: nil,
                pathIndex: nil
            )
        }

        describe("FlowJourneyRunner") {
            it("pauses on entry delay") {
                let flowId = "flow-delay"
                let flowDescription = makeFlowDescription(
                    flowId: flowId,
                    entryActions: [
                        .delay(DelayAction(durationMs: 5000))
                    ]
                )
                let flow = Flow(description: flowDescription, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                let outcome = await runner.handleRuntimeReady()

                var paused = false
                if case .paused(let pending) = outcome {
                    paused = (pending.kind == .delay)
                }

                expect(paused).to(beTrue())
                expect(journey.flowState.pendingAction?.kind).to(equal(.delay))
            }

            it("applies set_view_model on screen shown and emits patch") {
                let flowId = "flow-vm"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    properties: [
                        "flag": ViewModelProperty(
                            type: .boolean,
                            propertyId: 1,
                            defaultValue: AnyCodable(false),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let interaction = Interaction(
                    id: "int-1",
                    trigger: .screenShown,
                    actions: [
                        .setViewModel(SetViewModelAction(
                            path: .path("vm.flag"),
                            value: AnyCodable(["literal": true] as [String: Any])
                        ))
                    ],
                    enabled: true
                )
                let flowDescription = makeFlowDescription(
                    flowId: flowId,
                    interactionsByScreen: ["screen-1": [interaction]],
                    viewModels: [viewModel]
                )

                let flow = Flow(description: flowDescription, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                let controller = await MainActor.run {
                    SpyFlowViewController(flow: flow)
                }
                runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-1")

                let snapshot = journey.flowState.viewModelSnapshot
                let values = snapshot?.viewModelInstances.first?.values
                let flag = values?["flag"]?.value as? Bool
                expect(flag).to(equal(true))

                await expect(controller.messages.map(\.type)).toEventually(contain("runtime/view_model_patch"))
            }

            it("handles list_insert and fire_trigger actions") {
                let flowId = "flow-list"
                let listProperty = ViewModelProperty(
                    type: .list,
                    propertyId: 2,
                    defaultValue: AnyCodable([]),
                    required: nil,
                    enumValues: nil,
                    itemType: ViewModelProperty(
                        type: .string,
                        propertyId: 3,
                        defaultValue: nil,
                        required: nil,
                        enumValues: nil,
                        itemType: nil,
                        schema: nil,
                        viewModelId: nil,
                        validation: nil
                    ),
                    schema: nil,
                    viewModelId: nil,
                    validation: nil
                )
                let triggerProperty = ViewModelProperty(
                    type: .trigger,
                    propertyId: 4,
                    defaultValue: nil,
                    required: nil,
                    enumValues: nil,
                    itemType: nil,
                    schema: nil,
                    viewModelId: nil,
                    validation: nil
                )
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    properties: [
                        "items": listProperty,
                        "pulse": triggerProperty
                    ]
                )
                let interaction = Interaction(
                    id: "int-1",
                    trigger: .screenShown,
                    actions: [
                        .listInsert(ListInsertAction(
                            path: .path("vm.items"),
                            index: 0,
                            value: AnyCodable(["literal": "a"] as [String: Any])
                        )),
                        .fireTrigger(FireTriggerAction(path: .path("vm.pulse")))
                    ],
                    enabled: true
                )
                let flowDescription = makeFlowDescription(
                    flowId: flowId,
                    interactionsByScreen: ["screen-1": [interaction]],
                    viewModels: [viewModel]
                )

                let flow = Flow(description: flowDescription, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                let controller = await MainActor.run {
                    SpyFlowViewController(flow: flow)
                }
                runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-1")

                let snapshot = journey.flowState.viewModelSnapshot
                let values = snapshot?.viewModelInstances.first?.values
                let items = values?["items"]?.value as? [Any]
                expect(items?.first as? String).to(equal("a"))

                await expect(controller.messages.map(\.type)).toEventually(contain("runtime/view_model_list_insert"))
                await expect(controller.messages.map(\.type)).toEventually(contain("runtime/view_model_trigger"))
            }
        }
    }
}

private final class SpyFlowViewController: FlowViewController {
    struct Message {
        let type: String
        let payload: [String: Any]
    }

    private(set) var messages: [Message] = []

    init(flow: Flow) {
        super.init(flow: flow, archiveService: FlowArchiver())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func sendRuntimeMessage(
        type: String,
        payload: [String: Any] = [:],
        replyTo: String? = nil,
        completion: ((Any?, Error?) -> Void)? = nil
    ) {
        messages.append(Message(type: type, payload: payload))
    }
}
