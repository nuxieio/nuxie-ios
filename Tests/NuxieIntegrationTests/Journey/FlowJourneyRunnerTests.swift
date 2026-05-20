import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

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

        func vmPath(_ propertyPath: String, viewModelName: String = "VM") -> VmPathRef {
            VmPathRef(viewModelName: viewModelName, path: propertyPath)
        }

        func normalizeAnyCodable(_ value: AnyCodable) -> AnyCodable {
            AnyCodable(normalizeAny(value.value))
        }

        func normalizeAny(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                return dict.mapValues { normalizeAny($0) }
            }
            if let dict = value as? [String: AnyCodable] {
                return dict.mapValues { normalizeAnyCodable($0) }
            }
            if let array = value as? [Any] {
                return array.map { normalizeAny($0) }
            }
            if let array = value as? [AnyCodable] {
                return array.map { normalizeAnyCodable($0) }
            }
            return value
        }

        func normalizeAction(_ action: InteractionAction, viewModels: [ViewModel]) -> InteractionAction {
            switch action {
            case .setViewModel(let action):
                return .setViewModel(SetViewModelAction(
                    type: action.type,
                    path: action.path,
                    value: normalizeAnyCodable(action.value)
                ))
            case .fireTrigger(let action):
                return .fireTrigger(FireTriggerAction(
                    type: action.type,
                    path: action.path
                ))
            case .listInsert(let action):
                return .listInsert(ListInsertAction(
                    type: action.type,
                    path: action.path,
                    index: action.index,
                    value: normalizeAnyCodable(action.value)
                ))
            case .listRemove(let action):
                return .listRemove(ListRemoveAction(
                    type: action.type,
                    path: action.path,
                    index: action.index
                ))
            case .listSwap(let action):
                return .listSwap(ListSwapAction(
                    type: action.type,
                    path: action.path,
                    indexA: action.indexA,
                    indexB: action.indexB
                ))
            case .listMove(let action):
                return .listMove(ListMoveAction(
                    type: action.type,
                    path: action.path,
                    from: action.from,
                    to: action.to
                ))
            case .listSet(let action):
                return .listSet(ListSetAction(
                    type: action.type,
                    path: action.path,
                    index: action.index,
                    value: normalizeAnyCodable(action.value)
                ))
            case .listClear(let action):
                return .listClear(ListClearAction(
                    type: action.type,
                    path: action.path
                ))
            case .condition(let action):
                return .condition(ConditionAction(
                    type: action.type,
                    branches: action.branches.map { branch in
                        ConditionBranch(
                            id: branch.id,
                            label: branch.label,
                            condition: branch.condition,
                            actions: branch.actions.map { normalizeAction($0, viewModels: viewModels) }
                        )
                    },
                    defaultActions: action.defaultActions?.map { normalizeAction($0, viewModels: viewModels) }
                ))
            case .experiment(let action):
                return .experiment(ExperimentAction(
                    type: action.type,
                    experimentId: action.experimentId,
                    variants: action.variants.map { variant in
                        ExperimentVariant(
                            id: variant.id,
                            name: variant.name,
                            percentage: variant.percentage,
                            actions: variant.actions.map { normalizeAction($0, viewModels: viewModels) }
                        )
                    }
                ))
            case .timeWindow(let action):
                return .timeWindow(TimeWindowAction(
                    type: action.type,
                    startTime: action.startTime,
                    endTime: action.endTime,
                    timezone: action.timezone,
                    daysOfWeek: action.daysOfWeek,
                    successActions: action.successActions?.map { normalizeAction($0, viewModels: viewModels) }
                ))
            case .purchase(let action):
                return .purchase(PurchaseAction(
                    type: action.type,
                    placementIndex: normalizeAnyCodable(action.placementIndex),
                    productId: normalizeAnyCodable(action.productId)
                ))
            default:
                return action
            }
        }

        func normalizeTrigger(_ trigger: InteractionTrigger, viewModels: [ViewModel]) -> InteractionTrigger {
            if case .didSet(let path, let debounceMs) = trigger {
                return .didSet(path: path, debounceMs: debounceMs)
            }
            return trigger
        }

        func defaultValues(for viewModel: ViewModel) -> [String: AnyCodable] {
            viewModel.properties.compactMapValues { $0.defaultValue }
        }

        func viewModelValues(
            viewModels: [ViewModel],
            instances: [ViewModelInstance]?
        ) -> [RemoteFlowViewModelValue] {
            let nameById = Dictionary(uniqueKeysWithValues: viewModels.map { ($0.id, $0.name) })
            let sourceInstances = instances ?? viewModels.compactMap { viewModel -> ViewModelInstance? in
                let values = defaultValues(for: viewModel)
                guard !values.isEmpty else { return nil }
                return ViewModelInstance(
                    viewModelId: viewModel.id,
                    instanceId: "\(viewModel.name):default",
                    name: "Default",
                    values: values
                )
            }
            return sourceInstances.flatMap { instance in
                guard let viewModelName = nameById[instance.viewModelId] else { return [RemoteFlowViewModelValue]() }
                return instance.values.map { key, value in
                    RemoteFlowViewModelValue(
                        viewModelName: viewModelName,
                        instanceId: instance.instanceId,
                        instanceName: instance.name,
                        path: key,
                        value: value
                    )
                }
            }
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
                        actions: entryActions.map { normalizeAction($0, viewModels: viewModels) },
                        enabled: true
                    )
                ]
            }
            let resolvedScreens = (screens ?? [
                RemoteFlowScreen(
                    id: "screen-1",
                    defaultViewModelName: viewModels.first?.name,
                    defaultInstanceId: nil
                )
            ]).map { screen in
                RemoteFlowScreen(
                    id: screen.id,
                    defaultViewModelName: screen.defaultViewModelName.map { defaultName in
                        viewModels.first(where: { $0.id == defaultName })?.name ?? defaultName
                    },
                    defaultInstanceId: screen.defaultInstanceId
                )
            }
            let normalizedInteractions = interactions.mapValues { interactions in
                interactions.map { interaction in
                    Interaction(
                        id: interaction.id,
                        trigger: normalizeTrigger(interaction.trigger, viewModels: viewModels),
                        actions: interaction.actions.map { normalizeAction($0, viewModels: viewModels) },
                        enabled: interaction.enabled
                    )
                }
            }
            let values = viewModelValues(viewModels: viewModels, instances: viewModelInstances)

            return RemoteFlow(
                id: flowId,
                flowArtifact: FlowArtifact(
                    url: "https://example.com/flow/\(flowId)",
                    manifest: BuildManifest(
                        totalFiles: 1,
                        totalSize: 100,
                        contentHash: "test-hash",
                        files: [BuildFile(path: "index.html", size: 100, contentType: "text/html")]
                    )
                ),
                screens: resolvedScreens,
                interactions: normalizedInteractions,
                viewModelValues: values.isEmpty ? nil : values
            )
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

            it("applies initial view model state through the native controller API") {
                let flowId = "flow-view-model-init-v2"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "title": ViewModelProperty(
                            type: .string,
                            propertyId: 1,
                            defaultValue: AnyCodable("Hello"),
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
                    viewModels: [viewModel],
                    screens: [
                        RemoteFlowScreen(id: "screen-1", defaultViewModelName: "vm-1", defaultInstanceId: nil),
                    ]
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                let controller = await MainActor.run {
                    SpyFlowViewController(flow: flow)
                }
                runner.attach(viewController: controller)

                _ = await runner.handleRuntimeReady()

                await expect(controller.viewModelSnapshots.count).toEventually(equal(1))
                let snapshot = controller.viewModelSnapshots.first
                expect(snapshot?.screenId).to(beNil())
                expect(snapshot?.snapshot.viewModelInstances.first?.viewModelId).to(equal("VM"))
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
                        RemoteFlowScreen(id: "screen-1", defaultViewModelName: nil, defaultInstanceId: nil),
                        RemoteFlowScreen(id: "screen-2", defaultViewModelName: nil, defaultInstanceId: nil),
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

                await expect(controller.navigationRequests.map(\.screenId)).toEventually(contain("screen-2"))
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
                    trigger: .didSet(path: vmPath("pulse"), debounceMs: nil),
                    actions: [.navigate(NavigateAction(screenId: "screen-2", transition: nil))],
                    enabled: true
                )
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    interactionsByScreen: ["__global__": [interaction]],
                    viewModels: [viewModel],
                    screens: [
                        RemoteFlowScreen(id: "screen-1", defaultViewModelName: "vm-1", defaultInstanceId: nil),
                        RemoteFlowScreen(id: "screen-2", defaultViewModelName: "vm-1", defaultInstanceId: nil),
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
                    path: vmPath("pulse"),
                    value: 1,
                    source: "runtime",
                    screenId: "screen-1",
                    instanceId: nil
                )

                await expect(controller.navigationRequests.map(\.screenId)).toEventually(contain("screen-2"))
            }

            it("does not echo Rive-origin trigger did_set changes back into the renderer") {
                let flowId = "flow-rive-trigger-no-echo"
                let path = vmPath("pulse")
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
                    id: "int-rive-did-set",
                    trigger: .didSet(path: path, debounceMs: nil),
                    actions: [
                        .sendEvent(
                            SendEventAction(
                                eventName: "rive_trigger_seen",
                                properties: nil
                            )
                        )
                    ],
                    enabled: true
                )
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    interactionsByScreen: ["screen-1": [interaction]],
                    viewModels: [viewModel],
                    screens: [
                        RemoteFlowScreen(id: "screen-1", defaultViewModelName: "vm-1", defaultInstanceId: nil)
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
                    path: path,
                    value: true,
                    source: "rive",
                    screenId: "screen-1",
                    instanceId: nil,
                    isTrigger: true
                )

                await expect(mocks.eventService.trackedEvents.map(\.name)).toEventually(contain("rive_trigger_seen"))
                try? await Task.sleep(nanoseconds: 50_000_000)
                expect(controller.viewModelTriggers).to(beEmpty())
                let values = journey.flowState.viewModelSnapshot?.viewModelInstances.first?.values
                expect(values?["pulse"]?.value as? Int).to(equal(0))
            }

            it("isolates debounced did_set dispatch per interaction across screen and global scopes") {
                let flowId = "flow-did-set-debounce-scope"
                let path = vmPath("pulse")
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

                let screenInteraction = Interaction(
                    id: "int-screen-did-set",
                    trigger: .didSet(path: path, debounceMs: 5),
                    actions: [
                        .sendEvent(
                            SendEventAction(
                                eventName: "screen_did_set",
                                properties: nil
                            )
                        )
                    ],
                    enabled: true
                )

                let globalInteraction = Interaction(
                    id: "int-global-did-set",
                    trigger: .didSet(path: path, debounceMs: 5),
                    actions: [
                        .sendEvent(
                            SendEventAction(
                                eventName: "global_did_set",
                                properties: nil
                            )
                        )
                    ],
                    enabled: true
                )

                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    interactionsByScreen: [
                        "screen-1": [screenInteraction],
                        "__global__": [globalInteraction]
                    ],
                    viewModels: [viewModel],
                    screens: [
                        RemoteFlowScreen(id: "screen-1", defaultViewModelName: "vm-1", defaultInstanceId: nil)
                    ]
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                journey.flowState.currentScreenId = "screen-1"
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                _ = await runner.handleDidSet(
                    path: path,
                    value: 1,
                    source: "runtime",
                    screenId: "screen-1",
                    instanceId: nil
                )

                await expect(mocks.eventService.trackedEvents.map(\.name)).toEventually(contain("screen_did_set"))
                await expect(mocks.eventService.trackedEvents.map(\.name)).toEventually(contain("global_did_set"))
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
                            path: vmPath("flag"),
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

                await expect(controller.viewModelValues.map(\.path.normalizedPath)).toEventually(
                    contain(vmPath("flag").normalizedPath)
                )
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
                            path: vmPath("items"),
                            index: 0,
                            value: AnyCodable(["literal": "a"] as [String: Any])
                        )),
                        .fireTrigger(FireTriggerAction(path: vmPath("pulse")))
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
                try? await Task.sleep(nanoseconds: 50_000_000)
                let resetValues = journey.flowState.viewModelSnapshot?.viewModelInstances.first?.values
                let pulse = resetValues?["pulse"]?.value as? Int
                expect(pulse).to(equal(0))

                await expect(controller.viewModelListOperations.map(\.operation)).toEventually(contain(.insert))
                await expect(controller.viewModelTriggers.map(\.path.normalizedPath)).toEventually(
                    contain(vmPath("pulse").normalizedPath)
                )
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
                            path: vmPath("items"),
                            from: 0,
                            to: 2
                        )),
                        .listSet(ListSetAction(
                            path: vmPath("items"),
                            index: 1,
                            value: AnyCodable(["literal": "z"] as [String: Any])
                        )),
                        .listClear(ListClearAction(path: vmPath("items")))
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

                await expect(controller.viewModelListOperations.map(\.operation)).toEventually(contain(.move))
                expect(controller.viewModelListOperations.map(\.operation)).to(contain(.set))
                expect(controller.viewModelListOperations.map(\.operation)).to(contain(.clear))
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
                let purchaseAction = InteractionAction.purchase(
                    PurchaseAction(
                        placementIndex: AnyCodable([
                            "ref": [
                                "kind": "path",
                                "viewModelName": "VM",
                                "path": "selectedIndex"
                            ]
                        ]),
                        productId: AnyCodable([
                            "ref": [
                                "kind": "path",
                                "viewModelName": "VM",
                                "path": "selectedProductId"
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
                        .requestNotifications(RequestNotificationsAction()),
                        .requestPermission(RequestPermissionAction(permissionType: "camera")),
                        .requestTracking(RequestTrackingAction()),
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
                expect(controller.requestNotificationJourneyIds).to(equal([journey.id]))
                expect(controller.requestPermissionRequests.map(\.permissionType)).to(equal(["camera"]))
                expect(controller.requestPermissionRequests.map(\.journeyId)).to(equal([journey.id]))
                expect(controller.requestTrackingJourneyIds).to(equal([journey.id]))
                expect(controller.openLinkRequests.map(\.urlString)).to(equal(["https://example.com"]))
                expect(controller.dismissRequests).to(equal([.userDismissed]))
                expect(runner.hasPendingWork()).to(beTrue())

                runner.handleScopedSystemPermissionEvent(SystemEventNames.notificationsEnabled)
                runner.handleScopedSystemPermissionEvent(SystemEventNames.permissionGranted)
                runner.handleScopedSystemPermissionEvent(SystemEventNames.trackingAuthorized)

                expect(runner.hasPendingWork()).to(beFalse())
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
                            path: vmPath("flag"),
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

            it("uses the current device timezone token for time_window") {
                let flowId = "flow-time-window-device"
                let action = TimeWindowAction(
                    startTime: "09:00",
                    endTime: "11:00",
                    timezone: "__current_device__",
                    daysOfWeek: nil,
                    successActions: [
                        .navigate(NavigateAction(screenId: "screen-2", transition: nil))
                    ]
                )
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [.timeWindow(action)],
                    screens: [
                        RemoteFlowScreen(id: "screen-1", defaultViewModelName: nil, defaultInstanceId: nil),
                        RemoteFlowScreen(id: "screen-2", defaultViewModelName: nil, defaultInstanceId: nil),
                    ]
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
                let controller = await MainActor.run {
                    SpyFlowViewController(flow: flow)
                }
                runner.attach(viewController: controller)

                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .current
                let date = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 10, minute: 0))!
                mocks.dateProvider.setCurrentDate(date)

                _ = await runner.handleRuntimeReady()

                expect(journey.flowState.pendingAction).to(beNil())
                await expect(controller.navigationRequests.map(\.screenId)).toEventually(contain("screen-2"))
            }

            it("resumes nested time_window actions after a delay pause") {
                let flowId = "flow-time-window-delayed-then"
                let action = TimeWindowAction(
                    startTime: "09:00",
                    endTime: "11:00",
                    timezone: "UTC",
                    daysOfWeek: nil,
                    successActions: [
                        .delay(DelayAction(durationMs: 1_000)),
                        .navigate(NavigateAction(screenId: "screen-2", transition: nil)),
                    ]
                )
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [.timeWindow(action)],
                    screens: [
                        RemoteFlowScreen(id: "screen-1", defaultViewModelName: nil, defaultInstanceId: nil),
                        RemoteFlowScreen(id: "screen-2", defaultViewModelName: nil, defaultInstanceId: nil),
                    ]
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
                let controller = await MainActor.run {
                    SpyFlowViewController(flow: flow)
                }
                runner.attach(viewController: controller)

                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
                let date = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 10, minute: 0))!
                mocks.dateProvider.setCurrentDate(date)

                let outcome = await runner.handleRuntimeReady()
                if case .paused(let pending) = outcome {
                    expect(pending.kind).to(equal(.delay))
                } else {
                    fail("Expected nested time_window delay to pause")
                }

                _ = await runner.resumePendingAction(reason: .timer, event: nil)

                expect(journey.flowState.pendingAction).to(beNil())
                await expect(controller.navigationRequests.map(\.screenId)).toEventually(contain("screen-2"))
            }

            it("resumes nested time_window actions and continues outer actions") {
                let flowId = "flow-time-window-delayed-outer"
                let action = TimeWindowAction(
                    startTime: "09:00",
                    endTime: "11:00",
                    timezone: "UTC",
                    daysOfWeek: nil,
                    successActions: [
                        .delay(DelayAction(durationMs: 1_000)),
                        .sendEvent(SendEventAction(
                            eventName: "inside_window",
                            properties: nil
                        )),
                    ]
                )
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [
                        .timeWindow(action),
                        .sendEvent(SendEventAction(
                            eventName: "after_window",
                            properties: nil
                        )),
                    ]
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
                let date = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 10, minute: 0))!
                mocks.dateProvider.setCurrentDate(date)

                let outcome = await runner.handleRuntimeReady()
                if case .paused(let pending) = outcome {
                    expect(pending.kind).to(equal(.delay))
                } else {
                    fail("Expected nested time_window delay to pause")
                }

                _ = await runner.resumePendingAction(reason: .timer, event: nil)

                expect(journey.flowState.pendingAction).to(beNil())
                let trackedEvents = mocks.eventService.trackedEvents.map(\.name)
                expect(trackedEvents).to(contain("inside_window"))
                expect(trackedEvents).to(contain("after_window"))
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
                            path: vmPath("flag"),
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
                            path: vmPath("flag"),
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
                            path: vmPath("variant"),
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
                            path: vmPath("variant"),
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
                            path: vmPath("variant"),
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
                            path: vmPath("variant"),
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
                            path: vmPath("variant"),
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
                            path: vmPath("variant"),
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
                    eventId: nil,
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
                    eventId: nil,
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
                    RemoteFlowScreen(id: "screen-1", defaultViewModelName: nil, defaultInstanceId: nil),
                    RemoteFlowScreen(id: "screen-2", defaultViewModelName: nil, defaultInstanceId: nil)
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

                await expect(controller.navigationRequests.map(\.screenId)).toEventually(contain("screen-1"))
                let transitionPayload = controller.navigationRequests.last?.transition as? [String: Any]
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
                    RemoteFlowScreen(id: "screen-1", defaultViewModelName: nil, defaultInstanceId: nil),
                    RemoteFlowScreen(id: "screen-2", defaultViewModelName: nil, defaultInstanceId: nil)
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

                await expect(controller.navigationRequests.map(\.screenId)).toEventually(contain("screen-1"))
                expect(controller.navigationRequests.last?.transition).to(beNil())
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

            it("tracks goal actions with standard journey property keys") {
                let flowId = "flow-goal-action"
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [
                        .goal(GoalAction(goalId: " signup_complete ", label: " Signed Up "))
                    ]
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

                _ = await runner.handleRuntimeReady()

                let goalEvent = mocks.eventService.trackedEvents.last { $0.name == JourneyEvents.journeyGoalHit }
                expect(goalEvent?.properties?["journey_id"] as? String).to(equal(journey.id))
                expect(goalEvent?.properties?["campaign_id"] as? String).to(equal(campaign.id))
                expect(goalEvent?.properties?["goal_id"] as? String).to(equal("signup_complete"))
                expect(goalEvent?.properties?["goal_label"] as? String).to(equal("Signed Up"))
                expect(goalEvent?.properties?["interaction_id"] as? String).to(equal("start"))
                expect(goalEvent?.properties?["journeyId"]).to(beNil())
                expect(goalEvent?.properties?["campaignId"]).to(beNil())
                expect(goalEvent?.properties?["goalId"]).to(beNil())
                expect(goalEvent?.properties?["goalLabel"]).to(beNil())
            }

            it("stops executing after goal actions that complete the journey") {
                let flowId = "flow-goal-stop"
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [
                        .goal(GoalAction(goalId: "signup_complete", label: "Signed Up")),
                        .sendEvent(SendEventAction(eventName: "should_not_run", properties: nil)),
                    ]
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                let runner = FlowJourneyRunner(
                    journey: journey,
                    campaign: campaign,
                    flow: flow,
                    onGoalHit: { _, _, _, _ in
                        journey.complete(reason: .goalMet)
                    }
                )

                _ = await runner.handleRuntimeReady()

                let trackedEvents = mocks.eventService.trackedEvents.map(\.name)
                expect(trackedEvents).toNot(contain("should_not_run"))
            }

            it("stops executing after goal actions that defer dismissal") {
                let flowId = "flow-goal-deferred-stop"
                let remoteFlow = makeRemoteFlow(
                    flowId: flowId,
                    entryActions: [
                        .goal(GoalAction(goalId: "signup_complete", label: "Signed Up")),
                        .sendEvent(SendEventAction(eventName: "should_not_run", properties: nil)),
                    ]
                )
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                let campaign = makeCampaign(flowId: flowId)
                let journey = Journey(campaign: campaign, distinctId: "user-1")
                var runner: FlowJourneyRunner!
                runner = FlowJourneyRunner(
                    journey: journey,
                    campaign: campaign,
                    flow: flow,
                    onGoalHit: { _, _, _, _ in
                        runner.deferDismiss(reason: .goalMet)
                    }
                )

                _ = await runner.handleRuntimeReady()

                let trackedEvents = mocks.eventService.trackedEvents.map(\.name)
                expect(trackedEvents).toNot(contain("should_not_run"))
            }
        }
    }
}

