import FactoryKit
import Foundation
import UIKit

/// Reason for resuming a journey
public enum ResumeReason {
  case start              // Journey just started
  case timer              // Timer/schedule-based resume
  case event(NuxieEvent)  // Event-driven resume
  case segmentChange      // Segment change-driven resume
  
  /// Whether this is a reactive resume (event or segment change)
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
  /// Start a new journey for a campaign
  @discardableResult
  func startJourney(for campaign: Campaign, distinctId: String, originEventId: String?) async -> Journey?

  /// Resume a paused journey
  func resumeJourney(_ journey: Journey) async

  /// Handle an event (may trigger or resume journeys)
  func handleEvent(_ event: NuxieEvent) async

  /// Handle segment change
  func handleSegmentChange(distinctId: String, segments: Set<String>) async

  /// Get all active journeys for a user
  func getActiveJourneys(for distinctId: String) async -> [Journey]

  /// Check and resume expired timers (called on app foreground)
  func checkExpiredTimers() async

  /// Initialize service and restore journeys
  func initialize() async

  func onAppWillEnterForeground() async

  func onAppBecameActive() async

  func onAppDidEnterBackground() async

  /// Shutdown service
  func shutdown() async
  
  /// Handle user change (identity transition)
  func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async
}

/// High-level orchestrator for the journey system
public actor JourneyService: JourneyServiceProtocol {

  // MARK: - Dependencies

  private let journeyStore: JourneyStoreProtocol
  private let journeyExecutor: JourneyExecutorProtocol
  @Injected(\.profileService) private var profileService: ProfileServiceProtocol
  @Injected(\.identityService) private var identityService: IdentityServiceProtocol
  @Injected(\.segmentService) private var segmentService: SegmentServiceProtocol
  @Injected(\.featureService) private var featureService: FeatureServiceProtocol
  @Injected(\.dateProvider) private var dateProvider: DateProviderProtocol
  @Injected(\.sleepProvider) private var sleepProvider: SleepProviderProtocol
  @Injected(\.goalEvaluator) private var goalEvaluator: GoalEvaluatorProtocol
  @Injected(\.irRuntime) private var irRuntime: IRRuntime

  // MARK: - Properties

  /// In-memory registry of all live journeys (the single source of truth for running/paused)
  private var inMemoryJourneysById: [String: Journey] = [:]

  /// Active tasks for journey resumption
  private var activeTasks: [String: Task<Void, Never>] = [:]

  /// Task for monitoring segment changes
  private var segmentMonitoringTask: Task<Void, Never>?

  // MARK: - Initialization

  internal init(
    journeyStore: JourneyStoreProtocol? = nil,
    journeyExecutor: JourneyExecutorProtocol? = nil,
    customStoragePath: URL? = nil
  ) {
    // Use injected dependencies or create new instances
    self.journeyStore = journeyStore ?? JourneyStore(customStoragePath: customStoragePath)
    self.journeyExecutor = journeyExecutor ?? JourneyExecutor()
    
    LogInfo("JourneyService initialized")
  }

  deinit {
    segmentMonitoringTask?.cancel()
  }

  /// Initialize service and restore journeys
  public func initialize() async {
    LogInfo("Initializing JourneyService...")

    // Hydrate live registry from persisted journeys
    let persisted = journeyStore.loadActiveJourneys()
    LogInfo("Restored \(persisted.count) active journeys")

    for journey in persisted where journey.status.isLive {
      inMemoryJourneysById[journey.id] = journey

      // Schedule resume if needed
      if journey.status == .paused, let resumeAt = journey.resumeAt {
        await scheduleResume(journey, at: resumeAt)
      }
    }

    // Check for expired timers
    await checkExpiredTimers()

    // Register for segment changes
    registerForSegmentChanges()
  }

  public func onAppWillEnterForeground() async {
    // 1) Resume any timers that already matured
    await checkExpiredTimers()

    // 2) Re-arm not-yet-matured timers
    let candidates = getAllLiveJourneys().filter { $0.status == .paused }
    var scheduled = 0
    for journey in candidates {
      if let at = journey.resumeAt, at > dateProvider.now() {
        scheduleResume(journey, at: at)
        scheduled += 1
      }
    }
    if scheduled > 0 { LogInfo("Re-armed \(scheduled) journey timers") }
  }

  public func onAppBecameActive() async {
    // No-op for now; the normal execution path will present flows as nodes run.
    // But this hook gives us a place to nudge journeys that were waiting on "app active", if we add that later.
  }

  public func onAppDidEnterBackground() async {
    await self.cancelAllTasks()
    // Persist any paused journeys (already done). Optionally also persist active journeys that are at a node boundary.
    let journeys = await self.getAllLiveJourneys()
    for j in journeys where j.status == .paused {
      await self.persistJourney(j)
    }
    LogInfo("JourneyService background snapshot complete")
  }

  /// Shutdown service
  public func shutdown() async {
    segmentMonitoringTask?.cancel()
    segmentMonitoringTask = nil
    cancelAllTasks()
  }
  
  /// Handle user change (identity transition)
  public func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
    LogInfo("JourneyService handling user change from \(NuxieLogger.shared.logDistinctID(oldDistinctId)) to \(NuxieLogger.shared.logDistinctID(newDistinctId))")
    
    // Cancel all journeys for the old user
    let oldUserJourneys = await getActiveJourneys(for: oldDistinctId)
    for journey in oldUserJourneys {
      LogDebug("Cancelling journey \(journey.id) for old user")
      cancelJourney(journey)
    }
    
    // Clear in-memory registry for old user
    let keysToRemove = inMemoryJourneysById.keys.filter { key in
      inMemoryJourneysById[key]?.distinctId == oldDistinctId
    }
    for key in keysToRemove {
      inMemoryJourneysById.removeValue(forKey: key)
    }
    
    // Load persisted journeys for new user
    let persisted = journeyStore.loadActiveJourneys()
      .filter { $0.distinctId == newDistinctId && $0.status.isLive }
    
    LogInfo("Loaded \(persisted.count) active journeys for new user")
    
    for journey in persisted {
      inMemoryJourneysById[journey.id] = journey
      
      // Schedule resume if needed
      if journey.status == .paused, let resumeAt = journey.resumeAt {
        await scheduleResume(journey, at: resumeAt)
      }
    }
    
    // Check for expired timers for the new user
    await checkExpiredTimers()
  }

  // MARK: - Public Methods

  /// Start a new journey for a campaign
  public func startJourney(for campaign: Campaign, distinctId: String, originEventId: String? = nil) async -> Journey? {
    LogDebug("[JourneyService] startJourney called for campaign: \(campaign.id), user: \(distinctId)")
    // Check if user can start this journey
    guard canStartJourney(campaign: campaign, distinctId: distinctId) else {
      LogDebug("User \(distinctId) cannot start journey for campaign \(campaign.id)")
      LogDebug("[JourneyService] User cannot start journey (frequency policy check failed)")
      return nil
    }

    LogInfo("Starting journey for campaign \(campaign.name) (\(campaign.id)), user \(distinctId)")
    LogDebug("[JourneyService] Creating new journey...")

    // Create new journey
    let journey = Journey(campaign: campaign, distinctId: distinctId)
    journey.status = .active
    if let originEventId = originEventId {
      journey.setContext("_origin_event_id", value: originEventId)
    }

    // Put it in the identity map *before* execution so callers can find it immediately
    inMemoryJourneysById[journey.id] = journey
    LogDebug(
      "[JourneyService] Stored journey \(journey.id) in registry. Total journeys: \(inMemoryJourneysById.count)"
    )

    // Execute journey
    await executeJourney(journey, campaign: campaign, reason: .start)

    return journey
  }

  /// Resume a paused journey
  public func resumeJourney(_ journey: Journey) async {
    guard journey.status == .paused else {
      LogWarning("Cannot resume journey \(journey.id) - not paused")
      return
    }

    LogInfo("Resuming journey \(journey.id)")

    // Get campaign for the journey's user
    guard let campaign = await getCampaign(id: journey.campaignId, for: journey.distinctId) else {
      LogError("Campaign not found for journey \(journey.id)")
      cancelJourney(journey)
      return
    }

    // Work on the canonical instance from registry
    let canonical = inMemoryJourneysById[journey.id] ?? journey

    canonical.resume()
    inMemoryJourneysById[canonical.id] = canonical

    // Continue execution (timer-based resume)
    await executeJourney(canonical, campaign: campaign, reason: .timer)
  }

  /// Handle an event (may trigger or resume journeys)
  public func handleEvent(_ event: NuxieEvent) async {
    LogDebug("JourneyService handling event: \(event.name)")
    LogDebug("[JourneyService] handleEvent called: \(event.name) for user: \(event.distinctId)")

    // Fetch campaigns for THIS user
    guard let campaigns = await getAllCampaigns(for: event.distinctId) else {
      LogDebug("[JourneyService] No campaigns available")
      return
    }
    LogDebug("[JourneyService] Found \(campaigns.count) campaigns")

    // Check each campaign for triggers
    for campaign in campaigns {
      LogDebug("[JourneyService] Checking campaign: \(campaign.id)")
      if await shouldTriggerFromEvent(campaign: campaign, event: event) {
        LogDebug("[JourneyService] Event triggered campaign \(campaign.id), starting journey")
        _ = await startJourney(for: campaign, distinctId: event.distinctId, originEventId: event.id)
      } else {
        LogDebug("[JourneyService] Event did not trigger campaign \(campaign.id)")
      }
    }

    // Evaluate/latch goals for active journeys (event-time semantics for event goals)
    let activeJourneys = await getActiveJourneys(for: event.distinctId)
    for journey in activeJourneys {
      guard let campaign = campaigns.first(where: { $0.id == journey.campaignId }) else {
        continue
      }

      // Fast path for event-goal journeys: latch based on the *event's timestamp* being within the window
      if let goal = journey.goalSnapshot,
        goal.kind == .event,
        let goalEvent = goal.eventName,
        goalEvent == event.name
      {
        let anchor = journey.conversionAnchorAt
        var isInWindow = event.timestamp >= anchor
        if isInWindow, journey.conversionWindow > 0 {
          let windowEnd = anchor.addingTimeInterval(journey.conversionWindow)
          isInWindow = (event.timestamp <= windowEnd)
        }

        if isInWindow {
          // (Phase 2: apply goal.eventFilter via IR before latching, if present)
          // Latch conversion at the *event* time; keep the earliest conversion
          if let existing = journey.convertedAt {
            if event.timestamp < existing {
              journey.convertedAt = event.timestamp
              journey.updatedAt = dateProvider.now()
              persistJourney(journey)  // Persist immediately after updating convertedAt
            }
          } else {
            journey.convertedAt = event.timestamp
            journey.updatedAt = dateProvider.now()
            persistJourney(journey)  // Persist immediately after setting convertedAt
          }

          LogInfo(
            "Latched conversion for journey \(journey.id) at \(event.timestamp) via event-time window"
          )

          // Evaluate goal & exit if the policy allows
          let result = await goalEvaluator.isGoalMet(journey: journey, campaign: campaign)
          if result.met {
            // Respect exit policy (use snapshot to avoid mid-journey changes)
            let mode = journey.exitPolicySnapshot?.mode ?? .never
            switch mode {
            case .onGoal, .onGoalOrStop:
              LogInfo(
                "Journey \(journey.id) exiting due to goalMet (event-time) for campaign \(campaign.id)"
              )
              completeJourney(journey, reason: .goalMet)
              continue
            case .never, .onStopMatching:
              // Do not exit here; keep running. convertedAt remains set for reporting or later checks.
              break
            }
          }
        } else {
          LogDebug(
            "Event \(event.name) for journey \(journey.id) not within event-time window (anchor: \(anchor), window: \(journey.conversionWindow))"
          )
        }
      } else {
        // Non-event goals still follow evaluation-time semantics; keep your existing evaluation flow
        // Optionally evaluate goals generically when any event arrives
      }

      // Generic evaluation for any goal types (kept from your original flow)
      await evaluateGoalIfNeeded(journey, campaign: campaign)

      // Check if journey should exit after evaluation
      if let reason = await exitDecision(journey, campaign) {
        LogInfo("Journey \(journey.id) exiting with reason \(reason) after event \(event.name)")
        completeJourney(journey, reason: reason)
      }
    }

    // Check if any waiting journeys should resume
    await tryReactiveResume(for: event.distinctId, event: event)
  }

  /// Handle segment change
  public func handleSegmentChange(distinctId: String, segments: Set<String>) async {
    LogDebug("JourneyService handling segment change for user \(distinctId)")

    // Get all campaigns
    guard let campaigns = await getAllCampaigns() else {
      return
    }

    // Evaluate segment-triggered campaigns for new journeys
    for campaign in campaigns {
      // Only segment-triggered campaigns
      guard case .segment(let config) = campaign.trigger else {
        continue
      }

      // Evaluate segment condition using IR interpreter
      let qualifies = await evalConditionIR(config.condition)
      if qualifies {
        _ = await startJourney(for: campaign, distinctId: distinctId)
      }
    }

    // Check active journeys for stop-matching conditions
    let activeJourneys = await getActiveJourneys(for: distinctId)
    for journey in activeJourneys {
      guard let campaign = campaigns.first(where: { $0.id == journey.campaignId }) else {
        continue
      }

      // Check if journey should exit (handles both stop-matching and goal-based exits)
      if let reason = await exitDecision(journey, campaign) {
        LogInfo("Journey \(journey.id) exiting with reason \(reason) after segment change")
        completeJourney(journey, reason: reason)
      }

      // Also check for segment-based goals
      if let goal = journey.goalSnapshot,
        goal.kind == .segmentEnter || goal.kind == .segmentLeave
      {
        await evaluateGoalIfNeeded(journey, campaign: campaign)

        // Check if journey should exit after goal evaluation
        if let reason = await exitDecision(journey, campaign) {
          LogInfo("Journey \(journey.id) exiting with reason \(reason) after segment change")
          completeJourney(journey, reason: reason)
        }
      }
    }

    // Check any waiting journeys that should resume
    await tryReactiveResume(for: distinctId, event: nil)
  }

  /// Get all active journeys for a user (reads from memory, not disk)
  public func getActiveJourneys(for distinctId: String) async -> [Journey] {
    LogDebug("[JourneyService] getActiveJourneys called for \(distinctId)")
    LogDebug("[JourneyService] Total journeys in registry: \(inMemoryJourneysById.count)")
    let allJourneys = Array(inMemoryJourneysById.values)
    LogDebug("[JourneyService] All journeys: \(allJourneys.map { "\($0.id): \($0.status)" })")
    let userJourneys = allJourneys.filter { $0.distinctId == distinctId }
    LogDebug("[JourneyService] User journeys: \(userJourneys.map { "\($0.id): \($0.status)" })")
    let liveJourneys = userJourneys.filter { $0.status.isLive }
    LogDebug("[JourneyService] Live journeys: \(liveJourneys.map { "\($0.id): \($0.status)" })")
    return liveJourneys
  }

  /// Get all live journeys (internal helper)
  private func getAllLiveJourneys() -> [Journey] {
    return Array(inMemoryJourneysById.values.filter { $0.status.isLive })
  }

  /// Check and resume expired timers (called on app foreground)
  public func checkExpiredTimers() async {
    LogDebug("Checking for expired journey timers...")

    // Iterate memory, not disk
    let candidates = Array(inMemoryJourneysById.values.filter { $0.status.isLive })
    var resumeCount = 0

    for journey in candidates {
      if journey.status == .paused && journey.shouldResume() {
        await resumeJourney(journey)
        resumeCount += 1
      }
    }

    if resumeCount > 0 {
      LogInfo("Resumed \(resumeCount) journeys with expired timers")
    }
  }

  // MARK: - Private Methods

  /// Evaluate and update goal status for a journey
  private func evaluateGoalIfNeeded(_ journey: Journey, campaign: Campaign) async {
    LogDebug("[JourneyService.evaluateGoalIfNeeded] Called for journey \(journey.id)")
    
    // Skip if already converted
    guard journey.convertedAt == nil else {
      LogDebug("[JourneyService.evaluateGoalIfNeeded] Journey already converted at \(journey.convertedAt!), skipping")
      return
    }

    // Skip if no goal configured
    guard journey.goalSnapshot != nil else {
      LogDebug("[JourneyService.evaluateGoalIfNeeded] No goal configured, skipping")
      return
    }

    LogDebug("[JourneyService.evaluateGoalIfNeeded] Evaluating goal for journey \(journey.id)")
    let result = await goalEvaluator.isGoalMet(journey: journey, campaign: campaign)
    LogDebug("[JourneyService.evaluateGoalIfNeeded] Goal evaluation result: met=\(result.met), at=\(String(describing: result.at))")
    
    if result.met, let at = result.at {
      LogDebug("[JourneyService.evaluateGoalIfNeeded] Setting journey.convertedAt to \(at)")
      journey.convertedAt = at
      journey.updatedAt = dateProvider.now()
      persistJourney(journey)  // Persist immediately after setting convertedAt
      LogInfo("Journey \(journey.id) achieved goal at \(at)")

      // Track telemetry event
      Container.shared.eventService().track(
        JourneyEvents.journeyGoalMet,
        properties: [
          "journey_id": journey.id,
          "campaign_id": journey.campaignId,
          "goal_kind": journey.goalSnapshot?.kind.rawValue ?? "",
          "met_at": at.timeIntervalSince1970,
          "window_seconds": journey.conversionWindow,
        ],
        userProperties: nil,
        userPropertiesSetOnce: nil,
        completion: nil
      )
    } else {
      LogDebug("[JourneyService.evaluateGoalIfNeeded] Goal not met, journey continues")
    }
  }

  /// Consolidated exit decision function that checks all exit conditions
  private func exitDecision(_ journey: Journey, _ campaign: Campaign) async -> JourneyExitReason? {
    LogDebug("[JourneyService.exitDecision] Checking exit conditions for journey \(journey.id)")
    LogDebug("[JourneyService.exitDecision] Journey status: \(journey.status)")
    LogDebug("[JourneyService.exitDecision] Journey.convertedAt: \(String(describing: journey.convertedAt))")
    
    // 1. Check if journey expired
    if journey.hasExpired() {
      LogDebug("[JourneyService.exitDecision] Journey has expired")
      return .expired
    }

    // Get exit policy (default to never if not set)
    let mode = journey.exitPolicySnapshot?.mode ?? .never
    LogDebug("[JourneyService.exitDecision] Exit policy mode: \(mode)")

    // 2. Check exit on goal (if configured)
    if mode == .onGoal || mode == .onGoalOrStop {
      // If already converted, exit immediately
      if journey.convertedAt != nil {
        LogDebug("[JourneyService.exitDecision] Journey already converted at \(journey.convertedAt!), exiting with goalMet")
        return .goalMet
      } else {
        LogDebug("[JourneyService.exitDecision] Goal-based exit enabled but not yet converted")
      }
    }

    // 3. Check stop-matching for segment-triggered campaigns
    if mode == .onStopMatching || mode == .onGoalOrStop {
      if case .segment(let config) = campaign.trigger {
        LogDebug("[JourneyService.exitDecision] Checking stop-matching for segment-triggered campaign")
        // Re-evaluate the trigger condition
        let stillMatches = await evalConditionIR(config.condition)
        if !stillMatches {
          LogDebug("[JourneyService.exitDecision] Journey no longer matches trigger, exiting with triggerUnmatched")
          return .triggerUnmatched
        }
      }
    }

    LogDebug("[JourneyService.exitDecision] No exit conditions met, journey continues")
    return nil
  }

  private func executeJourney(
    _ journey: Journey,
    campaign: Campaign,
    reason: ResumeReason = .start
  ) async {
    LogDebug(
      "[JourneyService] executeJourney starting with currentNodeId: \(journey.currentNodeId ?? "nil")"
    )

    // Evaluate goal before starting
    await evaluateGoalIfNeeded(journey, campaign: campaign)

    // Check exit conditions before continuing
    if let reason = await exitDecision(journey, campaign) {
      LogDebug("[JourneyService] Journey should exit with reason: \(reason)")
      completeJourney(journey, reason: reason)
      return
    }

    var iterationCount = 0
    var currentReason = reason
    // Execute nodes until we hit an async point or complete
    while let currentNodeId = journey.currentNodeId {
      iterationCount += 1
      LogDebug("[JourneyService] Iteration \(iterationCount): Processing node \(currentNodeId)")

      // Re-evaluate goal before each node execution
      await evaluateGoalIfNeeded(journey, campaign: campaign)

      // Check exit conditions before executing node
      if let reason = await exitDecision(journey, campaign) {
        LogDebug("[JourneyService] Journey should exit with reason: \(reason)")
        completeJourney(journey, reason: reason)
        return
      }

      // Find current node
      guard let node = journeyExecutor.findNode(id: currentNodeId, in: campaign) else {
        LogError("Node \(currentNodeId) not found in campaign \(campaign.id)")
        LogDebug("[JourneyService] ERROR: Node \(currentNodeId) not found!")
        completeJourney(journey, reason: .error)
        return
      }

      LogDebug("[JourneyService] Found node \(currentNodeId) of type \(node.type)")

      // Execute node with resume reason (only use event/segment reason for first node)
      let result = await journeyExecutor.executeNode(
        node,
        journey: journey,
        resumeReason: currentReason
      )
      // After first node, subsequent nodes use start reason
      currentReason = .start
      LogDebug("[JourneyService] Node \(currentNodeId) execution result: \(result)")

      switch result {
      case .continue(let nextNodeIds):
        // Move to next node(s)
        let nextNodeId = nextNodeIds.first
        LogDebug("[JourneyService] Continue to next node: \(nextNodeId ?? "nil")")
        journey.currentNodeId = nextNodeId
        journey.updatedAt = dateProvider.now()
        inMemoryJourneysById[journey.id] = journey

      case .skip(let skipToNodeId):
        // Skip to specific node
        LogDebug("[JourneyService] Skip to node: \(skipToNodeId ?? "nil")")
        journey.currentNodeId = skipToNodeId
        journey.updatedAt = dateProvider.now()
        inMemoryJourneysById[journey.id] = journey

      case .async(let resumeAt):
        // Enter wait state
        LogDebug(
          "[JourneyService] Journey \(journey.id) entering async state (paused until \(String(describing: resumeAt)))"
        )
        journey.pause(until: resumeAt)
        inMemoryJourneysById[journey.id] = journey
        LogDebug("[JourneyService] Journey \(journey.id) status: \(journey.status)")
        persistJourney(journey)

        // Schedule resume if there's a deadline
        if let resumeAt = resumeAt {
          scheduleResume(journey, at: resumeAt)
        }
        return

      case .complete(let reason):
        // Journey complete
        LogDebug("[JourneyService] Journey complete with reason: \(reason)")
        completeJourney(journey, reason: reason)
        return
      }
    }

    // No more nodes - complete journey
    LogDebug("[JourneyService] No more nodes to execute - completing journey")
    completeJourney(journey, reason: .completed)
  }

  private func completeJourney(_ journey: Journey, reason: JourneyExitReason) {
    LogInfo("Completing journey \(journey.id) with reason: \(reason)")

    journey.complete(reason: reason)
    
    // Calculate journey duration
    let duration = journey.completedAt?.timeIntervalSince(journey.startedAt) ?? dateProvider.now().timeIntervalSince(journey.startedAt)
    
    // Track journey exit event for observability
    Container.shared.eventService().track(
      JourneyEvents.journeyExited,
      properties: JourneyEvents.journeyExitedProperties(
        journey: journey,
        exitReason: reason,
        durationSeconds: duration
      ),
      userProperties: nil,
      userPropertiesSetOnce: nil,
      completion: nil
    )

    // Remove from in-memory registry and tasks
    LogDebug("[JourneyService] Removing journey \(journey.id) from registry (reason: \(reason))")
    inMemoryJourneysById.removeValue(forKey: journey.id)
    activeTasks[journey.id]?.cancel()
    activeTasks.removeValue(forKey: journey.id)
    LogDebug("[JourneyService] Remaining journeys: \(inMemoryJourneysById.count)")

    // Delete persisted journey file
    journeyStore.deleteJourney(id: journey.id)

    // Record completion for frequency policy
    let record = JourneyCompletionRecord(journey: journey)
    try? journeyStore.recordCompletion(record)
  }

  private func cancelJourney(_ journey: Journey) {
    journey.cancel()
    completeJourney(journey, reason: .cancelled)
  }

  private func persistJourney(_ journey: Journey) {
    do {
      try journeyStore.saveJourney(journey)
      journeyStore.updateCache(for: journey)
    } catch {
      LogError("Failed to persist journey \(journey.id): \(error)")
    }
  }

  // MARK: - Frequency Policy

  private func canStartJourney(campaign: Campaign, distinctId: String) -> Bool {
    // Check in-memory registry for live journeys
    let liveJourneys = inMemoryJourneysById.values.filter {
      $0.distinctId == distinctId && $0.campaignId == campaign.id && $0.status.isLive
    }
    let hasLive = !liveJourneys.isEmpty

    // Parse frequency policy
    let policy = FrequencyPolicy(rawValue: campaign.frequencyPolicy) ?? .everyRematch

    switch policy {
    case .once:
      return !journeyStore.hasCompletedCampaign(distinctId: distinctId, campaignId: campaign.id)

    case .everyRematch:
      return !hasLive

    case .fixedInterval:
      if hasLive {
        // Check if we can cancel and restart based on time since journey started
        if let interval = campaign.frequencyInterval {
          // Get the live journey to check its start time
          if let liveJourney = liveJourneys.first {
            let elapsed = dateProvider.timeIntervalSince(liveJourney.startedAt)
            if elapsed >= interval {
              // Cancel old journey and allow new one
              Task {
                await cancelActiveJourneys(distinctId: distinctId, campaignId: campaign.id)
              }
              return true
            }
          }
        }
        return false
      }

      // Check time since last completion
      if let interval = campaign.frequencyInterval,
        let lastTime = journeyStore.lastCompletionTime(
          distinctId: distinctId, campaignId: campaign.id)
      {
        return dateProvider.timeIntervalSince(lastTime) >= interval
      }

      return true
    }
  }

  private func cancelActiveJourneys(distinctId: String, campaignId: String) async {
    let journeys = await getActiveJourneys(for: distinctId)
      .filter { $0.campaignId == campaignId }

    for journey in journeys {
      cancelJourney(journey)
    }
  }

  // MARK: - Task Management

  private func scheduleResume(_ journey: Journey, at date: Date) {
    // Cancel any existing task
    activeTasks[journey.id]?.cancel()

    let delay = max(0, date.timeIntervalSince(dateProvider.now()))
    let journeyId = journey.id  // Capture ID only, not the entire journey object

    let task = Task { [weak self] in
      do {
        try await self?.sleepProvider.sleep(for: delay)
        guard let self = self, !Task.isCancelled else { return }
        
        // Re-read canonical instance from registry
        if let journey = await self.inMemoryJourneysById[journeyId] {
          await self.resumeJourney(journey)
        }
      } catch {
        // Sleep was cancelled or failed, which is expected during app lifecycle changes
        LogDebug("Journey \(journeyId) resume task cancelled/failed: \(error)")
      }
      // Remove the finished task to release its captures ASAP
      await self?.clearTask(for: journeyId)
    }

    activeTasks[journey.id] = task
    LogDebug("Scheduled journey \(journey.id) to resume at \(date)")
  }

  private func clearTask(for journeyId: String) {
    activeTasks.removeValue(forKey: journeyId)
  }

  private func cancelAllTasks() {
    for (_, task) in activeTasks {
      task.cancel()
    }
    activeTasks.removeAll()
  }

  // MARK: - Segment Integration

  private func registerForSegmentChanges() {
    // Cancel any existing monitoring task
    segmentMonitoringTask?.cancel()

    // Start monitoring segment changes via AsyncStream
    segmentMonitoringTask = Task { [weak self] in
      LogInfo("Starting segment change monitoring")

      for await result in segmentService.segmentChanges {
        guard !Task.isCancelled else { break }

        guard let self = self else { break }
        
        // Get current user ID
        let currentDistinctId = await self.identityService.getDistinctId()
        
        // IMPORTANT: Only process segment changes for the current user
        // This prevents race conditions during identity transitions
        guard result.distinctId == currentDistinctId else {
          LogDebug("Ignoring segment change for user \(NuxieLogger.shared.logDistinctID(result.distinctId)) (current user: \(NuxieLogger.shared.logDistinctID(currentDistinctId)))")
          continue
        }

        // Build current segment set from memberships
        let currentSegments = Set(result.entered.map { $0.id } + result.remained.map { $0.id })

        // Handle segment changes for journey triggers
        await self.handleSegmentChange(distinctId: result.distinctId, segments: currentSegments)

        // Log segment changes for debugging
        for segment in result.entered {
          LogInfo("User entered segment '\(segment.name)' - checking for journey triggers")
        }
        for segment in result.exited {
          LogInfo("User exited segment '\(segment.name)'")
        }
      }

      LogInfo("Segment change monitoring stopped")
    }

    LogInfo("Registered for segment change notifications")
  }

  // MARK: - Helper Methods

  private func makeTrackingKey(distinctId: String, campaignId: String) -> String {
    return "\(distinctId):\(campaignId)"
  }

  // MARK: - IR Evaluation

  private func evalConditionIR(
    _ envelope: IREnvelope?, journey: Journey? = nil, event: NuxieEvent? = nil
  ) async -> Bool {
    // No condition means always true
    guard let envelope = envelope else { return true }
    
    // Create adapters for the services
    let userAdapter = IRUserPropsAdapter(identityService: identityService)
    let eventsAdapter = IREventQueriesAdapter(eventService: Container.shared.eventService())
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

  private func shouldTriggerFromEvent(campaign: Campaign, event: NuxieEvent) async -> Bool {
    guard case .event(let config) = campaign.trigger,
      config.eventName == event.name
    else {
      return false
    }

    // Evaluate trigger condition if present
    if let condition = config.condition {
      return await evalConditionIR(condition, event: event)
    }

    return true
  }

  private func evaluateSegmentExpression(_ expression: String, userSegments: Set<String>) async
    -> Bool
  {
    // Check if this is a simple segment ID reference
    if !expression.contains("&&") && !expression.contains("||") && !expression.contains("!") {
      // Just a segment ID - check SegmentService membership
      return await segmentService.isInSegment(expression)
    }

    // For complex expressions, we would need the IR envelope
    // Since we only have a string expression here, we can't use IR evaluation
    // This would need to be refactored to accept an IREnvelope instead
    LogWarning(
      "Complex segment expression evaluation not supported without IR envelope: \(expression)")
    return false
  }


  private func getCampaign(id: String) async -> Campaign? {
    let distinctId = identityService.getDistinctId()
    let response = try? await profileService.fetchProfile(distinctId: distinctId)
    return response?.campaigns.first { $0.id == id }
  }

  // Overload: fetch campaign for a specific distinctId
  private func getCampaign(id: String, for distinctId: String) async -> Campaign? {
    let response = try? await profileService.fetchProfile(distinctId: distinctId)
    return response?.campaigns.first { $0.id == id }
  }

  private func getAllCampaigns() async -> [Campaign]? {
    let distinctId = identityService.getDistinctId()
    LogDebug("[JourneyService] Getting campaigns for distinctId: \(distinctId)")

    do {
      let response = try await profileService.fetchProfile(distinctId: distinctId)
      LogDebug(
        "[JourneyService] Profile fetch successful, campaigns count: \(response.campaigns.count)")
      return response.campaigns
    } catch {
      LogDebug("[JourneyService] Profile fetch failed: \(error)")
      return nil
    }
  }

  // Overload: fetch campaigns for a specific distinctId
  private func getAllCampaigns(for distinctId: String) async -> [Campaign]? {
    LogDebug("[JourneyService] Getting campaigns for distinctId: \(distinctId)")
    do {
      let response = try await profileService.fetchProfile(distinctId: distinctId)
      LogDebug(
        "[JourneyService] Profile fetch successful, campaigns count: \(response.campaigns.count)")
      return response.campaigns
    } catch {
      LogDebug("[JourneyService] Profile fetch failed: \(error)")
      return nil
    }
  }

  /// Try to resume paused wait-until journeys for a user due to a reactive trigger (event/segment change)
  private func tryReactiveResume(for distinctId: String, event: NuxieEvent? = nil) async {
    let paused = await getActiveJourneys(for: distinctId).filter { $0.status == .paused }
    guard !paused.isEmpty else { return }

    // Fetch campaigns for THIS user
    guard let campaigns = await getAllCampaigns(for: distinctId) else { return }

    for journey in paused {
      guard let campaign = campaigns.first(where: { $0.id == journey.campaignId }),
        let nodeId = journey.currentNodeId,
        let node = journeyExecutor.findNode(id: nodeId, in: campaign)
      else { continue }

      // Only wait-until reacts (time-window will self-resume by schedule)
      if node.type == .waitUntil {
        // Resume the canonical in-memory instance, then immediately execute.
        // Cancel any pending timer for this journey (we may advance earlier)
        activeTasks[journey.id]?.cancel()
        activeTasks.removeValue(forKey: journey.id)

        journey.resume()  // status -> active
        inMemoryJourneysById[journey.id] = journey

        // Pass the event-driven resume reason for this reactive re-evaluation
        let resumeReason: ResumeReason = event != nil ? .event(event!) : .segmentChange
        await executeJourney(journey, campaign: campaign, reason: resumeReason)
      }
    }
  }
}
