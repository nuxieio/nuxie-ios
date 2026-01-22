import Foundation
import FactoryKit

final class FlowJourneyRunner {
    struct TriggerContext {
        let screenId: String?
        let componentId: String?
        let interactionId: String?
    }

    enum RunOutcome {
        case paused(FlowPendingAction)
        case exited(JourneyExitReason)
    }

    private enum ActionResult {
        case `continue`
        case stopSequence
        case pause(FlowPendingAction)
        case exit(JourneyExitReason)
    }

    private struct ActionRequest {
        let actions: [InteractionAction]
        let context: TriggerContext
    }

    private struct ResumeContext {
        let pending: FlowPendingAction
        let reason: ResumeReason
        let event: NuxieEvent?
    }

    private let journey: Journey
    private let campaign: Campaign
    private let flow: Flow
    private let remoteFlow: RemoteFlow
    private let viewModels: FlowViewModelRuntime

    @Injected(\.eventService) private var eventService: EventServiceProtocol
    @Injected(\.identityService) private var identityService: IdentityServiceProtocol
    @Injected(\.segmentService) private var segmentService: SegmentServiceProtocol
    @Injected(\.featureService) private var featureService: FeatureServiceProtocol
    @Injected(\.profileService) private var profileService: ProfileServiceProtocol
    @Injected(\.dateProvider) private var dateProvider: DateProviderProtocol
    @Injected(\.irRuntime) private var irRuntime: IRRuntime
    @Injected(\.outcomeBroker) private var outcomeBroker: OutcomeBrokerProtocol

    weak var viewController: FlowViewController?
    var onShowScreen: ((String, AnyCodable?) async -> Void)?
    private(set) var isRuntimeReady = false

    private var interactionsByScreen: [String: [Interaction]] = [:]
    private var interactionsByComponent: [String: [Interaction]] = [:]
    private var pathIndexByIds: [String: String] = [:]

    private var actionQueue: [ActionRequest] = []
    private var activeRequest: ActionRequest?
    private var activeIndex: Int = 0
    private var isProcessing = false
    private var isPaused = false
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var triggerResetTasks: [String: Task<Void, Never>] = [:]

    init(
        journey: Journey,
        campaign: Campaign,
        flow: Flow,
        viewController: FlowViewController? = nil
    ) {
        self.journey = journey
        self.campaign = campaign
        self.flow = flow
        self.remoteFlow = flow.remoteFlow
        self.viewModels = FlowViewModelRuntime(remoteFlow: flow.remoteFlow)
        self.viewController = viewController

        let interactions = flow.remoteFlow.interactions
        self.interactionsByScreen = interactions.screens
        self.interactionsByComponent = interactions.components ?? [:]

        if let index = flow.remoteFlow.pathIndex {
            for (path, entry) in index {
                let key = "ids:\(entry.pathIds.map(String.init).joined(separator: "."))"
                pathIndexByIds[key] = path
            }
        }

        if let snapshot = journey.flowState.viewModelSnapshot {
            viewModels.hydrate(snapshot)
        } else {
            journey.flowState.viewModelSnapshot = viewModels.getSnapshot()
        }
    }

    func attach(viewController: FlowViewController) {
        self.viewController = viewController
    }

    func handleRuntimeReady() async -> RunOutcome? {
        isRuntimeReady = true
        sendViewModelInit()

        if let current = journey.flowState.currentScreenId {
            await sendShowScreen(current)
            return nil
        }

        if journey.flowState.pendingAction == nil {
            let outcome = await runEntryActionsIfNeeded()
            if let outcome {
                return outcome
            }

            if journey.flowState.currentScreenId == nil {
                let fallback = remoteFlow.entryScreenId ?? remoteFlow.screens.first?.id
                if let fallback {
                    await navigate(to: fallback, transition: nil)
                }
            }
        }

        return nil
    }

    func handleScreenChanged(_ screenId: String) async -> RunOutcome? {
        journey.flowState.currentScreenId = screenId
        journey.flowState.pendingAfterDelay = buildAfterDelayTriggers(for: screenId)
        return await dispatchTrigger(
            trigger: .screenShown,
            screenId: screenId,
            componentId: nil,
            event: nil
        )
    }

    func handleViewModelChanged(
        path: VmPathRef,
        value: Any,
        source: String?,
        screenId: String?
    ) async -> RunOutcome? {
        let resolvedScreenId = screenId ?? journey.flowState.currentScreenId
        _ = viewModels.setValue(path: path, value: value, screenId: resolvedScreenId)
        journey.flowState.viewModelSnapshot = viewModels.getSnapshot()

        let outcome = await dispatchViewModelChanged(path: path, value: value, screenId: resolvedScreenId)
        scheduleTriggerReset(path: path, screenId: resolvedScreenId)
        return outcome
    }

    func dispatchEventTrigger(_ event: NuxieEvent) async -> RunOutcome? {
        return await dispatchTrigger(
            trigger: .event(eventName: event.name, filter: nil),
            screenId: journey.flowState.currentScreenId,
            componentId: nil,
            event: event
        )
    }

