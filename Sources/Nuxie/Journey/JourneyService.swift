import FactoryKit
import Foundation
import UIKit

/// Reason for resuming a journey
public enum ResumeReason {
  case start
  case timer
  case event(NuxieEvent)
  case segmentChange

  var isReactive: Bool {
    switch self {
    case .event, .segmentChange:
      return true
    case .start, .timer:
      return false
    }
  }
}

/// Protocol for journey management
public protocol JourneyServiceProtocol: AnyObject {
  @discardableResult
  func startJourney(for campaign: Campaign, distinctId: String, originEventId: String?) async -> Journey?

  func resumeJourney(_ journey: Journey) async

  func resumeFromServerState(_ journeys: [ActiveJourney], campaigns: [Campaign]) async

  func handleEvent(_ event: NuxieEvent) async

  func handleEventForTrigger(_ event: NuxieEvent) async -> [JourneyTriggerResult]

  func handleSegmentChange(distinctId: String, segments: Set<String>) async

  func getActiveJourneys(for distinctId: String) async -> [Journey]

  func checkExpiredTimers() async

  func initialize() async

  func onAppWillEnterForeground() async

  func onAppBecameActive() async

  func onAppDidEnterBackground() async

  func shutdown() async

  func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async
}

public actor JourneyService: JourneyServiceProtocol {

  // MARK: - Dependencies

  private let journeyStore: JourneyStoreProtocol

  @Injected(\.flowService) private var flowService: FlowServiceProtocol
  @Injected(\.flowPresentationService) private var flowPresentationService: FlowPresentationServiceProtocol
  @Injected(\.profileService) private var profileService: ProfileServiceProtocol
  @Injected(\.identityService) private var identityService: IdentityServiceProtocol
  @Injected(\.segmentService) private var segmentService: SegmentServiceProtocol
  @Injected(\.featureService) private var featureService: FeatureServiceProtocol
  @Injected(\.eventService) private var eventService: EventServiceProtocol
  @Injected(\.triggerBroker) private var triggerBroker: TriggerBrokerProtocol
  @Injected(\.dateProvider) private var dateProvider: DateProviderProtocol
  @Injected(\.sleepProvider) private var sleepProvider: SleepProviderProtocol
  @Injected(\.goalEvaluator) private var goalEvaluator: GoalEvaluatorProtocol
  @Injected(\.irRuntime) private var irRuntime: IRRuntime

  // MARK: - State

  private var inMemoryJourneysById: [String: Journey] = [:]
  private var flowRunners: [String: FlowJourneyRunner] = [:]
  private var runtimeDelegates: [String: FlowRuntimeDelegateAdapter] = [:]
  private var activeTasks: [String: Task<Void, Never>] = [:]
  private var segmentMonitoringTask: Task<Void, Never>?

  // MARK: - Initialization

  internal init(
    journeyStore: JourneyStoreProtocol? = nil,
    customStoragePath: URL? = nil
  ) {
    self.journeyStore = journeyStore ?? JourneyStore(customStoragePath: customStoragePath)
    LogInfo("JourneyService initialized")
  }

  deinit {
    segmentMonitoringTask?.cancel()
  }

  // MARK: - Lifecycle

  public func initialize() async {
    LogInfo("Initializing JourneyService...")

    let persisted = journeyStore.loadActiveJourneys()
    LogInfo("Restored \(persisted.count) active journeys")

    for journey in persisted where journey.status.isLive {
      inMemoryJourneysById[journey.id] = journey

      if let pending = journey.flowState.pendingAction, let resumeAt = pending.resumeAt {
        scheduleResume(journeyId: journey.id, at: resumeAt)
      }

      scheduleAfterDelay(for: journey)
    }

    await checkExpiredTimers()
    registerForSegmentChanges()
  }

  public func onAppWillEnterForeground() async {
    await checkExpiredTimers()

    let now = dateProvider.now()
    for journey in inMemoryJourneysById.values where journey.status.isLive {
      if let pending = journey.flowState.pendingAction,
         let resumeAt = pending.resumeAt,
         resumeAt > now {
        scheduleResume(journeyId: journey.id, at: resumeAt)
      }
      scheduleAfterDelay(for: journey)
    }
  }

  public func onAppBecameActive() async {
    await flowPresentationService.onAppBecameActive()
  }

  public func onAppDidEnterBackground() async {
    cancelAllTasks()
    await flowPresentationService.onAppDidEnterBackground()

    for journey in inMemoryJourneysById.values where journey.status.isLive {
      persistJourney(journey)
    }

    LogInfo("JourneyService background snapshot complete")
  }

  public func shutdown() async {
    segmentMonitoringTask?.cancel()
    segmentMonitoringTask = nil
    cancelAllTasks()
  }

  public func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
    LogInfo("JourneyService handling user change from \(NuxieLogger.shared.logDistinctID(oldDistinctId)) to \(NuxieLogger.shared.logDistinctID(newDistinctId))")

    let oldJourneys = await getActiveJourneys(for: oldDistinctId)
    for journey in oldJourneys {
      cancelJourney(journey)
    }

    inMemoryJourneysById = inMemoryJourneysById.filter { $0.value.distinctId != oldDistinctId }

    let persisted = journeyStore.loadActiveJourneys()
      .filter { $0.distinctId == newDistinctId && $0.status.isLive }

    for journey in persisted {
      inMemoryJourneysById[journey.id] = journey
      if let pending = journey.flowState.pendingAction, let resumeAt = pending.resumeAt {
        scheduleResume(journeyId: journey.id, at: resumeAt)
      }
      scheduleAfterDelay(for: journey)
    }

    await checkExpiredTimers()
  }

  // MARK: - Public API

  public func startJourney(
    for campaign: Campaign,
    distinctId: String,
    originEventId: String? = nil
  ) async -> Journey? {
    guard suppressionReason(campaign: campaign, distinctId: distinctId) == nil else {
      LogDebug("User \(distinctId) cannot start journey for campaign \(campaign.id)")
      return nil
    }

    return await startJourneyInternal(
      for: campaign,
      distinctId: distinctId,
      originEventId: originEventId
    )
  }

  private func startJourneyInternal(
    for campaign: Campaign,
    distinctId: String,
    originEventId: String? = nil
  ) async -> Journey? {
    guard let flowId = campaign.flowId else {
      LogError("Campaign \(campaign.id) missing flowId, cannot start journey")
      return nil
    }

    let journey = Journey(campaign: campaign, distinctId: distinctId)
    journey.status = .active
    if let originEventId {
      journey.setContext("_origin_event_id", value: originEventId)
    }

    inMemoryJourneysById[journey.id] = journey

    let flow = try? await flowService.fetchFlow(id: flowId)
    let entryScreenId = flow?.remoteFlow.screens.first?.id

    eventService.track(
      "$journey_start",
      properties: [
        "session_id": journey.id,
        "campaign_id": campaign.id,
        "campaign_version_id": campaign.versionId,
        "entry_node_id": entryScreenId as Any,
      ],
      userProperties: nil,
      userPropertiesSetOnce: nil
    )

    eventService.track(
      JourneyEvents.journeyStarted,
      properties: JourneyEvents.journeyStartedProperties(
        journey: journey,
        campaign: campaign,
        triggerEvent: nil,
        entryScreenId: entryScreenId
      ),
      userProperties: nil,
      userPropertiesSetOnce: nil
    )

    guard await ensureRunner(for: journey, campaign: campaign) != nil else {
      completeJourney(journey, reason: .error)
      return journey
    }

    return journey
  }

  public func resumeJourney(_ journey: Journey) async {
    guard journey.status == .paused || journey.status == .active else { return }

    guard let campaign = await getCampaign(id: journey.campaignId, for: journey.distinctId) else {
      cancelJourney(journey)
      return
    }

    guard let runner = await ensureRunner(for: journey, campaign: campaign) else {
      completeJourney(journey, reason: .error)
      return
    }

    journey.resume()
    inMemoryJourneysById[journey.id] = journey

    let outcome = await runner.resumePendingAction(reason: .timer, event: nil)
    handleOutcome(outcome, journey: journey)

    eventService.track(
      JourneyEvents.journeyResumed,
      properties: JourneyEvents.journeyResumedProperties(
        journey: journey,
        screenId: journey.flowState.currentScreenId,
        resumeReason: "timer"
      ),
      userProperties: nil,
      userPropertiesSetOnce: nil
    )
  }

  public func resumeFromServerState(_ journeys: [ActiveJourney], campaigns: [Campaign]) async {
    for active in journeys {
      if let existing = inMemoryJourneysById[active.sessionId] {
        existing.setContext("_server_resume", value: true)
        continue
      }

      guard let campaign = campaigns.first(where: { $0.id == active.campaignId }) else {
        LogWarning("Campaign \(active.campaignId) not found for server journey \(active.sessionId)")
        continue
      }

      let journey = Journey(id: active.sessionId, campaign: campaign, distinctId: identityService.getDistinctId())
      journey.status = .paused
      journey.flowState.currentScreenId = active.currentNodeId
      journey.context = active.context

      inMemoryJourneysById[journey.id] = journey

      if let pending = journey.flowState.pendingAction, let resumeAt = pending.resumeAt {
        scheduleResume(journeyId: journey.id, at: resumeAt)
      }
    }
  }

  public func handleEvent(_ event: NuxieEvent) async {
    _ = await handleEventForTrigger(event)
  }

  public func handleEventForTrigger(_ event: NuxieEvent) async -> [JourneyTriggerResult] {
    guard let campaigns = await getAllCampaigns(for: event.distinctId) else { return [] }

    var results: [JourneyTriggerResult] = []

    for campaign in campaigns {
      guard await shouldTriggerFromEvent(campaign: campaign, event: event) else { continue }

      if let reason = suppressionReason(campaign: campaign, distinctId: event.distinctId) {
        results.append(.suppressed(reason))
        continue
      }

      if let journey = await startJourneyInternal(
        for: campaign,
        distinctId: event.distinctId,
        originEventId: event.id
      ) {
        results.append(.started(journey))
      } else {
        results.append(.suppressed(.unknown("start_failed")))
      }
    }

    let journeys = await getActiveJourneys(for: event.distinctId)
    for journey in journeys {
      guard let campaign = campaigns.first(where: { $0.id == journey.campaignId }) else { continue }

      await evaluateGoalIfNeeded(journey, campaign: campaign)
      if let reason = await exitDecision(journey, campaign) {
        completeJourney(journey, reason: reason)
        continue
      }

      if let pending = journey.flowState.pendingAction, pending.kind == .waitUntil {
        if let runner = flowRunners[journey.id] {
          let outcome = await runner.resumePendingAction(reason: .event(event), event: event)
          handleOutcome(outcome, journey: journey)
        }
        continue
      }

      if let runner = flowRunners[journey.id] {
        let outcome = await runner.dispatchEventTrigger(event)
        handleOutcome(outcome, journey: journey)
      }
    }

    return results
  }

  public func handleSegmentChange(distinctId: String, segments: Set<String>) async {
    guard let campaigns = await getAllCampaigns(for: distinctId) else { return }

    for campaign in campaigns {
      guard case .segment(let config) = campaign.trigger else { continue }
      let matches = await evalConditionIR(config.condition)
      if matches {
        _ = await startJourney(for: campaign, distinctId: distinctId, originEventId: nil)
      }
    }

    let journeys = await getActiveJourneys(for: distinctId)
    for journey in journeys {
      guard let campaign = campaigns.first(where: { $0.id == journey.campaignId }) else { continue }
      await evaluateGoalIfNeeded(journey, campaign: campaign)
      if let reason = await exitDecision(journey, campaign) {
        completeJourney(journey, reason: reason)
      }
    }
  }

  public func getActiveJourneys(for distinctId: String) async -> [Journey] {
    return inMemoryJourneysById.values.filter { $0.distinctId == distinctId && $0.status.isLive }
  }

  public func checkExpiredTimers() async {
    let now = dateProvider.now()

    for journey in inMemoryJourneysById.values where journey.status.isLive {
      if let pending = journey.flowState.pendingAction, let resumeAt = pending.resumeAt, resumeAt <= now {
        await resumeJourney(journey)
        continue
      }

      let due = journey.flowState.pendingAfterDelay.filter { $0.fireAt <= now }
      for item in due {
        if let runner = flowRunners[journey.id] {
          let outcome = await runner.dispatchAfterDelay(interactionId: item.interactionId, screenId: item.screenId)
          handleOutcome(outcome, journey: journey)
        }
      }
    }
  }

  // MARK: - Runtime Bridge

  fileprivate func handleRuntimeMessage(
    journeyId: String,
    type: String,
    payload: [String: Any],
    id: String?,
    controller: FlowViewController
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = flowRunners[journeyId] else { return }

    switch type {
    case "runtime/ready":
      let outcome = await runner.handleRuntimeReady()
      handleOutcome(outcome, journey: journey)
      scheduleAfterDelay(for: journey)

    case "runtime/screen_changed":
      if let screenId = payload["screenId"] as? String {
        let outcome = await runner.handleScreenChanged(screenId)
        handleOutcome(outcome, journey: journey)
        persistJourney(journey)
        cancelAfterDelayTasks(for: journey.id)
        scheduleAfterDelay(for: journey)

        eventService.track(
          "$journey_node_executed",
          properties: [
            "session_id": journey.id,
            "node_id": screenId,
            "context": journey.context.mapValues { $0.value },
          ],
          userProperties: nil,
          userPropertiesSetOnce: nil
        )
      }

    case "action/view_model_changed":
      if let path = parsePathRef(payload) {
        let value = payload["value"] ?? NSNull()
        let source = payload["source"] as? String
        let screenId = payload["screenId"] as? String ?? journey.flowState.currentScreenId
        let instanceId = payload["instanceId"] as? String
        let outcome = await runner.handleViewModelChanged(
          path: path,
          value: value,
          source: source,
          screenId: screenId,
          instanceId: instanceId
        )
        handleOutcome(outcome, journey: journey)
        persistJourney(journey)
      }

    case "action/event":
      let name = payload["name"] as? String ?? ""
      let properties = payload["properties"] as? [String: Any]
      if !name.isEmpty {
        eventService.track(
          name,
          properties: properties,
          userProperties: nil,
          userPropertiesSetOnce: nil
        )
      }

    case "action/purchase":
      if let productId = payload["productId"] as? String {
        await handlePurchase(productId: productId, controller: controller)
      }

    case "action/restore":
      await handleRestore(controller: controller)

    case let action where action.hasPrefix("action/"):
      if let trigger = parseRuntimeTrigger(type: action, payload: payload) {
        let screenId = payload["screenId"] as? String ?? journey.flowState.currentScreenId
        let componentId = payload["componentId"] as? String
        let outcome = await runner.dispatchTrigger(
          trigger: trigger,
          screenId: screenId,
          componentId: componentId,
          event: nil
        )
        handleOutcome(outcome, journey: journey)
        persistJourney(journey)
      }

    default:
      break
    }
  }

  fileprivate func handleRuntimeDismiss(
    journeyId: String,
    reason: CloseReason,
    controller: FlowViewController
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = flowRunners[journeyId] else { return }

    let outcome = await runner.dispatchTrigger(
      trigger: .screenDismissed(method: nil),
      screenId: journey.flowState.currentScreenId,
      componentId: nil,
      event: nil
    )
    handleOutcome(outcome, journey: journey)

    if !runner.hasPendingWork() {
      completeJourney(journey, reason: .completed)
    }
  }

  // MARK: - Helpers

  private func ensureRunner(for journey: Journey, campaign: Campaign) async -> FlowJourneyRunner? {
    if let existing = flowRunners[journey.id] {
      return existing
    }

    guard let flowId = campaign.flowId else { return nil }

    do {
      let flow = try await flowService.fetchFlow(id: flowId)
      let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)

      runner.onShowScreen = { [weak self, weak runner] (screenId: String, transition: AnyCodable?) async in
        guard let self else { return }
        let controller = try? await self.presentFlowIfNeeded(flowId: flowId, journey: journey)
        if let controller {
          runner?.attach(viewController: controller)
          await MainActor.run {
            var payload: [String: Any] = ["screenId": screenId]
            if let transition {
              payload["transition"] = transition.value
            }
            controller.sendRuntimeMessage(type: "runtime/show_screen", payload: payload)
          }
        }
      }

      flowRunners[journey.id] = runner

      _ = try? await presentFlowIfNeeded(flowId: flowId, journey: journey)

      eventService.track(
        JourneyEvents.flowShown,
        properties: JourneyEvents.flowShownProperties(flowId: flowId, journey: journey),
        userProperties: nil,
        userPropertiesSetOnce: nil
      )

      return runner
    } catch {
      LogError("Failed to load flow \(campaign.flowId ?? "") for journey \(journey.id): \(error)")
      return nil
    }
  }

  private func presentFlowIfNeeded(flowId: String, journey: Journey) async throws -> FlowViewController {
    if let runner = flowRunners[journey.id],
       let controller = runner.viewController,
       await flowPresentationService.isFlowPresented {
      return controller
    }
    if let delegate = runtimeDelegates[journey.id] {
      let controller = try await flowPresentationService.presentFlow(flowId, from: journey, runtimeDelegate: delegate)
      if let runner = flowRunners[journey.id] {
        runner.attach(viewController: controller)
      }
      return controller
    }

    let delegate = FlowRuntimeDelegateAdapter(journeyId: journey.id, journeyService: self)
    runtimeDelegates[journey.id] = delegate
    let controller = try await flowPresentationService.presentFlow(flowId, from: journey, runtimeDelegate: delegate)
    if let runner = flowRunners[journey.id] {
      runner.attach(viewController: controller)
    }
    return controller
  }

  private func handleOutcome(_ outcome: FlowJourneyRunner.RunOutcome?, journey: Journey) {
    guard let outcome else { return }
    switch outcome {
    case .paused(let pending):
      journey.pause(until: pending.resumeAt)
      persistJourney(journey)
      if let resumeAt = pending.resumeAt {
        scheduleResume(journeyId: journey.id, at: resumeAt)
      }
      eventService.track(
        JourneyEvents.journeyPaused,
        properties: JourneyEvents.journeyPausedProperties(
          journey: journey,
          screenId: journey.flowState.currentScreenId,
          resumeAt: pending.resumeAt
        ),
        userProperties: nil,
        userPropertiesSetOnce: nil
      )
    case .exited(let reason):
      completeJourney(journey, reason: reason)
    }
  }

  private func scheduleAfterDelay(for journey: Journey) {
    cancelAfterDelayTasks(for: journey.id)
    let now = dateProvider.now()
    for item in journey.flowState.pendingAfterDelay {
      if item.fireAt <= now {
        continue
      }
      let key = taskKey(journeyId: journey.id, kind: "after_delay", id: item.interactionId)
      scheduleTask(key: key, at: item.fireAt) { [weak self] in
        await self?.handleAfterDelay(journeyId: journey.id, interactionId: item.interactionId, screenId: item.screenId)
      }
    }
  }

  private func scheduleResume(journeyId: String, at date: Date) {
    let key = taskKey(journeyId: journeyId, kind: "resume", id: nil)
    scheduleTask(key: key, at: date) { [weak self] in
      await self?.resumeJourneyIfCached(journeyId: journeyId)
    }
  }

  private func scheduleTask(key: String, at date: Date, work: @escaping () async -> Void) {
    activeTasks[key]?.cancel()

    let delay = max(0, date.timeIntervalSince(dateProvider.now()))
    let task = Task { [weak self] in
      guard let self else { return }
      await self.runScheduledTask(key: key, delay: delay, work: work)
    }

    activeTasks[key] = task
  }

  private func runScheduledTask(key: String, delay: TimeInterval, work: @escaping () async -> Void) async {
    do {
      try await sleepProvider.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await work()
    } catch {
      LogDebug("Journey task \(key) cancelled/failed: \(error)")
    }
    clearTask(key)
  }

  private func handleAfterDelay(journeyId: String, interactionId: String, screenId: String) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = flowRunners[journeyId] else { return }

    let outcome = await runner.dispatchAfterDelay(interactionId: interactionId, screenId: screenId)
    handleOutcome(outcome, journey: journey)
  }

  private func resumeJourneyIfCached(journeyId: String) async {
    guard let journey = inMemoryJourneysById[journeyId] else { return }
    await resumeJourney(journey)
  }

  private func taskKey(journeyId: String, kind: String, id: String?) -> String {
    var key = "\(journeyId):\(kind)"
    if let id {
      key += ":\(id)"
    }
    return key
  }

  private func clearTask(_ key: String) {
    activeTasks.removeValue(forKey: key)
  }

  private func cancelAllTasks() {
    for (_, task) in activeTasks {
      task.cancel()
    }
    activeTasks.removeAll()
  }

  private func persistJourney(_ journey: Journey) {
    do {
      try journeyStore.saveJourney(journey)
      journeyStore.updateCache(for: journey)
    } catch {
      LogError("Failed to persist journey \(journey.id): \(error)")
    }
  }

  private func completeJourney(_ journey: Journey, reason: JourneyExitReason) {
    journey.complete(reason: reason)

    let duration = journey.completedAt?.timeIntervalSince(journey.startedAt)
      ?? dateProvider.now().timeIntervalSince(journey.startedAt)

    eventService.track(
      "$journey_completed",
      properties: [
        "session_id": journey.id,
        "exit_reason": reason.rawValue,
        "goal_met": journey.convertedAt != nil,
        "goal_met_at": journey.convertedAt?.timeIntervalSince1970 as Any,
        "duration_seconds": duration,
      ],
      userProperties: nil,
      userPropertiesSetOnce: nil
    )

    eventService.track(
      JourneyEvents.journeyExited,
      properties: JourneyEvents.journeyExitedProperties(
        journey: journey,
        reason: reason,
        screenId: journey.flowState.currentScreenId
      ),
      userProperties: nil,
      userPropertiesSetOnce: nil
    )

    if let originEventId = journey.getContext("_origin_event_id") as? String {
      let update = JourneyUpdate(
        journeyId: journey.id,
        campaignId: journey.campaignId,
        flowId: journey.flowId,
        exitReason: reason,
        goalMet: journey.convertedAt != nil,
        goalMetAt: journey.convertedAt,
        durationSeconds: duration,
        flowExitReason: nil
      )
      Task { await triggerBroker.emit(eventId: originEventId, update: .journey(update)) }
    }

    cancelTasks(for: journey.id)
    flowRunners.removeValue(forKey: journey.id)
    runtimeDelegates.removeValue(forKey: journey.id)
    inMemoryJourneysById.removeValue(forKey: journey.id)

    journeyStore.deleteJourney(id: journey.id)
    let record = JourneyCompletionRecord(journey: journey)
    try? journeyStore.recordCompletion(record)
  }

  private func cancelTasks(for journeyId: String) {
    let keys = activeTasks.keys.filter { $0.hasPrefix("\(journeyId):") }
    for key in keys {
      activeTasks[key]?.cancel()
      activeTasks.removeValue(forKey: key)
    }
  }

  private func cancelAfterDelayTasks(for journeyId: String) {
    let prefix = "\(journeyId):after_delay:"
    let keys = activeTasks.keys.filter { $0.hasPrefix(prefix) }
    for key in keys {
      activeTasks[key]?.cancel()
      activeTasks.removeValue(forKey: key)
    }
  }

  private func cancelJourney(_ journey: Journey) {
    journey.cancel()
    completeJourney(journey, reason: .cancelled)
  }

  // MARK: - Goals + Exit Policy

  private func evaluateGoalIfNeeded(_ journey: Journey, campaign: Campaign) async {
    guard journey.convertedAt == nil else { return }
    guard journey.goalSnapshot != nil else { return }

    let result = await goalEvaluator.isGoalMet(journey: journey, campaign: campaign)
    if result.met, let at = result.at {
      journey.convertedAt = at
      journey.updatedAt = dateProvider.now()
      persistJourney(journey)

      eventService.track(
        JourneyEvents.journeyGoalMet,
        properties: [
          "journey_id": journey.id,
          "campaign_id": journey.campaignId,
          "goal_kind": journey.goalSnapshot?.kind.rawValue ?? "",
          "met_at": at.timeIntervalSince1970,
          "window_seconds": journey.conversionWindow,
        ],
        userProperties: nil,
        userPropertiesSetOnce: nil
      )
    }
  }

  private func exitDecision(_ journey: Journey, _ campaign: Campaign) async -> JourneyExitReason? {
    if journey.hasExpired() { return .expired }

    let mode = journey.exitPolicySnapshot?.mode ?? .never

    if (mode == .onGoal || mode == .onGoalOrStop), journey.convertedAt != nil {
      return .goalMet
    }

    if mode == .onStopMatching || mode == .onGoalOrStop {
      if case .segment(let config) = campaign.trigger {
        let stillMatches = await evalConditionIR(config.condition)
        if !stillMatches {
          return .triggerUnmatched
        }
      }
    }

    return nil
  }

  // MARK: - Reentry Policy

  private func suppressionReason(campaign: Campaign, distinctId: String) -> SuppressReason? {
    if campaign.flowId == nil {
      return .noFlow
    }

    let live = inMemoryJourneysById.values.filter {
      $0.distinctId == distinctId && $0.campaignId == campaign.id && $0.status.isLive
    }
    if !live.isEmpty { return .alreadyActive }

    switch campaign.reentry {
    case .everyTime:
      return nil
    case .oneTime:
      let completed = journeyStore.hasCompletedCampaign(distinctId: distinctId, campaignId: campaign.id)
      return completed ? .reentryLimited : nil
    case .oncePerWindow(let window):
      guard let lastCompletion = journeyStore.lastCompletionTime(distinctId: distinctId, campaignId: campaign.id) else {
        return nil
      }
      let interval = windowInterval(window)
      let allowed = dateProvider.timeIntervalSince(lastCompletion) >= interval
      return allowed ? nil : .reentryLimited
    }
  }

  private func windowInterval(_ window: Window) -> TimeInterval {
    switch window.unit {
    case .minute: return TimeInterval(window.amount * 60)
    case .hour: return TimeInterval(window.amount * 3600)
    case .day: return TimeInterval(window.amount * 86400)
    case .week: return TimeInterval(window.amount * 604800)
    }
  }

  // MARK: - Campaign Lookup

  private func getCampaign(id: String) async -> Campaign? {
    guard let profile = await profileService.getCachedProfile(distinctId: identityService.getDistinctId()) else {
      return nil
    }
    return profile.campaigns.first { $0.id == id }
  }

  private func getCampaign(id: String, for distinctId: String) async -> Campaign? {
    guard let profile = await profileService.getCachedProfile(distinctId: distinctId) else {
      return nil
    }
    return profile.campaigns.first { $0.id == id }
  }

  private func getAllCampaigns() async -> [Campaign]? {
    guard let profile = await profileService.getCachedProfile(distinctId: identityService.getDistinctId()) else {
      return nil
    }
    return profile.campaigns
  }

  private func getAllCampaigns(for distinctId: String) async -> [Campaign]? {
    guard let profile = await profileService.getCachedProfile(distinctId: distinctId) else {
      return nil
    }
    return profile.campaigns
  }

  // MARK: - Trigger Evaluation

  private func shouldTriggerFromEvent(campaign: Campaign, event: NuxieEvent) async -> Bool {
    switch campaign.trigger {
    case .event(let config):
      guard config.eventName == event.name else { return false }
      if let condition = config.condition {
        return await evalConditionIR(condition, event: event)
      }
      return true
    case .segment:
      return false
    }
  }

  private func evalConditionIR(_ envelope: IREnvelope?, event: NuxieEvent? = nil) async -> Bool {
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

  // MARK: - Segment Integration

  private func registerForSegmentChanges() {
    segmentMonitoringTask?.cancel()

    segmentMonitoringTask = Task { [weak self] in
      for await result in segmentService.segmentChanges {
        guard !Task.isCancelled else { break }
        guard let self else { break }

        let currentDistinctId = await self.identityService.getDistinctId()
        guard result.distinctId == currentDistinctId else { continue }

        let currentSegments = Set(result.entered.map { $0.id } + result.remained.map { $0.id })
        await self.handleSegmentChange(distinctId: result.distinctId, segments: currentSegments)
      }
    }
  }

  // MARK: - Runtime Helpers

  private func parseRuntimeTrigger(type: String, payload: [String: Any]) -> InteractionTrigger? {
    if let triggerPayload = payload["trigger"] as? [String: Any] {
      return parseTriggerDict(triggerPayload)
    }
    if let triggerType = payload["trigger"] as? String {
      return parseTriggerType(triggerType, payload: payload)
    }

    let fallback = type.hasPrefix("action/") ? String(type.dropFirst("action/".count)) : type
    return parseTriggerType(fallback, payload: payload)
  }

  private func parseTriggerDict(_ payload: [String: Any]) -> InteractionTrigger? {
    if let type = payload["type"] as? String {
      return parseTriggerType(type, payload: payload)
    }
    if let type = payload["trigger"] as? String {
      return parseTriggerType(type, payload: payload)
    }
    return nil
  }

  private func parseTriggerType(_ raw: String, payload: [String: Any]) -> InteractionTrigger? {
    let normalized = raw
      .replacingOccurrences(of: "action/", with: "")
      .replacingOccurrences(of: "-", with: "_")
      .lowercased()

    switch normalized {
    case "tap":
      return .tap
    case "long_press", "longpress":
      let minMs = parseInt(payload["minMs"] ?? payload["min_ms"])
      return .longPress(minMs: minMs)
    case "hover":
      return .hover
    case "press":
      return .press
    case "drag":
      let direction = (payload["direction"] as? String)
        .flatMap { InteractionTrigger.DragDirection(rawValue: $0) }
      let threshold = parseDouble(payload["threshold"])
      return .drag(direction: direction, threshold: threshold)
    case "manual":
      return .manual(label: payload["label"] as? String)
    case "screen_dismissed":
      return .screenDismissed(method: payload["method"] as? String)
    case "after_delay":
      let delayMs = parseInt(payload["delayMs"] ?? payload["delay_ms"]) ?? 0
      return .afterDelay(delayMs: delayMs)
    default:
      return nil
    }
  }

  private func parseInt(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? Double { return Int(value) }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
  }

  private func parseDouble(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
  }

  private func parsePathRef(_ payload: [String: Any]) -> VmPathRef? {
    let isRelative = payload["isRelative"] as? Bool
    let nameBased = payload["nameBased"] as? Bool
    if let pathIds = payload["pathIds"] as? [Int] {
      return .ids(VmPathIds(pathIds: pathIds, isRelative: isRelative, nameBased: nameBased))
    }
    if let pathIds = payload["pathIds"] as? [NSNumber] {
      return .ids(VmPathIds(pathIds: pathIds.map { $0.intValue }, isRelative: isRelative, nameBased: nameBased))
    }
    return nil
  }

  private func handlePurchase(productId: String, controller: FlowViewController) async {
    let transactionService = Container.shared.transactionService()
    let productService = Container.shared.productService()

    await MainActor.run {
      Task { @MainActor in
        do {
          let products = try await productService.fetchProducts(for: [productId])
          guard let product = products.first else {
            controller.sendRuntimeMessage(type: "purchase_error", payload: ["error": "Product not found"])
            return
          }
          let syncResult = try await transactionService.purchase(product)
          controller.sendRuntimeMessage(type: "purchase_ui_success", payload: ["productId": productId])
          if let syncTask = syncResult.syncTask {
            let confirmed = await syncTask.value
            if confirmed {
              controller.sendRuntimeMessage(type: "purchase_confirmed", payload: ["productId": productId])
            }
          }
        } catch StoreKitError.purchaseCancelled {
          controller.sendRuntimeMessage(type: "purchase_cancelled", payload: [:])
        } catch {
          controller.sendRuntimeMessage(type: "purchase_error", payload: ["error": error.localizedDescription])
        }
      }
    }
  }

  private func handleRestore(controller: FlowViewController) async {
    let transactionService = Container.shared.transactionService()

    await MainActor.run {
      Task { @MainActor in
        do {
          try await transactionService.restore()
          controller.sendRuntimeMessage(type: "restore_success", payload: [:])
        } catch {
          controller.sendRuntimeMessage(type: "restore_error", payload: ["error": error.localizedDescription])
        }
      }
    }
  }
}

private final class FlowRuntimeDelegateAdapter: FlowRuntimeDelegate {
  private weak var journeyService: JourneyService?
  private let journeyId: String

  init(journeyId: String, journeyService: JourneyService) {
    self.journeyId = journeyId
    self.journeyService = journeyService
  }

  func flowViewController(
    _ controller: FlowViewController,
    didReceiveRuntimeMessage type: String,
    payload: [String : Any],
    id: String?
  ) {
    Task { [weak journeyService] in
      await journeyService?.handleRuntimeMessage(
        journeyId: journeyId,
        type: type,
        payload: payload,
        id: id,
        controller: controller
      )
    }
  }

  func flowViewControllerDidRequestDismiss(_ controller: FlowViewController, reason: CloseReason) {
    Task { [weak journeyService] in
      await journeyService?.handleRuntimeDismiss(
        journeyId: journeyId,
        reason: reason,
        controller: controller
      )
    }
  }
}
