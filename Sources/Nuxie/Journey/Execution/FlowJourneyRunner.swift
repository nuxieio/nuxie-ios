import Foundation
import FactoryKit

final class FlowJourneyRunner {
    struct TriggerContext {
        let screenId: String?
        let componentId: String?
        let interactionId: String?
        let instanceId: String?
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

    weak var viewController: FlowViewController?
    var onShowScreen: ((String, AnyCodable?) async -> Void)?
    private(set) var isRuntimeReady = false

    private var interactionsById: [String: [Interaction]] = [:]

    private var actionQueue: [ActionRequest] = []
    private var activeRequest: ActionRequest?
    private var activeIndex: Int = 0
    private var isProcessing = false
    private var isPaused = false
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var triggerResetTasks: [String: Task<Void, Never>] = [:]
    private var didWarnConverters = false

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

        self.interactionsById = flow.remoteFlow.interactions

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
                let fallback = remoteFlow.screens.first?.id
                if let fallback {
                    await navigate(to: fallback, transition: nil)
                }
            }
        }

        return nil
    }

    func handleScreenChanged(_ screenId: String) async -> RunOutcome? {
        journey.flowState.currentScreenId = screenId
        let event = makeSystemEvent(
            name: SystemEventNames.screenShown,
            properties: ["screen_id": screenId]
        )
        return await dispatchEventTrigger(event)
    }

    func handleDidSet(
        path: VmPathRef,
        value: Any,
        source: String?,
        screenId: String?,
        instanceId: String?
    ) async -> RunOutcome? {
        let resolvedScreenId = screenId ?? journey.flowState.currentScreenId
        _ = viewModels.setValue(
            path: path,
            value: value,
            screenId: resolvedScreenId,
            instanceId: instanceId
        )
        journey.flowState.viewModelSnapshot = viewModels.getSnapshot()

        let outcome = await dispatchDidSetTrigger(
            path: path,
            value: value,
            screenId: resolvedScreenId,
            instanceId: instanceId
        )
        scheduleTriggerReset(path: path, screenId: resolvedScreenId, instanceId: instanceId)
        return outcome
    }

    func resolveRuntimeValue(
        _ value: Any,
        screenId: String?,
        instanceId: String?
    ) -> Any {
        return resolveValueRefs(
            value,
            context: TriggerContext(
                screenId: screenId,
                componentId: nil,
                interactionId: nil,
                instanceId: instanceId
            )
        )
    }

    func handleRuntimeBack(steps: Int?, transition: AnyCodable?) async {
        await handleBack(BackAction(steps: steps, transition: transition))
    }

    func handleRuntimeOpenLink(
        url: Any,
        target: String?,
        screenId: String?,
        instanceId: String?
    ) async {
        guard let controller = viewController else { return }
        let resolved = resolveValueRefs(
            url,
            context: TriggerContext(
                screenId: screenId,
                componentId: nil,
                interactionId: nil,
                instanceId: instanceId
            )
        )
        guard let urlString = resolved as? String, !urlString.isEmpty else { return }
        await MainActor.run {
            controller.performOpenLink(urlString: urlString, target: target)
        }
        var userInfo: [String: Any] = [
            "journeyId": journey.id,
            "campaignId": journey.campaignId,
            "url": urlString
        ]
        if let target {
            userInfo["target"] = target
        }
        if let resolvedScreenId = screenId ?? journey.flowState.currentScreenId {
            userInfo["screenId"] = resolvedScreenId
        }
        NotificationCenter.default.post(
            name: .nuxieOpenLink,
            object: nil,
            userInfo: userInfo
        )
    }

    func dispatchEventTrigger(_ event: NuxieEvent) async -> RunOutcome? {
        return await dispatchTrigger(
            trigger: .event(eventName: event.name, filter: nil),
            screenId: journey.flowState.currentScreenId,
            componentId: nil,
            instanceId: nil,
            event: event
        )
    }

    func dispatchTrigger(
        trigger: InteractionTrigger,
        screenId: String?,
        componentId: String?,
        instanceId: String?,
        event: NuxieEvent?
    ) async -> RunOutcome? {
        if isPaused { return nil }

        var interactions: [Interaction] = []
        if let componentId {
            interactions.append(contentsOf: interactionsById[componentId] ?? [])
        }
        if let screenId {
            interactions.append(contentsOf: interactionsById[screenId] ?? [])
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

            if case .didSet = interaction.trigger {
                continue
            }

            enqueueActions(
                interaction.actions,
                context: TriggerContext(
                    screenId: screenId,
                    componentId: componentId,
                    interactionId: interaction.id,
                    instanceId: instanceId
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
            interactionId: pending.interactionId,
            instanceId: nil
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

    func clearDebounces() {
        for (_, task) in debounceTasks {
            task.cancel()
        }
        debounceTasks.removeAll()
    }

    func hasPendingWork() -> Bool {
        if journey.flowState.pendingAction != nil { return true }
        if activeRequest != nil { return true }
        if !actionQueue.isEmpty { return true }
        return false
    }

    private func makeSystemEvent(name: String, properties: [String: Any]) -> NuxieEvent {
        return NuxieEvent(
            name: name,
            distinctId: journey.distinctId,
            properties: properties
        )
    }

    private func entryScreenId(from interactions: [Interaction]) -> String? {
        for interaction in interactions {
            for action in interaction.actions {
                if case .navigate(let navigateAction) = action, !navigateAction.screenId.isEmpty {
                    return navigateAction.screenId
                }
            }
        }
        return nil
    }

    private func runEntryActionsIfNeeded() async -> RunOutcome? {
        guard let entryInteractions = interactionsById["start"], !entryInteractions.isEmpty else { return nil }

        let entryScreenId = entryScreenId(from: entryInteractions)
        var properties: [String: Any] = [:]
        if let entryScreenId {
            properties["entry_screen_id"] = entryScreenId
        }
        let event = makeSystemEvent(
            name: SystemEventNames.flowEntered,
            properties: properties
        )

        for interaction in entryInteractions {
            if interaction.enabled == false { continue }
            guard case .event(let eventName, let filter) = interaction.trigger else { continue }
            guard eventName == SystemEventNames.flowEntered else { continue }
            if let filter {
                let ok = await evalConditionIR(filter, event: event)
                if !ok { continue }
            }
            enqueueActions(
                interaction.actions,
                context: TriggerContext(
                    screenId: journey.flowState.currentScreenId,
                    componentId: nil,
                    interactionId: interaction.id,
                    instanceId: nil
                )
            )
        }

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
            case .purchase(let purchase):
                let result = await handlePurchase(purchase, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .restore(let restore):
                let result = await handleRestore(restore, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .openLink(let openLink):
                let result = await handleOpenLink(openLink, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .dismiss(let dismiss):
                let result = await handleDismiss(dismiss, context: context)
                trackAction(action, context: context, error: nil)
                return result
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
            let event = makeSystemEvent(
                name: SystemEventNames.screenDismissed,
                properties: ["screen_id": current, "method": "navigate"]
            )
            _ = await dispatchEventTrigger(event)
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
        await sendShowScreen(target, transition: action.transition)

        NotificationCenter.default.post(
            name: .nuxieBack,
            object: nil,
            userInfo: [
                "journeyId": journey.id,
                "campaignId": journey.campaignId,
                "steps": steps,
                "screenId": target
            ]
        )
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

        let experimentKey = action.experimentId
        let assignment = await getServerAssignment(experimentId: experimentKey)

        let frozenVariantKey = getFrozenExperimentVariantKey(experimentKey: experimentKey)
        let frozenVariant =
            frozenVariantKey.flatMap { key in
                action.variants.first(where: { $0.id == key })
            }

        let resolution = frozenVariant != nil
            ? (variant: frozenVariant, matchedAssignment: assignment?.variantKey == frozenVariantKey)
            : resolveExperimentVariant(action, assignment: assignment)

        guard let variant = resolution.variant else {
            return .continue
        }

        let status = assignment?.status
        if status == "running",
           resolution.matchedAssignment,
           (frozenVariantKey == nil || frozenVariant == nil)
        {
            freezeExperimentVariantKey(experimentKey: experimentKey, variantKey: variant.id)
        }

        journey.setContext("_experiment_key", value: experimentKey)
        journey.setContext("_variant_key", value: variant.id)

        if status == "running",
           !hasEmittedExperimentExposure(experimentKey: experimentKey) {
            let assignmentSource = frozenVariant != nil ? "journey_context" : "profile"
            if resolution.matchedAssignment {
                eventService.track(
                    JourneyEvents.experimentExposure,
                    properties: JourneyEvents.experimentExposureProperties(
                        journey: journey,
                        experimentKey: experimentKey,
                        variantKey: variant.id,
                        flowId: journey.flowId,
                        isHoldout: assignment?.isHoldout ?? false,
                        assignmentSource: assignmentSource
                    ),
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                markExperimentExposureEmitted(experimentKey: experimentKey)
            } else {
                eventService.track(
                    "$experiment_exposure_error",
                    properties: [
                        "experiment_key": experimentKey,
                        "variant_key": assignment?.variantKey as Any,
                        "reason": "variant_not_found"
                    ],
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
            }
        }

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
            userPropertiesSetOnce: nil
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
            userPropertiesSetOnce: nil
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
            userPropertiesSetOnce: nil
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
            userPropertiesSetOnce: nil
        )
    }

    private func handlePurchase(
        _ action: PurchaseAction,
        context: TriggerContext
    ) async -> ActionResult {
        guard let controller = viewController else { return .continue }
        let resolvedProductId = resolveValueRefs(action.productId.value, context: context)
        guard let productId = resolvedProductId as? String, !productId.isEmpty else {
            return .continue
        }
        let placementIndex = resolveValueRefs(action.placementIndex.value, context: context)
        await MainActor.run {
            controller.performPurchase(productId: productId, placementIndex: placementIndex)
        }

        var userInfo: [String: Any] = [
            "journeyId": journey.id,
            "campaignId": journey.campaignId,
            "productId": productId
        ]
        if let screenId = context.screenId ?? journey.flowState.currentScreenId {
            userInfo["screenId"] = screenId
        }
        userInfo["placementIndex"] = placementIndex
        NotificationCenter.default.post(
            name: .nuxiePurchase,
            object: nil,
            userInfo: userInfo
        )
        return .continue
    }

    private func handleRestore(
        _ action: RestoreAction,
        context: TriggerContext
    ) async -> ActionResult {
        guard let controller = viewController else { return .continue }
        await MainActor.run {
            controller.performRestore()
        }
        var userInfo: [String: Any] = [
            "journeyId": journey.id,
            "campaignId": journey.campaignId
        ]
        if let screenId = context.screenId ?? journey.flowState.currentScreenId {
            userInfo["screenId"] = screenId
        }
        NotificationCenter.default.post(
            name: .nuxieRestore,
            object: nil,
            userInfo: userInfo
        )
        return .continue
    }

    private func handleOpenLink(
        _ action: OpenLinkAction,
        context: TriggerContext
    ) async -> ActionResult {
        guard let controller = viewController else { return .continue }
        let resolvedUrl = resolveValueRefs(action.url.value, context: context)
        guard let urlString = resolvedUrl as? String, !urlString.isEmpty else {
            return .continue
        }
        await MainActor.run {
            controller.performOpenLink(urlString: urlString, target: action.target)
        }
        var userInfo: [String: Any] = [
            "journeyId": journey.id,
            "campaignId": journey.campaignId,
            "url": urlString
        ]
        if let target = action.target {
            userInfo["target"] = target
        }
        if let screenId = context.screenId ?? journey.flowState.currentScreenId {
            userInfo["screenId"] = screenId
        }
        NotificationCenter.default.post(
            name: .nuxieOpenLink,
            object: nil,
            userInfo: userInfo
        )
        return .continue
    }

    private func handleDismiss(
        _ action: DismissAction,
        context: TriggerContext
    ) async -> ActionResult {
        guard let controller = viewController else { return .continue }
        await MainActor.run {
            controller.performDismiss(reason: .userDismissed)
        }
        return .continue
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
                userPropertiesSetOnce: nil
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
        _ = viewModels.setValue(
            path: action.path,
            value: resolvedValue,
            screenId: screenId,
            instanceId: context.instanceId
        )
        journey.flowState.viewModelSnapshot = viewModels.getSnapshot()

        sendViewModelPatch(path: action.path, value: resolvedValue, source: "host", instanceId: context.instanceId)

        _ = await dispatchDidSetTrigger(
            path: action.path,
            value: resolvedValue,
            screenId: screenId,
            instanceId: context.instanceId
        )
        scheduleTriggerReset(path: action.path, screenId: screenId, instanceId: context.instanceId)

        return .continue
    }

    private func handleFireTrigger(
        _ action: FireTriggerAction,
        context: TriggerContext
    ) async -> ActionResult {
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let timestamp = Int(dateProvider.now().timeIntervalSince1970 * 1000)
        _ = viewModels.setValue(
            path: action.path,
            value: timestamp,
            screenId: screenId,
            instanceId: context.instanceId
        )
        journey.flowState.viewModelSnapshot = viewModels.getSnapshot()

        sendViewModelTrigger(path: action.path, value: timestamp, instanceId: context.instanceId)

        _ = await dispatchDidSetTrigger(
            path: action.path,
            value: timestamp,
            screenId: screenId,
            instanceId: context.instanceId
        )
        scheduleTriggerReset(path: action.path, screenId: screenId, instanceId: context.instanceId)

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
            screenId: screenId,
            instanceId: context.instanceId
        )

        if ok {
            journey.flowState.viewModelSnapshot = viewModels.getSnapshot()
            sendViewModelListOperation(op: "insert", path: action.path, payload: payload, instanceId: context.instanceId)
            let updatedValue = viewModels.getValue(path: action.path, screenId: screenId, instanceId: context.instanceId) ?? NSNull()
            _ = await dispatchDidSetTrigger(
                path: action.path,
                value: updatedValue,
                screenId: screenId,
                instanceId: context.instanceId
            )
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
            screenId: screenId,
            instanceId: context.instanceId
        )

        if ok {
            journey.flowState.viewModelSnapshot = viewModels.getSnapshot()
            sendViewModelListOperation(op: "remove", path: action.path, payload: payload, instanceId: context.instanceId)
            let updatedValue = viewModels.getValue(path: action.path, screenId: screenId, instanceId: context.instanceId) ?? NSNull()
            _ = await dispatchDidSetTrigger(
                path: action.path,
                value: updatedValue,
                screenId: screenId,
                instanceId: context.instanceId
            )
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
            screenId: screenId,
            instanceId: context.instanceId
        )

        if ok {
            journey.flowState.viewModelSnapshot = viewModels.getSnapshot()
            sendViewModelListOperation(op: "swap", path: action.path, payload: payload, instanceId: context.instanceId)
            let updatedValue = viewModels.getValue(path: action.path, screenId: screenId, instanceId: context.instanceId) ?? NSNull()
            _ = await dispatchDidSetTrigger(
                path: action.path,
                value: updatedValue,
                screenId: screenId,
                instanceId: context.instanceId
            )
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
            screenId: screenId,
            instanceId: context.instanceId
        )

        if ok {
            journey.flowState.viewModelSnapshot = viewModels.getSnapshot()
            sendViewModelListOperation(op: "move", path: action.path, payload: payload, instanceId: context.instanceId)
            let updatedValue = viewModels.getValue(path: action.path, screenId: screenId, instanceId: context.instanceId) ?? NSNull()
            _ = await dispatchDidSetTrigger(
                path: action.path,
                value: updatedValue,
                screenId: screenId,
                instanceId: context.instanceId
            )
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
            screenId: screenId,
            instanceId: context.instanceId
        )

        if ok {
            journey.flowState.viewModelSnapshot = viewModels.getSnapshot()
            sendViewModelListOperation(op: "set", path: action.path, payload: payload, instanceId: context.instanceId)
            let updatedValue = viewModels.getValue(path: action.path, screenId: screenId, instanceId: context.instanceId) ?? NSNull()
            _ = await dispatchDidSetTrigger(
                path: action.path,
                value: updatedValue,
                screenId: screenId,
                instanceId: context.instanceId
            )
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
            screenId: screenId,
            instanceId: context.instanceId
        )

        if ok {
            journey.flowState.viewModelSnapshot = viewModels.getSnapshot()
            sendViewModelListOperation(op: "clear", path: action.path, payload: payload, instanceId: context.instanceId)
            let updatedValue = viewModels.getValue(path: action.path, screenId: screenId, instanceId: context.instanceId) ?? NSNull()
            _ = await dispatchDidSetTrigger(
                path: action.path,
                value: updatedValue,
                screenId: screenId,
                instanceId: context.instanceId
            )
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

    private func dispatchDidSetTrigger(
        path: VmPathRef,
        value: Any,
        screenId: String?,
        instanceId: String?
    ) async -> RunOutcome? {
        let interactions = (screenId != nil) ? (interactionsById[screenId!] ?? []) : []
        if interactions.isEmpty { return nil }

        for interaction in interactions {
            if interaction.enabled == false { continue }
            guard case .didSet(let triggerPath, let debounceMs) = interaction.trigger else { continue }
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
                            interactionId: interaction.id,
                            instanceId: instanceId
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
                        interactionId: interaction.id,
                        instanceId: instanceId
                    )
                )
            }
        }

        return await processQueue(resumeContext: nil)
    }

    private func scheduleTriggerReset(path: VmPathRef, screenId: String?, instanceId: String?) {
        guard viewModels.isTriggerPath(path: path, screenId: screenId) else { return }
        let key = path.normalizedPath
        triggerResetTasks[key]?.cancel()
        triggerResetTasks[key] = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            _ = self.viewModels.setValue(path: path, value: 0, screenId: screenId, instanceId: instanceId)
            self.journey.flowState.viewModelSnapshot = self.viewModels.getSnapshot()
            self.sendViewModelTrigger(path: path, value: 0, instanceId: instanceId)
        }
    }

    private func resolveActions(
        interactionId: String,
        screenId: String?,
        componentId: String?
    ) -> [InteractionAction]? {
        if let screenId,
           let list = interactionsById[screenId],
           let match = list.first(where: { $0.id == interactionId }) {
            return match.actions
        }

        if let componentId,
           let list = interactionsById[componentId],
           let match = list.first(where: { $0.id == interactionId }) {
            return match.actions
        }

        for (_, list) in interactionsById {
            if let match = list.first(where: { $0.id == interactionId }) {
                return match.actions
            }
        }

        return nil
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
            userPropertiesSetOnce: nil
        )
    }

    private func sendViewModelInit() {
        guard let controller = viewController else { return }
        warnConvertersIfNeeded()
        let payload: [String: Any] = [
            "viewModels": encodeJSON(remoteFlow.viewModels) ?? [],
            "instances": encodeJSON(viewModels.allInstances()) ?? [],
            "converters": remoteFlow.converters?.mapValues { value in
                value.mapValues { $0.value }
            } ?? [:],
            "screenDefaults": viewModels.screenDefaultsPayload(),
        ]

        Task { @MainActor in
            controller.sendRuntimeMessage(type: "runtime/view_model_init", payload: payload)
        }
    }

    private func warnConvertersIfNeeded() {
        if didWarnConverters { return }
        guard let converters = remoteFlow.converters, !converters.isEmpty else { return }
        didWarnConverters = true
        let hasViewModelTriggers = remoteFlow.interactions.values.contains { interactions in
            interactions.contains { interaction in
                if case .didSet = interaction.trigger {
                    return true
                }
                return false
            }
        }
        let triggerNote = hasViewModelTriggers ? " View-model triggers evaluate raw values on native." : ""
        LogWarning("Flow \(remoteFlow.id) includes converters. Native runtime does not execute converters; ensure converter-dependent logic runs in the web bundle.\(triggerNote)")
    }

    private func sendViewModelPatch(path: VmPathRef, value: Any, source: String?, instanceId: String? = nil) {
        guard let controller = viewController else { return }
        var payload: [String: Any] = [
            "value": value,
        ]
        appendPathPayload(&payload, path: path)
        if let source {
            payload["source"] = source
        }
        if let instanceId {
            payload["instanceId"] = instanceId
        }

        Task { @MainActor in
            controller.sendRuntimeMessage(type: "runtime/view_model_patch", payload: payload)
        }
    }

    private func sendViewModelListOperation(op: String, path: VmPathRef, payload: [String: Any], instanceId: String? = nil) {
        guard let controller = viewController else { return }
        var message = payload
        appendPathPayload(&message, path: path)
        if let instanceId {
            message["instanceId"] = instanceId
        }

        Task { @MainActor in
            controller.sendRuntimeMessage(type: "runtime/view_model_list_\(op)", payload: message)
        }
    }

    private func sendViewModelTrigger(path: VmPathRef, value: Any?, instanceId: String? = nil) {
        guard let controller = viewController else { return }
        var payload: [String: Any] = [:]
        appendPathPayload(&payload, path: path)
        if let value {
            payload["value"] = value
        }
        if let instanceId {
            payload["instanceId"] = instanceId
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
            controller.sendRuntimeMessage(type: "runtime/navigate", payload: payload)
        }
    }

    private func appendPathPayload(_ payload: inout [String: Any], path: VmPathRef) {
        if case .ids(let ref) = path {
            payload["pathIds"] = ref.pathIds
            if ref.isRelative == true {
                payload["isRelative"] = true
            }
            if ref.nameBased == true {
                payload["nameBased"] = true
            }
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
             (.manual, .manual):
            return true
        case (.longPress, .longPress):
            return true
        case (.drag(let dir, let threshold), .drag(let inputDir, let inputThreshold)):
            if let dir, let inputDir, dir != inputDir { return false }
            if let threshold, let inputThreshold, threshold > inputThreshold { return false }
            return true
        case (.event(let name, _), .event(let inputName, _)):
            return name == inputName
        case (.didSet(let path, _), .didSet(let inputPath, _)):
            return matchesViewModelPath(triggerPath: path, inputPath: inputPath)
        default:
            return false
        }
    }

    private func matchesViewModelPath(triggerPath: VmPathRef, inputPath: VmPathRef) -> Bool {
        if let triggerIds = pathIdsKey(for: triggerPath), let inputIds = pathIdsKey(for: inputPath) {
            return triggerIds == inputIds
        }
        return false
    }

    private func pathIdsKey(for ref: VmPathRef) -> String? {
        switch ref {
        case .ids(let ref):
            let prefix: String
            if ref.isRelative == true {
                prefix = "ids:rel"
            } else if ref.nameBased == true {
                prefix = "ids:name"
            } else {
                prefix = "ids"
            }
            return "\(prefix):\(ref.pathIds.map(String.init).joined(separator: "."))"
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
            if dict.count == 1, let refValue = dict["ref"], let ref = parseRefPath(refValue) {
                return viewModels.getValue(
                    path: ref,
                    screenId: context.screenId ?? journey.flowState.currentScreenId,
                    instanceId: context.instanceId
                ) as Any
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
            if dict.count == 1, let refValue = dict["ref"]?.value, let ref = parseRefPath(refValue) {
                return viewModels.getValue(
                    path: ref,
                    screenId: context.screenId ?? journey.flowState.currentScreenId,
                    instanceId: context.instanceId
                ) as Any
            }
            var resolved: [String: Any] = [:]
            for (key, entry) in dict {
                resolved[key] = resolveValueRefs(entry.value, context: context)
            }
            return resolved
        }
        return value
    }

    private func parseRefPath(_ value: Any) -> VmPathRef? {
        if let ref = value as? VmPathRef { return ref }
        if let dict = value as? [String: Any] {
            let isRelative = dict["isRelative"] as? Bool
            let nameBased = dict["nameBased"] as? Bool
            if let ids = dict["pathIds"] as? [Int] {
                return .ids(VmPathIds(pathIds: ids, isRelative: isRelative, nameBased: nameBased))
            }
            if let ids = dict["pathIds"] as? [NSNumber] {
                return .ids(VmPathIds(pathIds: ids.map { $0.intValue }, isRelative: isRelative, nameBased: nameBased))
            }
        }
        if let dict = value as? [String: AnyCodable] {
            let isRelative = dict["isRelative"]?.value as? Bool
            let nameBased = dict["nameBased"]?.value as? Bool
            if let ids = dict["pathIds"]?.value as? [Int] {
                return .ids(VmPathIds(pathIds: ids, isRelative: isRelative, nameBased: nameBased))
            }
            if let ids = dict["pathIds"]?.value as? [NSNumber] {
                return .ids(VmPathIds(pathIds: ids.map { $0.intValue }, isRelative: isRelative, nameBased: nameBased))
            }
        }
        return nil
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> Any? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
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

    private func resolveExperimentVariant(
        _ action: ExperimentAction,
        assignment: ExperimentAssignment?
    ) -> (variant: ExperimentVariant?, matchedAssignment: Bool) {
        guard let assignment else {
            return (action.variants.first, false)
        }

        switch assignment.status {
        case "running", "concluded":
            if let variantKey = assignment.variantKey,
               let variant = action.variants.first(where: { $0.id == variantKey }) {
                return (variant, true)
            }
            return (action.variants.first, false)
        default:
            return (action.variants.first, false)
        }
    }

    private func getServerAssignment(experimentId: String) async -> ExperimentAssignment? {
        guard let profile = await profileService.getCachedProfile(distinctId: journey.distinctId) else {
            return nil
        }
        return profile.experiments?[experimentId]
    }

    // -------------------------------------------------------------------------
    // Experiment Exposure Dedupe + Freeze
    // -------------------------------------------------------------------------

    private enum ExperimentContextKeys {
        static let frozenVariantsByExperiment = "_experiment_variants"
        static let exposureEmittedByExperiment = "_experiment_exposure_emitted"
    }

    private func getFrozenExperimentVariantKey(experimentKey: String) -> String? {
        guard let dict = journey.getContext(ExperimentContextKeys.frozenVariantsByExperiment) as? [String: Any] else {
            return nil
        }
        return dict[experimentKey] as? String
    }

    private func freezeExperimentVariantKey(experimentKey: String, variantKey: String) {
        guard !experimentKey.isEmpty, !variantKey.isEmpty else { return }
        var dict =
            (journey.getContext(ExperimentContextKeys.frozenVariantsByExperiment) as? [String: Any]) ?? [:]
        dict[experimentKey] = variantKey
        journey.setContext(ExperimentContextKeys.frozenVariantsByExperiment, value: dict)
    }

    private func hasEmittedExperimentExposure(experimentKey: String) -> Bool {
        guard let dict = journey.getContext(ExperimentContextKeys.exposureEmittedByExperiment) as? [String: Any] else {
            return false
        }
        if let emitted = dict[experimentKey] as? Bool {
            return emitted
        }
        if let emitted = dict[experimentKey] as? Int {
            return emitted != 0
        }
        if let emitted = dict[experimentKey] as? String {
            return emitted == "true" || emitted == "1"
        }
        return false
    }

    private func markExperimentExposureEmitted(experimentKey: String) {
        guard !experimentKey.isEmpty else { return }
        var dict =
            (journey.getContext(ExperimentContextKeys.exposureEmittedByExperiment) as? [String: Any]) ?? [:]
        dict[experimentKey] = true
        journey.setContext(ExperimentContextKeys.exposureEmittedByExperiment, value: dict)
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
        case .purchase: return "purchase"
        case .restore: return "restore"
        case .openLink: return "open_link"
        case .dismiss: return "dismiss"
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
