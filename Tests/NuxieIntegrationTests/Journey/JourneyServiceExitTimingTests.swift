import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie

private final class OrderingRecorder {
    private let lock = NSLock()
    private var _events: [String] = []

    func append(_ event: String) {
        lock.withLock {
            _events.append(event)
        }
    }

    func clear() {
        lock.withLock {
            _events.removeAll()
        }
    }

    var events: [String] {
        lock.withLock { _events }
    }
}

private final class OrderingJourneyStore: MockJourneyStore {
    private let recorder: OrderingRecorder

    init(recorder: OrderingRecorder) {
        self.recorder = recorder
        super.init()
    }

    override func recordCompletion(_ record: JourneyCompletionRecord) throws {
        try super.recordCompletion(record)
        recorder.append("complete:\(record.campaignId)")
    }
}

private final class OrderingFlowPresentationService: MockFlowPresentationService {
    private let recorder: OrderingRecorder

    init(recorder: OrderingRecorder) {
        self.recorder = recorder
        super.init()
    }

    @discardableResult
    @MainActor
    override func presentFlow(
        _ flowId: String,
        from journey: Journey?,
        runtimeDelegate: FlowRuntimeDelegate?
    ) async throws -> FlowViewController {
        recorder.append("present:\(flowId)")
        return try await super.presentFlow(
            flowId,
            from: journey,
            runtimeDelegate: runtimeDelegate
        )
    }

    @discardableResult
    @MainActor
    override func presentFlow(
        _ flowId: String,
        from journey: Journey?,
        runtimeDelegate: FlowRuntimeDelegate?,
        colorSchemeMode: FlowColorSchemeMode
    ) async throws -> FlowViewController {
        return try await super.presentFlow(
            flowId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode
        )
    }
}

private final class UnsupportedTrackingAuthorizationHandler: TrackingAuthorizationHandling {
    func authorizationStatus() -> TrackingAuthorizationStatus {
        .unsupported
    }

    func requestAuthorization() async -> TrackingAuthorizationStatus {
        .unsupported
    }
}

private final class DelayedTrackingAuthorizationHandler: TrackingAuthorizationHandling {
    let delayNanoseconds: UInt64
    let result: TrackingAuthorizationStatus

    init(delayNanoseconds: UInt64, result: TrackingAuthorizationStatus) {
        self.delayNanoseconds = delayNanoseconds
        self.result = result
    }

    func authorizationStatus() -> TrackingAuthorizationStatus {
        .notDetermined
    }

    func requestAuthorization() async -> TrackingAuthorizationStatus {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return result
    }
}