    func dispatchTrigger(
        trigger: InteractionTrigger,
        screenId: String?,
        componentId: String?,
        event: NuxieEvent?
    ) async -> RunOutcome? {
        if isPaused { return nil }

        var interactions: [Interaction] = []
        if let componentId {
            interactions.append(contentsOf: interactionsByComponent[componentId] ?? [])
        }
        if let screenId {
            interactions.append(contentsOf: interactionsByScreen[screenId] ?? [])
        }

        if interactions.isEmpty { return nil }

        for interaction in interactions {
            if interaction.enabled == false { continue }
            if !matchesTrigger(interaction.trigger, trigger) { continue }

            if case .event(let expectedName, let filter) = interaction.trigger,
               case .event(let actualName, _) = trigger {
                if expectedName != actualName { continue }
                if let filter {
                    let ok = await evalConditionIR(filter, event: event)
                    if !ok { continue }
                }
            }

            if case .viewModelChanged = interaction.trigger {
                continue
            }

            enqueueActions(
                interaction.actions,
                context: TriggerContext(
                    screenId: screenId,
                    componentId: componentId,
                    interactionId: interaction.id
                )
            )
        }

        return await processQueue(resumeContext: nil)
    }

    func resumePendingAction(reason: ResumeReason, event: NuxieEvent?) async -> RunOutcome? {
        guard let pending = journey.flowState.pendingAction else { return nil }

        isPaused = false
        journey.flowState.pendingAction = nil

        guard let actions = resolveActions(
            interactionId: pending.interactionId,
            screenId: pending.screenId,
            componentId: pending.componentId
        ) else {
            return nil
        }

        let context = TriggerContext(
            screenId: pending.screenId,
            componentId: pending.componentId,
            interactionId: pending.interactionId
        )

        activeRequest = ActionRequest(actions: actions, context: context)
        if pending.kind == .delay {
            activeIndex = pending.actionIndex + 1
        } else {
            activeIndex = pending.actionIndex
        }

        let resumeContext = ResumeContext(pending: pending, reason: reason, event: event)
        return await processQueue(resumeContext: resumeContext)
    }

    func dispatchAfterDelay(interactionId: String, screenId: String) async -> RunOutcome? {
        guard journey.flowState.currentScreenId == screenId else { return nil }
        guard let interactions = interactionsByScreen[screenId] else { return nil }
        guard let interaction = interactions.first(where: { $0.id == interactionId }) else { return nil }
        guard case .afterDelay = interaction.trigger else { return nil }

        journey.flowState.pendingAfterDelay.removeAll { $0.interactionId == interactionId }

        enqueueActions(
            interaction.actions,
            context: TriggerContext(
                screenId: screenId,
                componentId: nil,
                interactionId: interactionId
            )
        )
        return await processQueue(resumeContext: nil)
    }

    func clearDebounces() {
        for (_, task) in debounceTasks {
            task.cancel()
        }
        debounceTasks.removeAll()
    }

    func hasPendingWork() -> Bool {
        if journey.flowState.pendingAction != nil { return true }
        if !journey.flowState.pendingAfterDelay.isEmpty { return true }
        if activeRequest != nil { return true }
        if !actionQueue.isEmpty { return true }
        return false
    }

    private func runEntryActionsIfNeeded() async -> RunOutcome? {
        let actions = remoteFlow.entryActions ?? []
        guard !actions.isEmpty else { return nil }

        enqueueActions(
            actions,
            context: TriggerContext(
                screenId: journey.flowState.currentScreenId,
                componentId: nil,
                interactionId: "entry"
            )
        )

        return await processQueue(resumeContext: nil)
    }

    private func enqueueActions(_ actions: [InteractionAction], context: TriggerContext) {
        guard !actions.isEmpty else { return }
        actionQueue.append(ActionRequest(actions: actions, context: context))
    }

    private func processQueue(resumeContext: ResumeContext?) async -> RunOutcome? {
        if isProcessing { return nil }
        isProcessing = true
        defer { isProcessing = false }

        var resumeContext = resumeContext

        while !isPaused {
            if activeRequest == nil {
                guard !actionQueue.isEmpty else { return nil }
                activeRequest = actionQueue.removeFirst()
                activeIndex = 0
            }

            guard let request = activeRequest else { return nil }

            while activeIndex < request.actions.count {
                let action = request.actions[activeIndex]
                let actionResult = await executeAction(
                    action,
                    context: request.context,
                    index: activeIndex,
                    resumeContext: resumeContext
                )

                resumeContext = nil

                switch actionResult {
                case .continue:
                    activeIndex += 1
                case .stopSequence:
                    activeRequest = nil
                    activeIndex = 0
                    break
                case .pause(let pending):
                    isPaused = true
                    journey.flowState.pendingAction = pending
                    return .paused(pending)
                case .exit(let reason):
                    return .exited(reason)
                }

                if case .stopSequence = actionResult {
                    break
                }
            }

            if activeIndex >= request.actions.count {
                activeRequest = nil
                activeIndex = 0
            }
        }

        return nil
    }