private final class SpyFlowViewController: FlowViewController {
    struct PurchaseRequest {
        let productId: String
        let placementIndex: Any?
    }

    struct OpenLinkRequest {
        let urlString: String
        let target: String?
    }

    struct ViewModelSnapshotRequest {
        let snapshot: FlowViewModelSnapshot
        let screenId: String?
    }

    struct ViewModelValueRequest {
        let path: VmPathRef
        let value: Any
        let screenId: String?
        let instanceId: String?
    }

    struct ViewModelListOperationRequest {
        let operation: FlowViewModelListOperation
        let path: VmPathRef
        let payload: [String: Any]
        let screenId: String?
        let instanceId: String?
    }

    struct ViewModelTriggerRequest {
        let path: VmPathRef
        let screenId: String?
        let instanceId: String?
    }

    struct NavigationRequest {
        let screenId: String
        let transition: Any?
    }

    private(set) var viewModelSnapshots: [ViewModelSnapshotRequest] = []
    private(set) var viewModelValues: [ViewModelValueRequest] = []
    private(set) var viewModelListOperations: [ViewModelListOperationRequest] = []
    private(set) var viewModelTriggers: [ViewModelTriggerRequest] = []
    private(set) var navigationRequests: [NavigationRequest] = []
    private(set) var purchaseRequests: [PurchaseRequest] = []
    private(set) var restoreRequests = 0
    private(set) var requestNotificationJourneyIds: [String?] = []
    private(set) var requestPermissionRequests: [(permissionType: String, journeyId: String?)] = []
    private(set) var requestTrackingJourneyIds: [String?] = []
    private(set) var dismissRequests: [CloseReason] = []
    private(set) var openLinkRequests: [OpenLinkRequest] = []