final class JourneyServiceExitTimingTests: AsyncSpec {
    override class func spec() {
        var mocks: MockFactory!
        var journeyStore: MockJourneyStore!
        var service: JourneyService!
        var controller: MockFlowViewController!

        let distinctId = "user_1"
        let flowId = "flow-exit-timing"
        let campaignId = "camp-exit-timing"

        func makeGatePlanResponse(
            decision: String,
            flowId: String? = nil,
            featureId: String? = nil,
            policy: String? = nil,
            requiredBalance: Int? = nil
        ) -> EventResponse {
            var gatePayload: [String: Any] = ["decision": decision]
            if let flowId {
                gatePayload["flowId"] = flowId
            }
            if let featureId {
                gatePayload["featureId"] = featureId
            }
            if let policy {
                gatePayload["policy"] = policy
            }
            if let requiredBalance {
                gatePayload["requiredBalance"] = requiredBalance
            }

            return EventResponse(
                status: "ok",
                payload: ["gate": AnyCodable(gatePayload)],
                customer: nil,
                event: nil,
                message: nil,
                featuresMatched: nil,
                usage: nil,
                journey: nil,
                execution: nil
            )
        }

        func makeCampaign(
            id: String = campaignId,
            flowId: String = flowId,
            trigger: CampaignTrigger = .event(EventTriggerConfig(eventName: "paywall_trigger", condition: nil)),
            goal: GoalConfig?,
            exitPolicy: ExitPolicy?
        ) -> Campaign {
            Campaign(
                id: id,
                name: "Exit Timing Campaign",
                flowId: flowId,
                flowNumber: 1,
                flowName: nil,
                reentry: .everyTime,
                publishedAt: Date().ISO8601Format(),
                trigger: trigger,
                goal: goal,
                exitPolicy: exitPolicy,
                conversionAnchor: nil,
                campaignType: nil
            )
        }

        func makeFlow(flowId: String = flowId, interactions: [String: [Interaction]] = [:]) -> Flow {
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
            await primeProfile(campaigns: [campaign], flows: [flow])
        }

        func primeProfile(campaigns: [Campaign], flows: [Flow]) async {
            mocks.identityService.setDistinctId(distinctId)
            for flow in flows {
                mocks.flowService.mockFlows[flow.remoteFlow.id] = flow
            }
            mocks.profileService.setProfileResponse(
                ResponseBuilders.buildProfileResponse(
                    campaigns: campaigns,
                    flows: flows.map(\.remoteFlow)
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

            it("starts matching campaigns from scoped notification outcomes") {
                let notificationCampaign = makeCampaign(
                    id: "camp-notifications",
                    flowId: "flow-notifications",
                    trigger: .event(EventTriggerConfig(eventName: SystemEventNames.notificationsEnabled, condition: nil)),
                    goal: nil,
                    exitPolicy: nil
                )
                let primaryCampaign = makeCampaign(goal: nil, exitPolicy: nil)
                let primaryFlow = makeFlow()
                let notificationFlow = makeFlow(flowId: "flow-notifications")

                await primeProfile(
                    campaigns: [primaryCampaign, notificationCampaign],
                    flows: [primaryFlow, notificationFlow]
                )
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    await service.getActiveJourneys(for: distinctId).map(\.campaignId).sorted()
                }.toEventually(equal([campaignId, "camp-notifications"].sorted()), timeout: .seconds(2))
            }

            it("marks journeys converted when scoped goal actions fire") {
                let campaign = makeCampaign(
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyGoalHit),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()

                await service.handleScopedGoalEvent(
                    journeyId: journey.id,
                    goalId: "signup_complete",
                    goalLabel: "Signed Up",
                    screenId: "screen-1"
                )

                let activeJourneys = await service.getActiveJourneys(for: distinctId)
                expect(activeJourneys.map(\.id)).to(equal([journey.id]))
                expect(activeJourneys.first?.convertedAt).toNot(beNil())
                expect(mocks.eventService.trackForTriggerCalls.last?.properties?["journey_id"] as? String)
                    .to(equal(journey.id))
                expect(mocks.eventService.trackForTriggerCalls.last?.properties?["campaign_id"] as? String)
                    .to(equal(campaign.id))
                expect(mocks.eventService.trackForTriggerCalls.last?.properties?["goal_id"] as? String)
                    .to(equal("signup_complete"))
                expect(mocks.eventService.trackForTriggerCalls.last?.properties?["goal_label"] as? String)
                    .to(equal("Signed Up"))
                expect(mocks.eventService.trackForTriggerCalls.last?.properties?["journeyId"]).to(beNil())
                expect(mocks.eventService.trackForTriggerCalls.last?.properties?["goalId"]).to(beNil())

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
            }

            it("replays scoped notification outcomes into newly started journeys") {
                let notificationCampaign = makeCampaign(
                    id: "camp-notifications-replay",
                    flowId: "flow-notifications-replay",
                    trigger: .event(EventTriggerConfig(eventName: SystemEventNames.notificationsEnabled, condition: nil)),
                    goal: GoalConfig(
                        kind: .event,
                        eventName: SystemEventNames.notificationsEnabled,
                        eventFilter: nil,
                        window: 60
                    ),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let primaryCampaign = makeCampaign(goal: nil, exitPolicy: nil)
                let primaryFlow = makeFlow()
                let notificationFlow = makeFlow(flowId: "flow-notifications-replay")

                await primeProfile(
                    campaigns: [primaryCampaign, notificationCampaign],
                    flows: [primaryFlow, notificationFlow]
                )
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    await service.getActiveJourneys(for: distinctId).first {
                        $0.campaignId == "camp-notifications-replay"
                    }?.convertedAt
                }.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("replays scoped tracking outcomes into newly started journeys") {
                let trackingCampaign = makeCampaign(
                    id: "camp-tracking-replay",
                    flowId: "flow-tracking-replay",
                    trigger: .event(EventTriggerConfig(eventName: SystemEventNames.trackingAuthorized, condition: nil)),
                    goal: GoalConfig(
                        kind: .event,
                        eventName: SystemEventNames.trackingAuthorized,
                        eventFilter: nil,
                        window: 60
                    ),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let primaryCampaign = makeCampaign(goal: nil, exitPolicy: nil)
                let primaryFlow = makeFlow()
                let trackingFlow = makeFlow(flowId: "flow-tracking-replay")

                await primeProfile(
                    campaigns: [primaryCampaign, trackingCampaign],
                    flows: [primaryFlow, trackingFlow]
                )
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run {
                    (controller.runtimeDelegate as? TrackingPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveTrackingPermissionEvent: SystemEventNames.trackingAuthorized,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    await service.getActiveJourneys(for: distinctId).first {
                        $0.campaignId == "camp-tracking-replay"
                    }?.convertedAt
                }.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("replays unsupported scoped tracking outcomes into newly started journeys") {
                let trackingCampaign = makeCampaign(
                    id: "camp-tracking-denied-replay",
                    flowId: "flow-tracking-denied-replay",
                    trigger: .event(EventTriggerConfig(eventName: SystemEventNames.trackingDenied, condition: nil)),
                    goal: GoalConfig(
                        kind: .event,
                        eventName: SystemEventNames.trackingDenied,
                        eventFilter: nil,
                        window: 60
                    ),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let primaryCampaign = makeCampaign(goal: nil, exitPolicy: nil)
                let primaryFlow = makeFlow()
                let trackingFlow = makeFlow(flowId: "flow-tracking-denied-replay")

                await primeProfile(
                    campaigns: [primaryCampaign, trackingCampaign],
                    flows: [primaryFlow, trackingFlow]
                )
                await service.initialize()

                _ = await startJourney()
                await MainActor.run {
                    controller.trackingAuthorizationHandler = UnsupportedTrackingAuthorizationHandler()
                    controller.runtimeDelegate?.flowViewController(
                        controller,
                        didReceiveRuntimeMessage: "action/request_tracking",
                        payload: [:],
                        id: nil
                    )
                }

                await expect {
                    await service.getActiveJourneys(for: distinctId).first {
                        $0.campaignId == "camp-tracking-denied-replay"
                    }?.convertedAt
                }.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("completes dismissed journeys after unsupported tracking requests") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                await MainActor.run {
                    controller.trackingAuthorizationHandler = UnsupportedTrackingAuthorizationHandler()
                }

                await MainActor.run {
                    controller.runtimeDelegate?.flowViewController(
                        controller,
                        didReceiveRuntimeMessage: "action/request_tracking",
                        payload: [:],
                        id: nil
                    )
                }

                try? await Task.sleep(nanoseconds: 50_000_000)

                await MainActor.run {
                    controller.runtimeDelegate?.flowViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                await expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }.toEventually(beFalse(), timeout: .seconds(2))

                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.dismissed), timeout: .seconds(2))
            }

            it("does not defer dismissals for non-permission pending work") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                journey.flowState.pendingAction = FlowPendingAction(
                    interactionId: "wait-generic-dismiss",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                )

                await MainActor.run {
                    controller.runtimeDelegate?.flowViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                await expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }.toEventually(beFalse(), timeout: .seconds(2))

                await expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }.toEventually(equal(.dismissed), timeout: .seconds(2))
            }

            it("completes deferred dismissals after scoped tracking outcomes resolve") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.eventService.trackForTriggerDelayNanoseconds = 750_000_000

                await MainActor.run {
                    controller.trackingAuthorizationHandler = DelayedTrackingAuthorizationHandler(
                        delayNanoseconds: 100_000_000,
                        result: .authorized
                    )
                    controller.runtimeDelegate?.flowViewController(
                        controller,
                        didReceiveRuntimeMessage: "action/request_tracking",
                        payload: [:],
                        id: nil
                    )
                    controller.runtimeDelegate?.flowViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                await expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }.toEventually(beFalse(), timeout: .milliseconds(500))

                await expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }.toEventually(equal(.dismissed), timeout: .milliseconds(500))

                try? await Task.sleep(nanoseconds: 800_000_000)
            }

            it("completes dismissed journeys after unsupported request permission kinds") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run {
                    controller.runtimeDelegate?.flowViewController(
                        controller,
                        didReceiveRuntimeMessage: "action/request_permission",
                        payload: ["permissionType": "location_always"],
                        id: nil
                    )
                }

                try? await Task.sleep(nanoseconds: 50_000_000)

                await MainActor.run {
                    controller.runtimeDelegate?.flowViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                await expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }.toEventually(beFalse(), timeout: .milliseconds(500))

                await expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }.toEventually(equal(.dismissed), timeout: .milliseconds(500))
            }