    private func executeAction(
        _ action: InteractionAction,
        context: TriggerContext,
        index: Int,
        resumeContext: ResumeContext?
    ) async -> ActionResult {
        do {
            switch action {
            case .navigate(let navigate):
                await navigateToAction(navigate, context: context)
                trackAction(action, context: context, error: nil)
                return .stopSequence
            case .back(let back):
                await handleBack(back)
                trackAction(action, context: context, error: nil)
                return .stopSequence
            case .delay(let delay):
                let result = handleDelay(delay, context: context, index: index, resumeContext: resumeContext)
                trackAction(action, context: context, error: nil)
                return result
            case .timeWindow(let timeWindow):
                let result = await handleTimeWindow(timeWindow, context: context, index: index, resumeContext: resumeContext)
                trackAction(action, context: context, error: nil)
                return result
            case .waitUntil(let waitUntil):
                let result = await handleWaitUntil(waitUntil, context: context, index: index, resumeContext: resumeContext)
                trackAction(action, context: context, error: nil)
                return result
            case .condition(let condition):
                let result = await handleCondition(condition, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .experiment(let experiment):
                let result = await handleExperiment(experiment, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .sendEvent(let sendEvent):
                await handleSendEvent(sendEvent, context: context)
                trackAction(action, context: context, error: nil)
                return .continue
            case .updateCustomer(let updateCustomer):
                handleUpdateCustomer(updateCustomer, context: context)
                trackAction(action, context: context, error: nil)
                return .continue
            case .callDelegate(let callDelegate):
                handleCallDelegate(callDelegate, context: context)
                trackAction(action, context: context, error: nil)
                return .continue
            case .remote(let remote):
                let result = await handleRemote(remote, context: context, index: index)
                trackAction(action, context: context, error: nil)
                return result
            case .setViewModel(let setViewModel):
                let result = await handleSetViewModel(setViewModel, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .fireTrigger(let fireTrigger):
                let result = await handleFireTrigger(fireTrigger, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .listInsert(let listInsert):
                let result = await handleListInsert(listInsert, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .listRemove(let listRemove):
                let result = await handleListRemove(listRemove, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .listSwap(let listSwap):
                let result = await handleListSwap(listSwap, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .listMove(let listMove):
                let result = await handleListMove(listMove, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .listSet(let listSet):
                let result = await handleListSet(listSet, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .listClear(let listClear):
                let result = await handleListClear(listClear, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .exit(let exitAction):
                trackAction(action, context: context, error: nil)
                return .exit(mapExitReason(exitAction.reason))
            case .unknown:
                return .continue
            }
        } catch {
            trackAction(action, context: context, error: error.localizedDescription)
            return .exit(.error)
        }
    }

    private func navigateToAction(_ action: NavigateAction, context: TriggerContext) async {
        guard !action.screenId.isEmpty else { return }
        await navigate(to: action.screenId, transition: action.transition)
    }

    private func navigate(to screenId: String, transition: AnyCodable?) async {
        if let current = journey.flowState.currentScreenId, current != screenId {
            _ = await dispatchTrigger(
                trigger: .screenDismissed(method: nil),
                screenId: current,
                componentId: nil,
                event: nil
            )
            journey.flowState.navigationStack.append(current)
        }
        await sendShowScreen(screenId, transition: transition)
    }

    private func handleBack(_ action: BackAction) async {
        let steps = max(1, action.steps ?? 1)
        guard !journey.flowState.navigationStack.isEmpty else { return }

        var stack = journey.flowState.navigationStack
        let targetIndex = max(0, stack.count - steps)
        let target = stack[targetIndex]
        stack = Array(stack.prefix(targetIndex))
        journey.flowState.navigationStack = stack
        await sendShowScreen(target, transition: nil)
    }

    private func handleDelay(
        _ action: DelayAction,
        context: TriggerContext,
        index: Int,
        resumeContext: ResumeContext?
    ) -> ActionResult {
        if resumeContext?.pending.kind == .delay {
            return .continue
        }
        let durationMs = max(0, action.durationMs)
        if durationMs <= 0 { return .continue }
        let resumeAt = dateProvider.date(byAddingTimeInterval: TimeInterval(durationMs) / 1000, to: dateProvider.now())
        return .pause(makePendingAction(
            kind: .delay,
            context: context,
            index: index,
            resumeAt: resumeAt,
            condition: nil,
            maxTimeMs: nil
        ))
    }

    private func handleTimeWindow(
        _ action: TimeWindowAction,
        context: TriggerContext,
        index: Int,
        resumeContext: ResumeContext?
    ) async -> ActionResult {
        let now = dateProvider.now()
        let tz = TimeZone(identifier: action.timezone) ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        guard let startHM = parseTime(action.startTime),
              let endHM = parseTime(action.endTime),
              let sh = startHM.hour, let sm = startHM.minute,
              let eh = endHM.hour, let em = endHM.minute
        else {
            return .continue
        }

        let weekday = cal.component(.weekday, from: now)
        if let days = action.daysOfWeek, !days.isEmpty, !days.contains(weekday) {
            let nextValid = calculateNextValidDay(from: now, validDays: days, timezone: tz)
            return .pause(makePendingAction(
                kind: .timeWindow,
                context: context,
                index: index,
                resumeAt: nextValid,
                condition: nil,
                maxTimeMs: nil
            ))
        }

        let currentHM = cal.dateComponents([.hour, .minute], from: now)
        let curMin = (currentHM.hour ?? 0) * 60 + (currentHM.minute ?? 0)
        let startMin = sh * 60 + sm
        let endMin = eh * 60 + em

        if startMin == endMin {
            return .continue
        }

        let inWindow =
            (startMin <= endMin)
            ? (curMin >= startMin && curMin < endMin)
            : (curMin >= startMin || curMin < endMin)

        if inWindow {
            return .continue
        }

        let nextOpen = calculateNextWindowOpen(
            from: now,
            startTime: action.startTime,
            timezone: tz,
            validDays: action.daysOfWeek
        )

        return .pause(makePendingAction(
            kind: .timeWindow,
            context: context,
            index: index,
            resumeAt: nextOpen,
            condition: nil,
            maxTimeMs: nil
        ))
    }

    private func handleWaitUntil(
        _ action: WaitUntilAction,
        context: TriggerContext,
        index: Int,
        resumeContext: ResumeContext?
    ) async -> ActionResult {
        let now = dateProvider.now()
        let condition = action.condition ?? resumeContext?.pending.condition
        let event = resumeContext?.event

        let ok = await evalConditionIR(condition, event: event)
        if ok {
            return .continue
        }

        let maxTimeMs = action.maxTimeMs ?? resumeContext?.pending.maxTimeMs
        let startedAt = resumeContext?.pending.startedAt ?? now

        if let maxTimeMs {
            let deadline = startedAt.addingTimeInterval(TimeInterval(maxTimeMs) / 1000)
            if now >= deadline {
                return .continue
            }
            return .pause(makePendingAction(
                kind: .waitUntil,
                context: context,
                index: index,
                resumeAt: deadline,
                condition: condition,
                maxTimeMs: maxTimeMs,
                startedAt: startedAt
            ))
        }

        return .pause(makePendingAction(
            kind: .waitUntil,
            context: context,
            index: index,
            resumeAt: nil,
            condition: condition,
            maxTimeMs: nil,
            startedAt: startedAt
        ))
    }

    private func handleCondition(
        _ action: ConditionAction,
        context: TriggerContext
    ) async -> ActionResult {
        for branch in action.branches {
            let ok = await evalConditionIR(branch.condition, event: nil)
            if ok {
                let result = await runNestedActions(branch.actions, context: context)
                return result
            }
        }

        if let defaults = action.defaultActions {
            return await runNestedActions(defaults, context: context)
        }

        return .continue
    }

    private func handleExperiment(
        _ action: ExperimentAction,
        context: TriggerContext
    ) async -> ActionResult {
        guard !action.variants.isEmpty else { return .continue }

        guard let variant = await resolveExperimentVariant(action) else {
            return .continue
        }

        journey.setContext("_experiment_id", value: action.experimentId)
        journey.setContext("_variant_id", value: variant.id)

        eventService.track(
            JourneyEvents.experimentVariantAssigned,
            properties: JourneyEvents.experimentVariantAssignedProperties(
                journey: journey,
                experimentId: action.experimentId,
                variantId: variant.id
            ),
            userProperties: nil,
            userPropertiesSetOnce: nil,
            completion: nil
        )

        let result = await runNestedActions(variant.actions, context: context)
        return result
    }

    private func handleSendEvent(
        _ action: SendEventAction,
        context: TriggerContext
    ) async {
        var properties: [String: Any] = [:]
        if let props = action.properties {
            for (key, value) in props { properties[key] = value.value }
        }
        properties["journeyId"] = journey.id
        properties["campaignId"] = journey.campaignId
        if let screenId = context.screenId ?? journey.flowState.currentScreenId {
            properties["screenId"] = screenId
        }

        eventService.track(
            action.eventName,
            properties: properties,
            userProperties: nil,
            userPropertiesSetOnce: nil,
            completion: nil
        )

        eventService.track(
            JourneyEvents.eventSent,
            properties: JourneyEvents.eventSentProperties(
                journey: journey,
                screenId: context.screenId ?? journey.flowState.currentScreenId,
                eventName: action.eventName,
                eventProperties: properties
            ),
            userProperties: nil,
            userPropertiesSetOnce: nil,
            completion: nil
        )
    }

    private func handleUpdateCustomer(
        _ action: UpdateCustomerAction,
        context: TriggerContext
    ) {
        var attributes: [String: Any] = [:]
        for (key, value) in action.attributes {
            attributes[key] = value.value
        }

        identityService.setUserProperties(attributes)

        eventService.track(
            JourneyEvents.customerUpdated,
            properties: JourneyEvents.customerUpdatedProperties(
                journey: journey,
                screenId: context.screenId ?? journey.flowState.currentScreenId,
                attributesUpdated: Array(attributes.keys)
            ),
            userProperties: nil,
            userPropertiesSetOnce: nil,
            completion: nil
        )
    }

    private func handleCallDelegate(
        _ action: CallDelegateAction,
        context: TriggerContext
    ) {
        var userInfo: [String: Any] = [
            "message": action.message,
            "journeyId": journey.id,
            "campaignId": journey.campaignId,
        ]
        if let payload = action.payload?.value {
            userInfo["payload"] = payload
        }

        NotificationCenter.default.post(
            name: .nuxieCallDelegate,
            object: nil,
            userInfo: userInfo
        )

        eventService.track(
            JourneyEvents.delegateCalled,
            properties: JourneyEvents.delegateCalledProperties(
                journey: journey,
                screenId: context.screenId ?? journey.flowState.currentScreenId,
                message: action.message,
                payload: action.payload?.value
            ),
            userProperties: nil,
            userPropertiesSetOnce: nil,
            completion: nil
        )
    }

    private func handleRemote(
        _ action: RemoteAction,
        context: TriggerContext,
        index: Int
    ) async -> ActionResult {
        let nodeId = context.interactionId ?? context.screenId ?? journey.flowState.currentScreenId ?? "unknown"
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let payload: [String: Any] = [
            "session_id": journey.id,
            "node_id": nodeId,
            "screen_id": screenId as Any,
            "node_data": [
                "type": "remote",
                "data": [
                    "action": action.action,
                    "payload": action.payload.value as Any,
                    "async": action.async ?? false,
                ],
            ],
            "context": journey.context.mapValues { $0.value },
        ]

        if action.async == true {
            eventService.track(
                "$journey_node_executed",
                properties: payload,
                userProperties: nil,
                userPropertiesSetOnce: nil,
                completion: nil
            )
            return .continue
        }

        do {
            let response = try await eventService.trackWithResponse(
                "$journey_node_executed",
                properties: payload
            )

            if let execution = response.execution {
                if execution.success {
                    if let updates = execution.contextUpdates {
                        for (key, value) in updates {
                            journey.setContext(key, value: value.value)
                        }
                    }
                    return .continue
                }

                if let error = execution.error {
                    if error.retryable {
                        let retryAfter = TimeInterval(error.retryAfter ?? 5)
                        let resumeAt = dateProvider.date(byAddingTimeInterval: retryAfter, to: dateProvider.now())
                        return .pause(makePendingAction(
                            kind: .remoteRetry,
                            context: context,
                            index: index,
                            resumeAt: resumeAt,
                            condition: nil,
                            maxTimeMs: nil
                        ))
                    }
                    return .exit(.error)
                }
            }

            return .continue
        } catch {
            let resumeAt = dateProvider.date(byAddingTimeInterval: 5, to: dateProvider.now())
            return .pause(makePendingAction(
                kind: .remoteRetry,
                context: context,
                index: index,
                resumeAt: resumeAt,
                condition: nil,
                maxTimeMs: nil
            ))
        }
    }

    private func handleSetViewModel(
        _ action: SetViewModelAction,
        context: TriggerContext
    ) async -> ActionResult {
        let resolvedValue = resolveValueRefs(action.value.value, context: context)
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        _ = viewModels.setValue(path: action.path, value: resolvedValue, screenId: screenId)
        journey.flowState.viewModelSnapshot = viewModels.getSnapshot()

        sendViewModelPatch(path: action.path, value: resolvedValue, source: "host")

        _ = await dispatchViewModelChanged(path: action.path, value: resolvedValue, screenId: screenId)
        scheduleTriggerReset(path: action.path, screenId: screenId)

        return .continue
    }

    private func handleFireTrigger(
        _ action: FireTriggerAction,
        context: TriggerContext
    ) async -> ActionResult {
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let timestamp = Int(dateProvider.now().timeIntervalSince1970 * 1000)
        _ = viewModels.setValue(path: action.path, value: timestamp, screenId: screenId)
        journey.flowState.viewModelSnapshot = viewModels.getSnapshot()

        sendViewModelTrigger(path: action.path, value: timestamp)

        _ = await dispatchViewModelChanged(path: action.path, value: timestamp, screenId: screenId)
        scheduleTriggerReset(path: action.path, screenId: screenId)

        return .continue
    }

    private func handleListInsert(
        _ action: ListInsertAction,
        context: TriggerContext
    ) async -> ActionResult {
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let resolvedValue = resolveValueRefs(action.value.value, context: context)
        var payload: [String: Any] = ["value": resolvedValue]
        if let index = action.index {
            payload["index"] = index
        }

        let ok = viewModels.setListValue(
            path: action.path,
            operation: "insert",
            payload: payload,
            screenId: screenId
        )

        if ok {
            journey.flowState.viewModelSnapshot = viewModels.getSnapshot()
            sendViewModelListOperation(op: "insert", path: action.path, payload: payload)
            let updatedValue = viewModels.getValue(path: action.path, screenId: screenId) ?? NSNull()
            _ = await dispatchViewModelChanged(path: action.path, value: updatedValue, screenId: screenId)
        }

        return .continue
    }

    private func handleListRemove(
        _ action: ListRemoveAction,
        context: TriggerContext
    ) async -> ActionResult {
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let payload: [String: Any] = ["index": action.index]

        let ok = viewModels.setListValue(
            path: action.path,
            operation: "remove",
            payload: payload,
            screenId: screenId
        )

        if ok {
            journey.flowState.viewModelSnapshot = viewModels.getSnapshot()
            sendViewModelListOperation(op: "remove", path: action.path, payload: payload)
            let updatedValue = viewModels.getValue(path: action.path, screenId: screenId) ?? NSNull()
            _ = await dispatchViewModelChanged(path: action.path, value: updatedValue, screenId: screenId)
        }

        return .continue
    }

    private func handleListSwap(
        _ action: ListSwapAction,
        context: TriggerContext
    ) async -> ActionResult {
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let payload: [String: Any] = [
            "from": action.indexA,
            "to": action.indexB
        ]

        let ok = viewModels.setListValue(
            path: action.path,
            operation: "swap",
            payload: payload,
            screenId: screenId
        )

        if ok {
            journey.flowState.viewModelSnapshot = viewModels.getSnapshot()
            sendViewModelListOperation(op: "swap", path: action.path, payload: payload)
            let updatedValue = viewModels.getValue(path: action.path, screenId: screenId) ?? NSNull()
            _ = await dispatchViewModelChanged(path: action.path, value: updatedValue, screenId: screenId)
        }

        return .continue
    }

    private func handleListMove(
        _ action: ListMoveAction,
        context: TriggerContext
    ) async -> ActionResult {
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let payload: [String: Any] = [
            "from": action.from,
            "to": action.to
        ]

        let ok = viewModels.setListValue(
            path: action.path,
            operation: "move",
            payload: payload,
            screenId: screenId
        )

        if ok {
            journey.flowState.viewModelSnapshot = viewModels.getSnapshot()
            sendViewModelListOperation(op: "move", path: action.path, payload: payload)
            let updatedValue = viewModels.getValue(path: action.path, screenId: screenId) ?? NSNull()
            _ = await dispatchViewModelChanged(path: action.path, value: updatedValue, screenId: screenId)
        }

        return .continue
    }

    private func handleListSet(
        _ action: ListSetAction,
        context: TriggerContext
    ) async -> ActionResult {
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let resolvedValue = resolveValueRefs(action.value.value, context: context)
        let payload: [String: Any] = [
            "index": action.index,
            "value": resolvedValue
        ]

        let ok = viewModels.setListValue(
            path: action.path,
            operation: "set",
            payload: payload,
            screenId: screenId
        )

        if ok {
            journey.flowState.viewModelSnapshot = viewModels.getSnapshot()
            sendViewModelListOperation(op: "set", path: action.path, payload: payload)
            let updatedValue = viewModels.getValue(path: action.path, screenId: screenId) ?? NSNull()
            _ = await dispatchViewModelChanged(path: action.path, value: updatedValue, screenId: screenId)
        }

        return .continue
    }

    private func handleListClear(
        _ action: ListClearAction,
        context: TriggerContext
    ) async -> ActionResult {
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let payload: [String: Any] = [:]

        let ok = viewModels.setListValue(
            path: action.path,
            operation: "clear",
            payload: payload,
            screenId: screenId
        )

        if ok {
            journey.flowState.viewModelSnapshot = viewModels.getSnapshot()
            sendViewModelListOperation(op: "clear", path: action.path, payload: payload)
            let updatedValue = viewModels.getValue(path: action.path, screenId: screenId) ?? NSNull()
            _ = await dispatchViewModelChanged(path: action.path, value: updatedValue, screenId: screenId)
        }

        return .continue
    }

    private func runNestedActions(
        _ actions: [InteractionAction],
        context: TriggerContext
    ) async -> ActionResult {
        guard !actions.isEmpty else { return .continue }

        for (index, action) in actions.enumerated() {
            let result = await executeAction(action, context: context, index: index, resumeContext: nil)
            switch result {
            case .continue:
                continue
            case .stopSequence, .pause, .exit:
                return result
            }
        }

        return .continue
    }

    private func dispatchViewModelChanged(
        path: VmPathRef,
        value: Any,
        screenId: String?
    ) async -> RunOutcome? {
        let interactions = (screenId != nil) ? (interactionsByScreen[screenId!] ?? []) : []
        if interactions.isEmpty { return nil }

        for interaction in interactions {
            if interaction.enabled == false { continue }
            guard case .viewModelChanged(let triggerPath, let debounceMs) = interaction.trigger else { continue }
            if !matchesViewModelPath(triggerPath: triggerPath, inputPath: path) { continue }

            if let debounceMs, debounceMs > 0 {
                let key = triggerPath.normalizedPath
                debounceTasks[key]?.cancel()
                debounceTasks[key] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(debounceMs) * 1_000_000)
                    guard let self else { return }
                    self.enqueueActions(
                        interaction.actions,
                        context: TriggerContext(
                            screenId: screenId,
                            componentId: nil,
                            interactionId: interaction.id
                        )
                    )
                    _ = await self.processQueue(resumeContext: nil)
                }
            } else {
                enqueueActions(
                    interaction.actions,
                    context: TriggerContext(
                        screenId: screenId,
                        componentId: nil,
                        interactionId: interaction.id
                    )
                )
            }
        }

        return await processQueue(resumeContext: nil)
    }

    private func scheduleTriggerReset(path: VmPathRef, screenId: String?) {
        guard viewModels.isTriggerPath(path: path, screenId: screenId) else { return }
        let key = path.normalizedPath
        triggerResetTasks[key]?.cancel()
        triggerResetTasks[key] = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            _ = self.viewModels.setValue(path: path, value: 0, screenId: screenId)
            self.journey.flowState.viewModelSnapshot = self.viewModels.getSnapshot()
            self.sendViewModelTrigger(path: path, value: 0)
        }
    }

    private func resolveActions(
        interactionId: String,
        screenId: String?,
        componentId: String?
    ) -> [InteractionAction]? {
        if interactionId == "entry" {
            return remoteFlow.entryActions ?? []
        }

        if let screenId,
           let list = interactionsByScreen[screenId],
           let match = list.first(where: { $0.id == interactionId }) {
            return match.actions
        }

        if let componentId,
           let list = interactionsByComponent[componentId],
           let match = list.first(where: { $0.id == interactionId }) {
            return match.actions
        }

        for (_, list) in interactionsByScreen {
            if let match = list.first(where: { $0.id == interactionId }) {
                return match.actions
            }
        }
        for (_, list) in interactionsByComponent {
            if let match = list.first(where: { $0.id == interactionId }) {
                return match.actions
            }
        }

        return nil
    }

    private func buildAfterDelayTriggers(for screenId: String) -> [FlowAfterDelaySnapshot] {
        let now = dateProvider.now()
        guard let interactions = interactionsByScreen[screenId] else { return [] }

        return interactions.compactMap { interaction in
            guard interaction.enabled != false else { return nil }
            guard case .afterDelay(let delayMs) = interaction.trigger else { return nil }
            let fireAt = dateProvider.date(byAddingTimeInterval: TimeInterval(delayMs) / 1000, to: now)
            return FlowAfterDelaySnapshot(
                interactionId: interaction.id,
                screenId: screenId,
                fireAt: fireAt
            )
        }
    }

    private func makePendingAction(
        kind: FlowPendingActionKind,
        context: TriggerContext,
        index: Int,
        resumeAt: Date?,
        condition: IREnvelope?,
        maxTimeMs: Int?,
        startedAt: Date? = nil
    ) -> FlowPendingAction {
        FlowPendingAction(
            interactionId: context.interactionId ?? "entry",
            screenId: context.screenId,
            componentId: context.componentId,
            actionIndex: index,
            kind: kind,
            resumeAt: resumeAt,
            condition: condition,
            maxTimeMs: maxTimeMs,
            startedAt: startedAt ?? dateProvider.now()
        )
    }

    private func mapExitReason(_ reason: String?) -> JourneyExitReason {
        switch reason {
        case "goal_met":
            return .goalMet
        case "expired":
            return .expired
        case "error":
            return .error
        case "cancelled":
            return .cancelled
        default:
            return .completed
        }
    }

    private func trackAction(_ action: InteractionAction, context: TriggerContext, error: String?) {
        eventService.track(
            JourneyEvents.journeyAction,
            properties: JourneyEvents.journeyActionProperties(
                journey: journey,
                screenId: context.screenId ?? journey.flowState.currentScreenId,
                interactionId: context.interactionId,
                actionType: action.actionType,
                error: error
            ),
            userProperties: nil,
            userPropertiesSetOnce: nil,
            completion: nil
        )
    }

    private func sendViewModelInit() {
        guard let controller = viewController else { return }
        let payload: [String: Any] = [
            "viewModels": encodeJSON(remoteFlow.viewModels) ?? [],
            "instances": encodeJSON(viewModels.allInstances()) ?? [],
            "converters": remoteFlow.converters?.mapValues { value in
                value.mapValues { $0.value }
            } ?? [:],
            "screenDefaults": viewModels.screenDefaultsPayload(),
            "pathIndex": encodeJSON(remoteFlow.pathIndex ?? [:]) ?? [:],
        ]

        Task { @MainActor in
            controller.sendRuntimeMessage(type: "runtime/view_model_init", payload: payload)
        }
    }

    private func sendViewModelPatch(path: VmPathRef, value: Any, source: String?) {
        guard let controller = viewController else { return }
        var payload: [String: Any] = [
            "value": value,
        ]
        appendPathPayload(&payload, path: path)
        if let source {
            payload["source"] = source
        }

        Task { @MainActor in
            controller.sendRuntimeMessage(type: "runtime/view_model_patch", payload: payload)
        }
    }

    private func sendViewModelListOperation(op: String, path: VmPathRef, payload: [String: Any]) {
        guard let controller = viewController else { return }
        var message = payload
        appendPathPayload(&message, path: path)

        Task { @MainActor in
            controller.sendRuntimeMessage(type: "runtime/view_model_list_\(op)", payload: message)
        }
    }

    private func sendViewModelTrigger(path: VmPathRef, value: Any?) {
        guard let controller = viewController else { return }
        var payload: [String: Any] = [:]
        appendPathPayload(&payload, path: path)
        if let value {
            payload["value"] = value
        }

        Task { @MainActor in
            controller.sendRuntimeMessage(type: "runtime/view_model_trigger", payload: payload)
        }
    }

    private func sendShowScreen(_ screenId: String, transition: AnyCodable? = nil) async {
        if let onShowScreen {
            await onShowScreen(screenId, transition)
            return
        }
        guard let controller = viewController else { return }
        var payload: [String: Any] = ["screenId": screenId]
        if let transition {
            payload["transition"] = transition.value
        }
        await MainActor.run {
            controller.sendRuntimeMessage(type: "runtime/show_screen", payload: payload)
        }
    }

    private func appendPathPayload(_ payload: inout [String: Any], path: VmPathRef) {
        let normalized = path.normalizedPath
        if let ids = parseIds(normalized) {
            payload["pathIds"] = ids
        }

        if let pathString = pathString(for: path) {
            payload["path"] = pathString
        } else if !normalized.hasPrefix("ids:") {
            payload["path"] = normalized
        }
    }

    private func matchesTrigger(
        _ interactionTrigger: InteractionTrigger,
        _ inputTrigger: InteractionTrigger
    ) -> Bool {
        switch (interactionTrigger, inputTrigger) {
        case (.tap, .tap),
             (.hover, .hover),
             (.press, .press),
             (.screenShown, .screenShown),
             (.afterDelay, .afterDelay),
             (.manual, .manual):
            return true
        case (.longPress, .longPress):
            return true
        case (.drag(let dir, let threshold), .drag(let inputDir, let inputThreshold)):
            if let dir, let inputDir, dir != inputDir { return false }
            if let threshold, let inputThreshold, threshold > inputThreshold { return false }
            return true
        case (.screenDismissed(let method), .screenDismissed(let inputMethod)):
            if let method, let inputMethod {
                return method == inputMethod
            }
            return true
        case (.event(let name, _), .event(let inputName, _)):
            return name == inputName
        case (.viewModelChanged(let path, _), .viewModelChanged(let inputPath, _)):
            return matchesViewModelPath(triggerPath: path, inputPath: inputPath)
        default:
            return false
        }
    }

    private func matchesViewModelPath(triggerPath: VmPathRef, inputPath: VmPathRef) -> Bool {
        let triggerKey = normalizedPathKey(triggerPath)
        let inputKey = normalizedPathKey(inputPath)
        if triggerKey == inputKey { return true }

        if let triggerIds = pathIdsKey(for: triggerPath), let inputIds = pathIdsKey(for: inputPath) {
            return triggerIds == inputIds
        }

        if let triggerPath = pathString(for: triggerPath), let inputPath = pathString(for: inputPath) {
            return triggerPath == inputPath
        }

        return false
    }

    private func normalizedPathKey(_ ref: VmPathRef) -> String {
        return ref.normalizedPath
    }

    private func pathIdsKey(for ref: VmPathRef) -> String? {
        switch ref {
        case .ids(let ids):
            return "ids:\(ids.map(String.init).joined(separator: "."))"
        case .path(let path):
            if let entry = remoteFlow.pathIndex?[path] {
                return "ids:\(entry.pathIds.map(String.init).joined(separator: "."))"
            }
            return nil
        case .raw:
            return nil
        }
    }

    private func pathString(for ref: VmPathRef) -> String? {
        switch ref {
        case .path(let path):
            return path
        case .ids(let ids):
            let key = "ids:\(ids.map(String.init).joined(separator: "."))"
            return pathIndexByIds[key]
        case .raw:
            return nil
        }
    }

    private func resolveValueRefs(_ value: Any, context: TriggerContext) -> Any {
        if let list = value as? [Any] {
            return list.map { resolveValueRefs($0, context: context) }
        }
        if let list = value as? [AnyCodable] {
            return list.map { resolveValueRefs($0.value, context: context) }
        }
        if let dict = value as? [String: Any] {
            if dict.count == 1, let literal = dict["literal"] {
                return literal
            }
            if dict.count == 1, let ref = dict["ref"] as? String {
                return viewModels.getValue(path: VmPathRef.path(ref), screenId: context.screenId ?? journey.flowState.currentScreenId) as Any
            }
            var resolved: [String: Any] = [:]
            for (key, entry) in dict {
                resolved[key] = resolveValueRefs(entry, context: context)
            }
            return resolved
        }
        if let dict = value as? [String: AnyCodable] {
            if dict.count == 1, let literal = dict["literal"]?.value {
                return literal
            }
            if dict.count == 1, let ref = dict["ref"]?.value as? String {
                return viewModels.getValue(path: VmPathRef.path(ref), screenId: context.screenId ?? journey.flowState.currentScreenId) as Any
            }
            var resolved: [String: Any] = [:]
            for (key, entry) in dict {
                resolved[key] = resolveValueRefs(entry.value, context: context)
            }
            return resolved
        }
        return value
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> Any? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func parseIds(_ key: String) -> [Int]? {
        guard key.hasPrefix("ids:") else { return nil }
        let raw = key.dropFirst(4)
        let parts = raw.split(separator: ".")
        let ids = parts.compactMap { Int($0) }
        return ids.isEmpty ? nil : ids
    }

    private func evalConditionIR(_ envelope: IREnvelope?, event: NuxieEvent?) async -> Bool {
        guard let envelope else { return true }

        let userAdapter = IRUserPropsAdapter(identityService: identityService)
        let eventsAdapter = IREventQueriesAdapter(eventService: eventService)
        let segmentsAdapter = IRSegmentQueriesAdapter(segmentService: segmentService)
        let featuresAdapter = IRFeatureQueriesAdapter(featureService: featureService)

        let config = IRRuntime.Config(
            event: event,
            user: userAdapter,
            events: eventsAdapter,
            segments: segmentsAdapter,
            features: featuresAdapter
        )

        return await irRuntime.eval(envelope, config)
    }

    private func resolveExperimentVariant(_ action: ExperimentAction) async -> ExperimentVariant? {
        if let assignment = await getServerAssignment(experimentId: action.experimentId) {
            if let variant = action.variants.first(where: { $0.id == assignment.variantId }) {
                return variant
            }
        }

        return computeVariantLocally(action)
    }

    private func getServerAssignment(experimentId: String) async -> ExperimentAssignment? {
        guard let profile = await profileService.getCachedProfile(distinctId: journey.distinctId) else {
            return nil
        }
        return profile.experiments?[experimentId]
    }

    private func computeVariantLocally(_ action: ExperimentAction) -> ExperimentVariant? {
        let seed = "\(journey.distinctId):\(action.experimentId)"
        let bucket = stableHash(seed) % 100

        var cumulative: Double = 0
        for variant in action.variants {
            cumulative += variant.percentage
            if Double(bucket) < cumulative {
                return variant
            }
        }

        return action.variants.first
    }

    private func stableHash(_ input: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash & 0x7FFF_FFFF_FFFF_FFFF)
    }

    private func parseTime(_ timeString: String) -> DateComponents? {
        let parts = timeString.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1])
        else { return nil }

        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return components
    }

    private func calculateNextValidDay(from date: Date, validDays: [Int], timezone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone

        for i in 1...7 {
            guard let nextDate = cal.date(byAdding: .day, value: i, to: date) else { continue }
            let weekday = cal.component(.weekday, from: nextDate)
            if validDays.contains(weekday) {
                var comps = cal.dateComponents([.year, .month, .day], from: nextDate)
                comps.hour = 0
                comps.minute = 0
                comps.second = 0
                comps.timeZone = timezone
                return cal.date(from: comps) ?? nextDate
            }
        }

        return date
    }

    private func calculateNextWindowOpen(
        from date: Date,
        startTime: String,
        timezone: TimeZone,
        validDays: [Int]?
    ) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone

        guard let startHM = parseTime(startTime),
              let sh = startHM.hour, let sm = startHM.minute
        else { return date }

        var today = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        today.hour = sh
        today.minute = sm
        today.second = 0
        today.timeZone = timezone

        var nextOpen = cal.date(from: today) ?? date

        if nextOpen <= date {
            nextOpen = cal.date(byAdding: .day, value: 1, to: nextOpen) ?? nextOpen
        }

        if let days = validDays, !days.isEmpty {
            while true {
                let wd = cal.component(.weekday, from: nextOpen)
                if days.contains(wd) { break }
                nextOpen = cal.date(byAdding: .day, value: 1, to: nextOpen) ?? nextOpen
            }
        }

        return nextOpen
    }
}

private extension InteractionAction {
    var actionType: String {
        switch self {
        case .navigate: return "navigate"
        case .back: return "back"
        case .delay: return "delay"
        case .timeWindow: return "time_window"
        case .waitUntil: return "wait_until"
        case .condition: return "condition"
        case .experiment: return "experiment"
        case .sendEvent: return "send_event"
        case .updateCustomer: return "update_customer"
        case .callDelegate: return "call_delegate"
        case .remote: return "remote"
        case .setViewModel: return "set_view_model"
        case .fireTrigger: return "fire_trigger"
        case .listInsert: return "list_insert"
        case .listRemove: return "list_remove"
        case .listSwap: return "list_swap"
        case .listMove: return "list_move"
        case .listSet: return "list_set"
        case .listClear: return "list_clear"
        case .exit: return "exit"
        case .unknown(let type, _): return type
        }
    }
}