    init(flow: Flow) {
        super.init(flow: flow, artifactStore: FlowArtifactStore())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func applyViewModelSnapshot(_ snapshot: FlowViewModelSnapshot, screenId: String? = nil) {
        viewModelSnapshots.append(ViewModelSnapshotRequest(snapshot: snapshot, screenId: screenId))
    }

    override func applyViewModelValue(
        path: VmPathRef,
        value: Any,
        screenId: String? = nil,
        instanceId: String? = nil
    ) {
        viewModelValues.append(
            ViewModelValueRequest(
                path: path,
                value: value,
                screenId: screenId,
                instanceId: instanceId
            )
        )
    }

    override func applyViewModelListOperation(
        _ operation: FlowViewModelListOperation,
        path: VmPathRef,
        payload: [String: Any],
        screenId: String? = nil,
        instanceId: String? = nil
    ) {
        viewModelListOperations.append(
            ViewModelListOperationRequest(
                operation: operation,
                path: path,
                payload: payload,
                screenId: screenId,
                instanceId: instanceId
            )
        )
    }

    override func fireViewModelTrigger(
        path: VmPathRef,
        screenId: String? = nil,
        instanceId: String? = nil
    ) {
        viewModelTriggers.append(
            ViewModelTriggerRequest(
                path: path,
                screenId: screenId,
                instanceId: instanceId
            )
        )
    }

    override func navigate(to screenId: String, transition: Any? = nil) {
        navigationRequests.append(NavigationRequest(screenId: screenId, transition: transition))
    }

    override func performPurchase(productId: String, placementIndex: Any? = nil) {
        purchaseRequests.append(PurchaseRequest(productId: productId, placementIndex: placementIndex))
    }

    override func performRestore() {
        restoreRequests += 1
    }

    override func performRequestNotifications(journeyId: String? = nil) {
        requestNotificationJourneyIds.append(journeyId)
    }

    override func performRequestPermission(permissionType: String, journeyId: String? = nil) {
        requestPermissionRequests.append((permissionType: permissionType, journeyId: journeyId))
    }

    override func performRequestTracking(journeyId: String? = nil) {
        requestTrackingJourneyIds.append(journeyId)
    }

    override func performDismiss(reason: CloseReason = .userDismissed) {
        dismissRequests.append(reason)
    }

    override func performOpenLink(urlString: String, target: String? = nil) {
        openLinkRequests.append(OpenLinkRequest(urlString: urlString, target: target))
    }
}