            it("keeps deferred dismiss waiting when another request permission is still pending") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run {
                    controller.cameraPermissionAuthorizationHandler = DelayedRequestPermissionAuthorizationHandler(
                        initialStatus: .notDetermined,
                        delayNanoseconds: 200_000_000,
                        result: .granted
                    )
                    controller.cameraUsageDescriptionProvider = { "Camera usage description" }
                    controller.runtimeDelegate?.flowViewController(
                        controller,
                        didReceiveRuntimeMessage: "action/request_permission",
                        payload: ["permissionType": "location_always"],
                        id: nil
                    )
                    controller.runtimeDelegate?.flowViewController(
                        controller,
                        didReceiveRuntimeMessage: "action/request_permission",
                        payload: ["permissionType": "camera"],
                        id: nil
                    )
                }

                try? await Task.sleep(nanoseconds: 50_000_000)

                await MainActor.run {
                    controller.runtimeDelegate?.flowViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                try? await Task.sleep(nanoseconds: 75_000_000)
                let isStillActive = await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                expect(isStillActive).to(beTrue())

                await expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }.toEventually(beFalse(), timeout: .seconds(2))

                await expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }.toEventually(equal(.dismissed), timeout: .seconds(2))
            }

            it("resumes wait_until work on unsupported tracking requests") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                journey.flowState.pendingAction = FlowPendingAction(
                    interactionId: "wait-unsupported-tracking",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                )

                await MainActor.run {
                    controller.trackingAuthorizationHandler = UnsupportedTrackingAuthorizationHandler()
                    controller.runtimeDelegate?.flowViewController(
                        controller,
                        didReceiveRuntimeMessage: "action/request_tracking",
                        payload: [:],
                        id: nil
                    )
                }

                await expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("tracks scoped notification outcomes against the original user across identify races") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.identityService.setDistinctId("user_2")

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    mocks.eventService.trackForTriggerCalls.last?.distinctIdOverride
                }.toEventually(equal(distinctId), timeout: .seconds(2))
            }

            it("still tracks scoped notification outcomes after the original journey is cancelled") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                await service.handleUserChange(from: distinctId, to: "user_2")

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    mocks.eventService.trackForTriggerCalls.last?.distinctIdOverride
                }.toEventually(equal(distinctId), timeout: .seconds(2))
            }

            it("tracks unsupported scoped tracking outcomes against the original user across identify races") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                _ = await startJourney()
                mocks.identityService.setDistinctId("user_2")

                await MainActor.run {
                    controller.trackingAuthorizationHandler = UnsupportedTrackingAuthorizationHandler()
                    controller.runtimeDelegate?.flowViewController(
                        controller,
                        didReceiveRuntimeMessage: "action/request_tracking",
                        payload: [:],
                        id: nil
                    )
                }

                await expect {
                    mocks.eventService.trackForTriggerCalls.last?.distinctIdOverride
                }.toEventually(equal(distinctId), timeout: .seconds(2))
            }

            it("tracks unsupported scoped request permission outcomes against the original user across identify races") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                _ = await startJourney()
                mocks.identityService.setDistinctId("user_2")

                await MainActor.run {
                    controller.cameraPermissionAuthorizationHandler = UnsupportedRequestPermissionAuthorizationHandler()
                    controller.runtimeDelegate?.flowViewController(
                        controller,
                        didReceiveRuntimeMessage: "action/request_permission",
                        payload: ["permissionType": "camera"],
                        id: nil
                    )
                }

                await expect {
                    mocks.eventService.trackForTriggerCalls.last?.distinctIdOverride
                }.toEventually(equal(distinctId), timeout: .seconds(2))
            }

            it("resumes wait_until work on scoped notification outcomes") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                journey.flowState.pendingAction = FlowPendingAction(
                    interactionId: "wait-notifications",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                )

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("resumes wait_until work on scoped tracking outcomes") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                journey.flowState.pendingAction = FlowPendingAction(
                    interactionId: "wait-tracking",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                )

                await MainActor.run {
                    (controller.runtimeDelegate as? TrackingPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveTrackingPermissionEvent: SystemEventNames.trackingAuthorized,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("resumes wait_until work on scoped request permission outcomes") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                journey.flowState.pendingAction = FlowPendingAction(
                    interactionId: "wait-permission",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                )

                await MainActor.run {
                    (controller.runtimeDelegate as? RequestPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveRequestPermissionEvent: SystemEventNames.permissionGranted,
                        properties: [
                            "journey_id": journey.id,
                            "type": "camera"
                        ],
                        journeyId: journey.id
                    )
                }

                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("resumes wait_until work on unsupported request permission kinds") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                journey.flowState.pendingAction = FlowPendingAction(
                    interactionId: "wait-unsupported-permission",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                )

                await MainActor.run {
                    (controller.runtimeDelegate as? RequestPermissionEventReceiver)?.flowViewController(
                        controller,
                        didIgnoreUnsupportedRequestPermissionType: "location_always",
                        journeyId: journey.id
                    )
                }

                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("honors gate plans from unsupported scoped request permission outcomes") {
                let orderingPresentationService = OrderingFlowPresentationService(recorder: OrderingRecorder())
                orderingPresentationService.defaultMockViewController = controller
                Container.shared.flowPresentationService.register { @MainActor in orderingPresentationService }
                service = JourneyService(journeyStore: journeyStore)

                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.eventService.trackWithResponseResult = makeGatePlanResponse(
                    decision: "show_flow",
                    flowId: "gate-flow"
                )

                await MainActor.run {
                    (controller.runtimeDelegate as? RequestPermissionEventReceiver)?.flowViewController(
                        controller,
                        didIgnoreUnsupportedRequestPermissionType: "location_always",
                        journeyId: journey.id
                    )
                }

                await expect {
                    await MainActor.run {
                        orderingPresentationService.wasFlowPresented("gate-flow")
                    }
                }.toEventually(beTrue(), timeout: .seconds(2))
            }

            it("resumes wait_until work before scoped notification tracking returns") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                journey.flowState.pendingAction = FlowPendingAction(
                    interactionId: "wait-notifications",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                )
                mocks.eventService.trackForTriggerDelayNanoseconds = 750_000_000

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.completed), timeout: .milliseconds(250))

                try? await Task.sleep(nanoseconds: 800_000_000)
            }

            it("uses enriched scoped notification properties during immediate local goal evaluation") {
                Container.shared.sessionService().setSessionId("session-notification")

                let notificationGoal = GoalConfig(
                    kind: .event,
                    eventName: SystemEventNames.notificationsEnabled,
                    eventFilter: IREnvelope(
                        ir_version: 1,
                        engine_min: nil,
                        compiled_at: nil,
                        expr: .pred(
                            op: "eq",
                            key: "properties.$session_id",
                            value: .string("session-notification")
                        )
                    ),
                    window: 60
                )
                let campaign = makeCampaign(
                    id: "camp-session-filter",
                    flowId: "flow-session-filter",
                    goal: notificationGoal,
                    exitPolicy: nil
                )

                await primeProfile(
                    campaigns: [campaign],
                    flows: [makeFlow(flowId: "flow-session-filter")]
                )
                await service.initialize()

                let journey = await startJourney()
                mocks.eventService.trackForTriggerDelayNanoseconds = 750_000_000

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    (await service.getActiveJourneys(for: distinctId).first {
                        $0.id == journey.id
                    })?.convertedAt
                }.toEventuallyNot(beNil(), timeout: .milliseconds(250))

                try? await Task.sleep(nanoseconds: 800_000_000)
            }

            it("feeds scoped notification outcomes into all active journeys for goal evaluation") {
                let notificationGoal = GoalConfig(
                    kind: .event,
                    eventName: SystemEventNames.notificationsEnabled,
                    eventFilter: nil,
                    window: 60
                )
                let primaryCampaign = makeCampaign(
                    id: "camp-primary",
                    flowId: "flow-primary",
                    goal: nil,
                    exitPolicy: nil
                )
                let secondaryCampaign = makeCampaign(
                    id: "camp-secondary",
                    flowId: "flow-secondary",
                    goal: notificationGoal,
                    exitPolicy: nil
                )

                await primeProfile(
                    campaigns: [primaryCampaign, secondaryCampaign],
                    flows: [
                        makeFlow(flowId: "flow-primary"),
                        makeFlow(flowId: "flow-secondary"),
                    ]
                )
                await service.initialize()

                _ = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_origin", name: "paywall_trigger", distinctId: distinctId)
                )

                let activeJourneys = await service.getActiveJourneys(for: distinctId)
                let primaryJourney = activeJourneys.first(where: { $0.campaignId == "camp-primary" })
                let secondaryJourney = activeJourneys.first(where: { $0.campaignId == "camp-secondary" })
                expect(primaryJourney).toNot(beNil())
                expect(secondaryJourney?.convertedAt).to(beNil())

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": primaryJourney!.id],
                        journeyId: primaryJourney!.id
                    )
                }

                await expect {
                    (await service.getActiveJourneys(for: distinctId).first {
                        $0.campaignId == "camp-secondary"
                    })?.convertedAt
                }.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("feeds scoped notification outcomes into mixed attribute goals") {
                let notificationGoal = GoalConfig(
                    kind: .attribute,
                    attributeExpr: IREnvelope(
                        ir_version: 1,
                        engine_min: nil,
                        compiled_at: nil,
                        expr: .and([
                            .eventsExists(
                                name: SystemEventNames.notificationsEnabled,
                                since: nil,
                                until: nil,
                                within: nil,
                                where_: .pred(
                                    op: "eq",
                                    key: "journey_id",
                                    value: .journeyId
                                )
                            ),
                            .user(op: "eq", key: "plan", value: .string("pro"))
                        ])
                    ),
                    window: 60
                )
                let campaign = makeCampaign(
                    id: "camp-mixed",
                    flowId: "flow-mixed",
                    goal: notificationGoal,
                    exitPolicy: nil
                )

                await primeProfile(
                    campaigns: [campaign],
                    flows: [makeFlow(flowId: "flow-mixed")]
                )
                await service.initialize()
                mocks.identityService.setUserProperty("plan", value: "pro")

                let journey = await startJourney()
                expect(journey.convertedAt).to(beNil())

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    (await service.getActiveJourneys(for: distinctId).first {
                        $0.id == journey.id
                    })?.convertedAt
                }.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("processes active journeys before presenting scoped gate flows") {
                let ordering = OrderingRecorder()
                let orderingStore = OrderingJourneyStore(recorder: ordering)
                let orderingPresentationService = OrderingFlowPresentationService(recorder: ordering)
                orderingPresentationService.defaultMockViewController = controller
                Container.shared.flowPresentationService.register { @MainActor in orderingPresentationService }
                service = JourneyService(journeyStore: orderingStore)
                journeyStore = orderingStore

                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()

                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                journey.flowState.pendingAction = FlowPendingAction(
                    interactionId: "wait-notifications",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                )
                mocks.eventService.trackWithResponseResult = makeGatePlanResponse(
                    decision: "show_flow",
                    flowId: "gate-flow"
                )

                ordering.clear()

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    ordering.events
                }.toEventually(equal(["complete:\(campaignId)", "present:gate-flow"]), timeout: .seconds(2))
            }

            it("does not present scoped require_feature cache-only flows on deny") {
                let orderingPresentationService = OrderingFlowPresentationService(recorder: OrderingRecorder())
                orderingPresentationService.defaultMockViewController = controller
                Container.shared.flowPresentationService.register { @MainActor in orderingPresentationService }

                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                let baselinePresentations = orderingPresentationService.presentFlowCallCount
                mocks.eventService.trackWithResponseResult = makeGatePlanResponse(
                    decision: "require_feature",
                    flowId: "gate-flow",
                    featureId: "premium",
                    policy: "cache_only"
                )

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    orderingPresentationService.presentFlowCallCount
                }.toEventually(equal(baselinePresentations), timeout: .seconds(2))
                expect(orderingPresentationService.wasFlowPresented("gate-flow")).to(beFalse())
            }
        }
    }
}

private final class DelayedRequestPermissionAuthorizationHandler: PermissionAuthorizationHandling {
    let initialStatus: PermissionAuthorizationStatus
    let delayNanoseconds: UInt64
    let result: PermissionAuthorizationStatus

    init(
        initialStatus: PermissionAuthorizationStatus,
        delayNanoseconds: UInt64,
        result: PermissionAuthorizationStatus
    ) {
        self.initialStatus = initialStatus
        self.delayNanoseconds = delayNanoseconds
        self.result = result
    }

    func authorizationStatus() -> PermissionAuthorizationStatus {
        initialStatus
    }

    func requestAuthorization() async -> PermissionAuthorizationStatus {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return result
    }
}

private final class UnsupportedRequestPermissionAuthorizationHandler: PermissionAuthorizationHandling {
    func authorizationStatus() -> PermissionAuthorizationStatus {
        .unsupported
    }

    func requestAuthorization() async -> PermissionAuthorizationStatus {
        .unsupported
    }
}
