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
                flowId: flowId,
                flowNumber: 1,
                flowName: nil,
                reentry: .oneTime,
                publishedAt: publishedAt,
                trigger: .event(EventTriggerConfig(eventName: "test_event", condition: nil)),
                goal: nil,
                exitPolicy: nil,
                conversionAnchor: nil,
                campaignType: nil
            )
        }

        func makeRemoteFlow(
            flowId: String,
            entryActions: [InteractionAction]? = nil,
            interactionsByScreen: [String: [Interaction]] = [:],
            viewModels: [ViewModel] = [],
            viewModelInstances: [ViewModelInstance]? = nil,
            screens: [RemoteFlowScreen]? = nil
        ) -> RemoteFlow {
            var interactions = interactionsByScreen
            if let entryActions, !entryActions.isEmpty {
                interactions["__global__"] = [
                    Interaction(
                        id: "start",
                        trigger: .start(config: nil),
                        actions: entryActions,
                        enabled: true
                    )
                ]
            }
            let resolvedScreens = screens ?? [
                RemoteFlowScreen(
                    id: "screen-1",
                    defaultViewModelId: viewModels.first?.id,
                    defaultInstanceId: nil
                )
            ]

            return RemoteFlow(
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
                screens: resolvedScreens,
                interactions: interactions,
                viewModels: viewModels,
                viewModelInstances: viewModelInstances,
                converters: nil,
            )
        }

        func nameId(_ value: String) -> Int {
            let fnvOffsetBasis: UInt32 = 0x811c9dc5
            let fnvPrime: UInt32 = 0x01000193
            if value.isEmpty { return Int(fnvOffsetBasis) }
            var hash = fnvOffsetBasis
            for byte in value.utf8 {
                hash ^= UInt32(byte)
                hash = hash &* fnvPrime
            }
            return Int(hash)
        }

        describe("FlowJourneyRunner") {
            it("pauses on entry delay") {
                let flowId = "flow-delay"
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [
                        .delay(DelayAction(durationMs: 5000))
                    ]
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
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

            it("dispatches global event interactions") {
                let flowId = "flow-global-event"
                let interaction = Interaction(
                    id: "int-global",
                    trigger: .event(eventName: "promo_ready", filter: nil),
                    actions: [.navigate(NavigateAction(screenId: "screen-2", transition: nil))],
                    enabled: true
                )
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    interactionsByScreen: ["__global__": [interaction]],
                    screens: [
                        RemoteFlowScreen(id: "screen-1", defaultViewModelId: nil, defaultInstanceId: nil),
                        RemoteFlowScreen(id: "screen-2", defaultViewModelId: nil, defaultInstanceId: nil),
                    ]
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                journey.flowState.currentScreenId = "screen-1"
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                let controller = await MainActor.run {
                    SpyFlowViewController(flow: flow)
                }
                runner.attach(viewController: controller)

                _ = await runner.dispatchTrigger(
                    trigger: .event(eventName: "promo_ready", filter: nil),
                    screenId: "screen-1",
                    componentId: nil,
                    instanceId: nil,
                    event: nil
                )

                await expect(controller.messages.map(\.type)).toEventually(contain("runtime/navigate"))
                let navigatePayload = controller.messages.first(where: { $0.type == "runtime/navigate" })?.payload
                expect(navigatePayload?["screenId"] as? String).to(equal("screen-2"))
            }

            it("dispatches global did_set interactions") {
                let flowId = "flow-global-did-set"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "pulse": ViewModelProperty(
                            type: .trigger,
                            propertyId: 1,
                            defaultValue: AnyCodable(0),
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
                    id: "int-global-did-set",
                    trigger: .didSet(path: .ids(VmPathIds(pathIds: [0, 1])), debounceMs: nil),
                    actions: [.navigate(NavigateAction(screenId: "screen-2", transition: nil))],
                    enabled: true
                )
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    interactionsByScreen: ["__global__": [interaction]],
                    viewModels: [viewModel],
                    screens: [
                        RemoteFlowScreen(id: "screen-1", defaultViewModelId: "vm-1", defaultInstanceId: nil),
                        RemoteFlowScreen(id: "screen-2", defaultViewModelId: "vm-1", defaultInstanceId: nil),
                    ]
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                journey.flowState.currentScreenId = "screen-1"
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                let controller = await MainActor.run {
                    SpyFlowViewController(flow: flow)
                }
                runner.attach(viewController: controller)

                _ = await runner.handleDidSet(
                    path: .ids(VmPathIds(pathIds: [0, 1])),
                    value: 1,
                    source: "runtime",
                    screenId: "screen-1",
                    instanceId: nil
                )

                await expect(controller.messages.map(\.type)).toEventually(contain("runtime/navigate"))
                let navigatePayload = controller.messages.first(where: { $0.type == "runtime/navigate" })?.payload
                expect(navigatePayload?["screenId"] as? String).to(equal("screen-2"))
            }

            it("applies set_view_model on screen shown and emits patch") {
                let flowId = "flow-vm"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
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
                    trigger: .event(eventName: SystemEventNames.screenShown, filter: nil),
                    actions: [
                        .setViewModel(SetViewModelAction(
                            path: .ids(VmPathIds(pathIds: [0, 1])),
                            value: AnyCodable(["literal": true] as [String: Any])
                        ))
                    ],
                    enabled: true
                )
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    interactionsByScreen: ["screen-1": [interaction]],
                    viewModels: [viewModel]
                )

                let flow = Flow(remoteFlow: remoteFlow, products: [])
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
                    viewModelPathId: 0,
                    properties: [
                        "items": listProperty,
                        "pulse": triggerProperty
                    ]
                )
                let interaction = Interaction(
                    id: "int-1",
                    trigger: .event(eventName: SystemEventNames.screenShown, filter: nil),
                    actions: [
                        .listInsert(ListInsertAction(
                            path: .ids(VmPathIds(pathIds: [0, 2])),
                            index: 0,
                            value: AnyCodable(["literal": "a"] as [String: Any])
                        )),
                        .fireTrigger(FireTriggerAction(path: .ids(VmPathIds(pathIds: [0, 4]))))
                    ],
                    enabled: true
                )
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    interactionsByScreen: ["screen-1": [interaction]],
                    viewModels: [viewModel]
                )

                let flow = Flow(remoteFlow: remoteFlow, products: [])
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

            it("handles list_move, list_set, and list_clear actions") {
                let flowId = "flow-list-ops"
                let listProperty = ViewModelProperty(
                    type: .list,
                    propertyId: 2,
                    defaultValue: AnyCodable(["a", "b", "c"]),
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
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "items": listProperty
                    ]
                )
                let interaction = Interaction(
                    id: "int-ops",
                    trigger: .event(eventName: SystemEventNames.screenShown, filter: nil),
                    actions: [
                        .listMove(ListMoveAction(
                            path: .ids(VmPathIds(pathIds: [0, 2])),
                            from: 0,
                            to: 2
                        )),
                        .listSet(ListSetAction(
                            path: .ids(VmPathIds(pathIds: [0, 2])),
                            index: 1,
                            value: AnyCodable(["literal": "z"] as [String: Any])
                        )),
                        .listClear(ListClearAction(path: .ids(VmPathIds(pathIds: [0, 2]))))
                    ],
                    enabled: true
                )
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    interactionsByScreen: ["screen-1": [interaction]],
                    viewModels: [viewModel]
                )

                let flow = Flow(remoteFlow: remoteFlow, products: [])
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
                expect(items?.isEmpty).to(equal(true))

                await expect(controller.messages.map(\.type)).toEventually(contain("runtime/view_model_list_move"))
                await expect(controller.messages.map(\.type)).toEventually(contain("runtime/view_model_list_set"))
                await expect(controller.messages.map(\.type)).toEventually(contain("runtime/view_model_list_clear"))
            }

            it("executes system actions on screen shown") {
                let flowId = "flow-system-actions"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "selectedProductId": ViewModelProperty(
                            type: .string,
                            propertyId: 1,
                            defaultValue: nil,
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        ),
                        "selectedIndex": ViewModelProperty(
                            type: .number,
                            propertyId: 2,
                            defaultValue: nil,
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let instance = ViewModelInstance(
                    viewModelId: "vm-1",
                    instanceId: "vmi-1",
                    name: "Default",
                    values: [
                        "selectedProductId": AnyCodable("prod_1"),
                        "selectedIndex": AnyCodable(2)
                    ]
                )
                let viewModelNameId = nameId(viewModel.name)
                let productNameId = nameId("selectedProductId")
                let indexNameId = nameId("selectedIndex")
                let purchaseAction = InteractionAction.purchase(
                    PurchaseAction(
                        placementIndex: AnyCodable([
                            "ref": [
                                "pathIds": [viewModelNameId, indexNameId],
                                "nameBased": true
                            ]
                        ]),
                        productId: AnyCodable([
                            "ref": [
                                "pathIds": [viewModelNameId, productNameId],
                                "nameBased": true
                            ]
                        ])
                    )
                )
                let interaction = Interaction(
                    id: "int-1",
                    trigger: .event(eventName: SystemEventNames.screenShown, filter: nil),
                    actions: [
                        purchaseAction,
                        .restore(RestoreAction()),
                        .openLink(OpenLinkAction(url: AnyCodable("https://example.com"), target: "external")),
                        .dismiss(DismissAction())
                    ],
                    enabled: true
                )
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    interactionsByScreen: ["screen-1": [interaction]],
                    viewModels: [viewModel],
                    viewModelInstances: [instance]
                )

                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                let controller = await MainActor.run {
                    SpyFlowViewController(flow: flow)
                }
                runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-1")

                expect(controller.purchaseRequests.map(\.productId)).to(equal(["prod_1"]))
                expect(controller.purchaseRequests.first?.placementIndex as? Int).to(equal(2))
                expect(controller.restoreRequests).to(equal(1))
                expect(controller.openLinkRequests.map(\.urlString)).to(equal(["https://example.com"]))
                expect(controller.dismissRequests).to(equal([.userDismissed]))
            }

            it("resumes delayed entry action and continues sequence") {
                let flowId = "flow-resume"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
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
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [
                        .delay(DelayAction(durationMs: 500)),
                        .setViewModel(SetViewModelAction(
                            path: .ids(VmPathIds(pathIds: [0, 1])),
                            value: AnyCodable(["literal": true] as [String: Any])
                        ))
                    ],
                    viewModels: [viewModel]
                )

                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                let outcome = await runner.handleRuntimeReady()
                var paused = false
                if case .paused(let pending) = outcome {
                    paused = (pending.kind == .delay)
                }
                expect(paused).to(beTrue())

                _ = await runner.resumePendingAction(reason: .timer, event: nil)

                let snapshot = journey.flowState.viewModelSnapshot
                let values = snapshot?.viewModelInstances.first?.values
                let flag = values?["flag"]?.value as? Bool
                expect(flag).to(equal(true))
                expect(journey.flowState.pendingAction).to(beNil())
            }

            it("pauses on time_window when outside configured hours") {
                let flowId = "flow-time-window"
                let action = TimeWindowAction(
                    startTime: "09:00",
                    endTime: "17:00",
                    timezone: "UTC",
                    daysOfWeek: nil
                )
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [.timeWindow(action)]
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
                let date = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 2, minute: 0))!
                mocks.dateProvider.setCurrentDate(date)

                let outcome = await runner.handleRuntimeReady()

                if case .paused(let pending) = outcome {
                    expect(pending.kind).to(equal(.timeWindow))
                    expect(pending.resumeAt).toNot(beNil())
                } else {
                    fail("Expected time_window to pause")
                }
            }

            it("continues on time_window when inside configured hours") {
                let flowId = "flow-time-window-in"
                let action = TimeWindowAction(
                    startTime: "09:00",
                    endTime: "17:00",
                    timezone: "UTC",
                    daysOfWeek: nil
                )
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [.timeWindow(action)]
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
                let date = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 10, minute: 0))!
                mocks.dateProvider.setCurrentDate(date)

                _ = await runner.handleRuntimeReady()

                expect(journey.flowState.pendingAction).to(beNil())
            }

            it("resumes wait_until when event condition is satisfied") {
                let flowId = "flow-wait"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
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
                let waitAction = WaitUntilAction(
                    condition: TestWaitCondition.event("ready"),
                    maxTimeMs: 10_000
                )
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [
                        .waitUntil(waitAction),
                        .setViewModel(SetViewModelAction(
                            path: .ids(VmPathIds(pathIds: [0, 1])),
                            value: AnyCodable(["literal": true] as [String: Any])
                        ))
                    ],
                    viewModels: [viewModel]
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                let outcome = await runner.handleRuntimeReady()
                if case .paused(let pending) = outcome {
                    expect(pending.kind).to(equal(.waitUntil))
                } else {
                    fail("Expected wait_until to pause")
                }

                let event = TestEventBuilder(name: "ready").withDistinctId("user-1").build()
                _ = await runner.resumePendingAction(reason: .event(event), event: event)

                let snapshot = journey.flowState.viewModelSnapshot
                let values = snapshot?.viewModelInstances.first?.values
                let flag = values?["flag"]?.value as? Bool
                expect(flag).to(equal(true))
                expect(journey.flowState.pendingAction).to(beNil())
            }

            it("continues wait_until after maxTimeMs deadline") {
                let flowId = "flow-wait-deadline"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
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
                let waitAction = WaitUntilAction(
                    condition: TestWaitCondition.expression("false"),
                    maxTimeMs: 1_000
                )
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [
                        .waitUntil(waitAction),
                        .setViewModel(SetViewModelAction(
                            path: .ids(VmPathIds(pathIds: [0, 1])),
                            value: AnyCodable(["literal": true] as [String: Any])
                        ))
                    ],
                    viewModels: [viewModel]
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
                let start = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 0, minute: 0, second: 0))!
                mocks.dateProvider.setCurrentDate(start)

                let outcome = await runner.handleRuntimeReady()
                guard case .paused(let pending) = outcome else {
                    fail("Expected wait_until to pause")
                    return
                }
                expect(pending.kind).to(equal(.waitUntil))
                expect(pending.resumeAt).toNot(beNil())

                mocks.dateProvider.setCurrentDate(start.addingTimeInterval(2.0))
                _ = await runner.resumePendingAction(reason: .timer, event: nil)

                let snapshot = journey.flowState.viewModelSnapshot
                let values = snapshot?.viewModelInstances.first?.values
                let flag = values?["flag"]?.value as? Bool
                expect(flag).to(equal(true))
                expect(journey.flowState.pendingAction).to(beNil())
            }

            it("executes the first matching condition branch") {
                let flowId = "flow-condition"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "variant": ViewModelProperty(
                            type: .string,
                            propertyId: 1,
                            defaultValue: AnyCodable("none"),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let branchA = ConditionBranch(
                    id: "branch-a",
                    label: nil,
                    condition: TestIRBuilder.alwaysFalse(),
                    actions: [
                        .setViewModel(SetViewModelAction(
                            path: .ids(VmPathIds(pathIds: [0, 1])),
                            value: AnyCodable(["literal": "a"] as [String: Any])
                        ))
                    ]
                )
                let branchB = ConditionBranch(
                    id: "branch-b",
                    label: nil,
                    condition: TestIRBuilder.alwaysTrue(),
                    actions: [
                        .setViewModel(SetViewModelAction(
                            path: .ids(VmPathIds(pathIds: [0, 1])),
                            value: AnyCodable(["literal": "b"] as [String: Any])
                        ))
                    ]
                )
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [
                        .condition(ConditionAction(branches: [branchA, branchB]))
                    ],
                    viewModels: [viewModel]
                )

                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                _ = await runner.handleRuntimeReady()

                let snapshot = journey.flowState.viewModelSnapshot
                let values = snapshot?.viewModelInstances.first?.values
                let variant = values?["variant"]?.value as? String
                expect(variant).to(equal("b"))
            }

            it("applies experiment variant from profile assignment") {
                let flowId = "flow-experiment"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "variant": ViewModelProperty(
                            type: .string,
                            propertyId: 1,
                            defaultValue: AnyCodable("none"),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let variantA = ExperimentVariant(
                    id: "a",
                    name: "A",
                    percentage: 50,
                    actions: [
                        .setViewModel(SetViewModelAction(
                            path: .ids(VmPathIds(pathIds: [0, 1])),
                            value: AnyCodable(["literal": "a"] as [String: Any])
                        ))
                    ]
                )
                let variantB = ExperimentVariant(
                    id: "b",
                    name: "B",
                    percentage: 50,
                    actions: [
                        .setViewModel(SetViewModelAction(
                            path: .ids(VmPathIds(pathIds: [0, 1])),
                            value: AnyCodable(["literal": "b"] as [String: Any])
                        ))
                    ]
                )

                let experiment = ExperimentAction(
                    experimentId: "exp-1",
                    variants: [variantA, variantB]
                )

                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [.experiment(experiment)],
                    viewModels: [viewModel]
                )

                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                let assignment = ExperimentAssignment(
                    experimentKey: "exp-1",
                    variantKey: "b",
                    status: "running",
                    isHoldout: false
                )
                let profile = ProfileResponse(
                    campaigns: [],
                    segments: [],
                    flows: [],
                    userProperties: nil,
                    experiments: ["exp-1": assignment],
                    features: nil,
                    journeys: nil
                )
                mocks.profileService.setProfileResponse(profile)
                _ = try? await mocks.profileService.fetchProfile(distinctId: journey.distinctId)

                _ = await runner.handleRuntimeReady()

                let snapshot = journey.flowState.viewModelSnapshot
                let values = snapshot?.viewModelInstances.first?.values
                let variant = values?["variant"]?.value as? String
                expect(variant).to(equal("b"))
                expect(journey.context["_experiment_key"]?.value as? String).to(equal("exp-1"))
                expect(journey.context["_variant_key"]?.value as? String).to(equal("b"))
            }

            it("does not freeze experiment variant key without a running assignment") {
                let flowId = "flow-experiment-freeze-non-running"
                let variantA = ExperimentVariant(
                    id: "a",
                    name: "A",
                    percentage: 50,
                    actions: []
                )
                let variantB = ExperimentVariant(
                    id: "b",
                    name: "B",
                    percentage: 50,
                    actions: []
                )

                let experiment = ExperimentAction(
                    experimentId: "exp-1",
                    variants: [variantA, variantB]
                )

                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [.experiment(experiment)]
                )

                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                // No cached profile => no assignment => should not freeze fallback variant.
                _ = await runner.handleRuntimeReady()

                expect(journey.getContext("_experiment_variants")).to(beNil())
            }

            it("freezes experiment variant key when assignment is running and matches") {
                let flowId = "flow-experiment-freeze-running"
                let variantA = ExperimentVariant(
                    id: "a",
                    name: "A",
                    percentage: 50,
                    actions: []
                )
                let variantB = ExperimentVariant(
                    id: "b",
                    name: "B",
                    percentage: 50,
                    actions: []
                )

                let experiment = ExperimentAction(
                    experimentId: "exp-1",
                    variants: [variantA, variantB]
                )

                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [.experiment(experiment)]
                )

                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                let assignment = ExperimentAssignment(
                    experimentKey: "exp-1",
                    variantKey: "b",
                    status: "running",
                    isHoldout: false
                )
                let profile = ProfileResponse(
                    campaigns: [],
                    segments: [],
                    flows: [],
                    userProperties: nil,
                    experiments: ["exp-1": assignment],
                    features: nil,
                    journeys: nil
                )
                mocks.profileService.setProfileResponse(profile)
                _ = try? await mocks.profileService.fetchProfile(distinctId: journey.distinctId)

                _ = await runner.handleRuntimeReady()

                let frozen =
                    journey.getContext("_experiment_variants") as? [String: Any]
                expect(frozen?["exp-1"] as? String).to(equal("b"))
            }

            it("tracks experiment exposure for running assignment") {
                let flowId = "flow-experiment-exposure"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "variant": ViewModelProperty(
                            type: .string,
                            propertyId: 1,
                            defaultValue: AnyCodable("none"),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let variantA = ExperimentVariant(
                    id: "a",
                    name: "A",
                    percentage: 50,
                    actions: [
                        .setViewModel(SetViewModelAction(
                            path: .ids(VmPathIds(pathIds: [0, 1])),
                            value: AnyCodable(["literal": "a"] as [String: Any])
                        ))
                    ]
                )
                let variantB = ExperimentVariant(
                    id: "b",
                    name: "B",
                    percentage: 50,
                    actions: [
                        .setViewModel(SetViewModelAction(
                            path: .ids(VmPathIds(pathIds: [0, 1])),
                            value: AnyCodable(["literal": "b"] as [String: Any])
                        ))
                    ]
                )

                let experiment = ExperimentAction(
                    experimentId: "exp-1",
                    variants: [variantA, variantB]
                )

                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [.experiment(experiment)],
                    viewModels: [viewModel]
                )

                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                let assignment = ExperimentAssignment(
                    experimentKey: "exp-1",
                    variantKey: "b",
                    status: "running",
                    isHoldout: true
                )
                let profile = ProfileResponse(
                    campaigns: [],
                    segments: [],
                    flows: [],
                    userProperties: nil,
                    experiments: ["exp-1": assignment],
                    features: nil,
                    journeys: nil
                )
                mocks.profileService.setProfileResponse(profile)
                _ = try? await mocks.profileService.fetchProfile(distinctId: journey.distinctId)

                _ = await runner.handleRuntimeReady()

                let exposure = mocks.eventService.trackedEvents.first {
                    $0.name == JourneyEvents.experimentExposure
                }
                expect(exposure).toNot(beNil())
                let props = exposure?.properties ?? [:]
                expect(props["experiment_key"] as? String).to(equal("exp-1"))
                expect(props["variant_key"] as? String).to(equal("b"))
                expect(props["campaign_id"] as? String).to(equal("camp-1"))
                expect(props["flow_id"] as? String).to(equal(flowId))
                expect(props["journey_id"] as? String).to(equal(journey.id))
                expect(props["is_holdout"] as? Bool).to(beTrue())
            }

            it("tracks experiment exposure errors for missing variants") {
                let flowId = "flow-experiment-missing"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "variant": ViewModelProperty(
                            type: .string,
                            propertyId: 1,
                            defaultValue: AnyCodable("none"),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let variantA = ExperimentVariant(
                    id: "a",
                    name: "A",
                    percentage: 50,
                    actions: []
                )
                let variantB = ExperimentVariant(
                    id: "b",
                    name: "B",
                    percentage: 50,
                    actions: []
                )

                let experiment = ExperimentAction(
                    experimentId: "exp-1",
                    variants: [variantA, variantB]
                )

                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [.experiment(experiment)],
                    viewModels: [viewModel]
                )

                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                let assignment = ExperimentAssignment(
                    experimentKey: "exp-1",
                    variantKey: "missing",
                    status: "running",
                    isHoldout: false
                )
                let profile = ProfileResponse(
                    campaigns: [],
                    segments: [],
                    flows: [],
                    userProperties: nil,
                    experiments: ["exp-1": assignment],
                    features: nil,
                    journeys: nil
                )
                mocks.profileService.setProfileResponse(profile)
                _ = try? await mocks.profileService.fetchProfile(distinctId: journey.distinctId)

                _ = await runner.handleRuntimeReady()

                let errorEvent = mocks.eventService.trackedEvents.first {
                    $0.name == "$experiment_exposure_error"
                }
                expect(errorEvent).toNot(beNil())
                let props = errorEvent?.properties ?? [:]
                expect(props["experiment_key"] as? String).to(equal("exp-1"))
                expect(props["variant_key"] as? String).to(equal("missing"))
                expect(props["reason"] as? String).to(equal("variant_not_found"))

                let trackedNames = mocks.eventService.trackedEvents.map(\.name)
                expect(trackedNames).toNot(contain(JourneyEvents.experimentExposure))
            }

            it("updates context from remote action success") {
                let flowId = "flow-remote"
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [
                        .remote(RemoteAction(
                            action: "do_work",
                            payload: AnyCodable(["key": "value"] as [String: Any]),
                            async: false
                        ))
                    ]
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                let execution = EventResponse.ExecutionResult(
                    success: true,
                    statusCode: nil,
                    error: nil,
                    contextUpdates: ["flag": AnyCodable(true)]
                )
                mocks.eventService.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: nil,
                    customer: nil,
                    event: nil,
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil,
                    execution: execution
                )

                _ = await runner.handleRuntimeReady()

                let flag = journey.context["flag"]?.value as? Bool
                expect(flag).to(equal(true))
            }

            it("pauses on remote action retryable error") {
                let flowId = "flow-remote-retry"
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [
                        .remote(RemoteAction(
                            action: "do_work",
                            payload: AnyCodable(["key": "value"] as [String: Any]),
                            async: false
                        ))
                    ]
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                let execution = EventResponse.ExecutionResult(
                    success: false,
                    statusCode: 500,
                    error: EventResponse.ExecutionResult.ExecutionError(
                        message: "retry later",
                        retryable: true,
                        retryAfter: 5
                    ),
                    contextUpdates: nil
                )
                mocks.eventService.trackWithResponseResult = EventResponse(
                    status: "error",
                    payload: nil,
                    customer: nil,
                    event: nil,
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil,
                    execution: execution
                )

                let outcome = await runner.handleRuntimeReady()

                if case .paused(let pending) = outcome {
                    expect(pending.kind).to(equal(.remoteRetry))
                    expect(pending.resumeAt).toNot(beNil())
                } else {
                    fail("Expected remote retry to pause")
                }
            }

            it("uses explicit back transitions when provided") {
                let flowId = "flow-back-transition"
                let transition = AnyCodable(["type": "push", "direction": "left"])
                let interaction = Interaction(
                    id: "int-back",
                    trigger: .event(eventName: SystemEventNames.screenShown, filter: nil),
                    actions: [.back(BackAction(steps: 1, transition: transition))],
                    enabled: true
                )
                let screens = [
                    RemoteFlowScreen(id: "screen-1", defaultViewModelId: nil, defaultInstanceId: nil),
                    RemoteFlowScreen(id: "screen-2", defaultViewModelId: nil, defaultInstanceId: nil)
                ]
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    interactionsByScreen: ["screen-2": [interaction]],
                    screens: screens
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                journey.flowState.navigationStack = ["screen-1"]
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                let controller = await MainActor.run {
                    SpyFlowViewController(flow: flow)
                }
                runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-2")

                await expect(controller.messages.map(\.type)).toEventually(contain("runtime/navigate"))
                let payload = controller.messages.last?.payload
                let transitionPayload = payload?["transition"] as? [String: Any]
                expect(payload?["screenId"] as? String).to(equal("screen-1"))
                expect(transitionPayload?["type"] as? String).to(equal("push"))
                expect(transitionPayload?["direction"] as? String).to(equal("left"))
            }

            it("omits back transitions when not configured") {
                let flowId = "flow-back-no-transition"
                let interaction = Interaction(
                    id: "int-back",
                    trigger: .event(eventName: SystemEventNames.screenShown, filter: nil),
                    actions: [.back(BackAction(steps: 1))],
                    enabled: true
                )
                let screens = [
                    RemoteFlowScreen(id: "screen-1", defaultViewModelId: nil, defaultInstanceId: nil),
                    RemoteFlowScreen(id: "screen-2", defaultViewModelId: nil, defaultInstanceId: nil)
                ]
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    interactionsByScreen: ["screen-2": [interaction]],
                    screens: screens
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                journey.flowState.navigationStack = ["screen-1"]
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                let controller = await MainActor.run {
                    SpyFlowViewController(flow: flow)
                }
                runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-2")

                await expect(controller.messages.map(\.type)).toEventually(contain("runtime/navigate"))
                let payload = controller.messages.last?.payload
                expect(payload?["screenId"] as? String).to(equal("screen-1"))
                expect(payload?["transition"]).to(beNil())
            }

            it("no-ops back when history is empty") {
                let flowId = "flow-back-empty"
                let interaction = Interaction(
                    id: "int-back",
                    trigger: .event(eventName: SystemEventNames.screenShown, filter: nil),
                    actions: [.back(BackAction(steps: 1))],
                    enabled: true
                )
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    interactionsByScreen: ["screen-1": [interaction]]
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                let controller = await MainActor.run {
                    SpyFlowViewController(flow: flow)
                }
                runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-1")

                expect(controller.messages.isEmpty).to(beTrue())
            }

            it("tracks send_event and updates customer properties") {
                let flowId = "flow-send-event"
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [
                        .updateCustomer(UpdateCustomerAction(attributes: ["plan": AnyCodable("pro")])),
                        .sendEvent(SendEventAction(
                            eventName: "custom_event",
                            properties: ["source": AnyCodable("flow")]
                        ))
                    ]
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                _ = await runner.handleRuntimeReady()

                let props = mocks.identityService.getUserProperties()
                expect(props["plan"] as? String).to(equal("pro"))

                let trackedEvents = mocks.eventService.trackedEvents.map(\.name)
                expect(trackedEvents).to(contain("custom_event"))
            }
        }
    }
}

private final class SpyFlowViewController: FlowViewController {
    struct Message {
        let type: String
        let payload: [String: Any]
    }

    struct PurchaseRequest {
        let productId: String
        let placementIndex: Any?
    }

    struct OpenLinkRequest {
        let urlString: String
        let target: String?
    }

    private(set) var messages: [Message] = []
    private(set) var purchaseRequests: [PurchaseRequest] = []
    private(set) var restoreRequests = 0
    private(set) var dismissRequests: [CloseReason] = []
    private(set) var openLinkRequests: [OpenLinkRequest] = []

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

    override func performPurchase(productId: String, placementIndex: Any? = nil) {
        purchaseRequests.append(PurchaseRequest(productId: productId, placementIndex: placementIndex))
    }

    override func performRestore() {
        restoreRequests += 1
    }

    override func performDismiss(reason: CloseReason = .userDismissed) {
        dismissRequests.append(reason)
    }

    override func performOpenLink(urlString: String, target: String? = nil) {
        openLinkRequests.append(OpenLinkRequest(urlString: urlString, target: target))
    }
}
