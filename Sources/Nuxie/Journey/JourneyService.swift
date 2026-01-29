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

  /// Resume journeys from server state (for cross-device resume)
  /// Called after profile fetch to resume any journeys active on other devices
  func resumeFromServerState(_ journeys: [ActiveJourney], campaigns: [Campaign]) async

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
  @Injected(\.eventService) private var eventService: EventServiceProtocol
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

      // Schedule branch-level resumes
      for branch in journey.branches where branch.status == .paused {
        if let resumeAt = branch.resumeAt {
          scheduleBranchResume(journey: journey, branchId: branch.id, at: resumeAt)
        }
      }

      // Legacy fallback: journey-level resume
      if journey.status == .paused, let resumeAt = journey.resumeAt {
        scheduleResume(journey, at: resumeAt)
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

    // 2) Re-arm not-yet-matured branch timers
    let candidates = getAllLiveJourneys()
    var scheduled = 0
    let now = dateProvider.now()

    for journey in candidates {
      // Check each paused branch
      for branch in journey.branches where branch.status == .paused {
        if let resumeAt = branch.resumeAt, resumeAt > now {
          scheduleBranchResume(journey: journey, branchId: branch.id, at: resumeAt)
          scheduled += 1
        }
      }
      // Legacy fallback: journey-level timer
      if journey.status == .paused, let at = journey.resumeAt, at > now {
        scheduleResume(journey, at: at)
        scheduled += 1
      }
    }
    if scheduled > 0 { LogInfo("Re-armed \(scheduled) journey/branch timers") }
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

    // Send $journey_start to server for cross-device tracking (fire-and-forget)
    eventService.track(
      "$journey_start",
      properties: [
        "session_id": journey.id,
        "campaign_id": campaign.id,
        "campaign_version_id": campaign.versionId,
        "entry_node_id": campaign.entryNodeId as Any,
      ],
      userProperties: nil,
      userPropertiesSetOnce: nil,
      completion: nil
    )

    // Track local journey started event for telemetry
    eventService.track(
      JourneyEvents.journeyStarted,
      properties: JourneyEvents.journeyStartedProperties(
        journey: journey,
        campaign: campaign,
        triggerEvent: nil
      ),
      userProperties: nil,
      userPropertiesSetOnce: nil,
      completion: nil
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

    // Track journey resumed event
    eventService.track(
      JourneyEvents.journeyResumed,
      properties: JourneyEvents.journeyResumedProperties(
        journey: canonical,
        nodeId: canonical.currentNodeId,
        resumeReason: "timer"
      ),
      userProperties: nil,
      userPropertiesSetOnce: nil,
      completion: nil
    )

    // Continue execution (timer-based resume)
    await executeJourney(canonical, campaign: campaign, reason: .timer)
  }

  /// Resume journeys from server state (for cross-device resume)
  /// Called after profile fetch to resume any journeys active on other devices
  public func resumeFromServerState(_ journeys: [ActiveJourney], campaigns: [Campaign]) async {
    guard !journeys.isEmpty else { return }

    let distinctId = identityService.getDistinctId()
    LogInfo("[JourneyService] Resuming \(journeys.count) journeys from server state")

    for active in journeys {
      // Skip if we already have this journey locally (by ID)
      if inMemoryJourneysById[active.sessionId] != nil {
        LogDebug("[JourneyService] Journey \(active.sessionId) already exists locally, skipping")
        continue
      }

      // Find the campaign for this journey
      guard let campaign = campaigns.first(where: { $0.id == active.campaignId }) else {
        LogWarning("[JourneyService] Campaign \(active.campaignId) not found for server journey \(active.sessionId)")
        continue
      }

      // Create journey with the server's session ID as the journey ID
      let journey = Journey(id: active.sessionId, campaign: campaign, distinctId: distinctId)
      journey.currentNodeId = active.currentNodeId
      journey.status = .active

      // Restore context from server
      for (key, value) in active.context {
        journey.context[key] = value
      }

      // Register in memory
      inMemoryJourneysById[journey.id] = journey
      LogInfo("[JourneyService] Restored journey from server: id=\(journey.id), node=\(active.currentNodeId)")

      // Track cross-device resume event
      eventService.track(
        JourneyEvents.journeyResumed,
        properties: JourneyEvents.journeyResumedProperties(
          journey: journey,
          nodeId: active.currentNodeId,
          resumeReason: "cross_device"
        ),
        userProperties: nil,
        userPropertiesSetOnce: nil,
        completion: nil
      )

      // Continue execution from the current node
      await executeJourney(journey, campaign: campaign, reason: .start)
    }
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
    LogDebug("Checking for expired journey/branch timers...")

    // Iterate memory, not disk
    let candidates = Array(inMemoryJourneysById.values.filter { $0.status.isLive })
    var resumeCount = 0
    let now = dateProvider.now()

    for journey in candidates {
      // Check for branches with expired timers
      let expiredBranches = journey.branchesReadyToResume(at: now)
      if !expiredBranches.isEmpty {
        for branch in expiredBranches {
          await resumeBranch(journey: journey, branchId: branch.id)
          resumeCount += 1
        }
      } else if journey.status == .paused && journey.shouldResume(at: now) {
        // Legacy fallback: journey-level resume
        await resumeJourney(journey)
        resumeCount += 1
      }
    }

    if resumeCount > 0 {
      LogInfo("Resumed \(resumeCount) journeys/branches with expired timers")
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
      "[JourneyService] executeJourney starting with \(journey.branches.count) branches, \(journey.pendingBranchStarts.count) pending"
    )

    // Evaluate goal before starting
    await evaluateGoalIfNeeded(journey, campaign: campaign)

    // Check exit conditions before continuing
    if let exitReason = await exitDecision(journey, campaign) {
      LogDebug("[JourneyService] Journey should exit with reason: \(exitReason)")
      completeJourney(journey, reason: exitReason)
      return
    }

    // Execute branches concurrently: when one pauses, start the next
    while true {
      // Find the first running branch
      guard let branchIndex = journey.branches.firstIndex(where: { $0.status == .running }) else {
        // No running branches - try to start a pending branch
        if let newBranch = journey.startNextPendingBranch() {
          LogDebug("[JourneyService] Started pending branch \(newBranch.id) at node \(newBranch.currentNodeId ?? "nil")")
          inMemoryJourneysById[journey.id] = journey
          continue
        }
        // No running branches and no pending - check if all completed
        if journey.allBranchesCompleted() {
          LogDebug("[JourneyService] All branches completed - completing journey")
          completeJourney(journey, reason: .completed)
        } else {
          // Some branches still paused - journey is waiting
          LogDebug("[JourneyService] Journey has paused branches, waiting for resume")
          persistJourney(journey)
        }
        return
      }

      var branch = journey.branches[branchIndex]
      let branchResult = await executeBranch(
        &branch,
        journey: journey,
        campaign: campaign,
        reason: reason
      )
      journey.branches[branchIndex] = branch
      inMemoryJourneysById[journey.id] = journey

      switch branchResult {
      case .branchCompleted:
        // Branch finished naturally, continue to next branch
        LogDebug("[JourneyService] Branch \(branch.id) completed naturally")
        continue

      case .branchPaused:
        // Branch is waiting - try to start next pending branch
        LogDebug("[JourneyService] Branch \(branch.id) paused, checking for pending branches")
        continue

      case .journeyExited(let exitReason):
        // Exit node or error - end entire journey
        LogDebug("[JourneyService] Journey exiting with reason: \(exitReason)")
        completeJourney(journey, reason: exitReason)
        return
      }
    }
  }

  /// Result of executing a single branch
  private enum BranchExecutionResult {
    case branchCompleted      // Branch reached end (no more nodes)
    case branchPaused         // Branch is waiting (async node)
    case journeyExited(JourneyExitReason)  // Journey should end (exit node or error)
  }

  /// Execute a single branch until it pauses, completes, or exits
  private func executeBranch(
    _ branch: inout BranchState,
    journey: Journey,
    campaign: Campaign,
    reason: ResumeReason
  ) async -> BranchExecutionResult {
    var currentReason = reason
    var iterationCount = 0

    while let currentNodeId = branch.currentNodeId {
      iterationCount += 1
      LogDebug("[JourneyService] Branch \(branch.id) iteration \(iterationCount): node \(currentNodeId)")

      // Re-evaluate goal before each node
      await evaluateGoalIfNeeded(journey, campaign: campaign)

      // Check exit conditions
      if let exitReason = await exitDecision(journey, campaign) {
        return .journeyExited(exitReason)
      }

      // Find current node
      guard let node = journeyExecutor.findNode(id: currentNodeId, in: campaign) else {
        LogError("Node \(currentNodeId) not found in campaign \(campaign.id)")
        return .journeyExited(.error)
      }

      // Execute node
      let result = await journeyExecutor.executeNode(
        node,
        journey: journey,
        resumeReason: currentReason
      )
      currentReason = .start  // Only first node uses original reason
      LogDebug("[JourneyService] Node \(currentNodeId) result: \(result)")

      switch result {
      case .continue(let nextNodeIds):
        // Handle multiple outputs: first continues this branch, rest queued as new branches
        if nextNodeIds.count > 1 {
          let additionalPaths = Array(nextNodeIds.dropFirst())
          journey.queueBranchStarts(additionalPaths)
          LogDebug("[JourneyService] Queued \(additionalPaths.count) additional branch(es)")
        }
        branch.currentNodeId = nextNodeIds.first
        journey.updatedAt = dateProvider.now()

      case .skip(let skipToNodeId):
        branch.currentNodeId = skipToNodeId
        journey.updatedAt = dateProvider.now()

      case .async(let resumeAt):
        // Branch enters wait state
        branch.status = .paused
        branch.resumeAt = resumeAt
        journey.pauseBranch(withId: branch.id, until: resumeAt)
        LogDebug("[JourneyService] Branch \(branch.id) paused until \(String(describing: resumeAt))")

        // Track paused event
        eventService.track(
          JourneyEvents.journeyPaused,
          properties: JourneyEvents.journeyPausedProperties(
            journey: journey,
            nodeId: currentNodeId,
            resumeAt: resumeAt
          ),
          userProperties: nil,
          userPropertiesSetOnce: nil,
          completion: nil
        )

        // Schedule timer resume for this branch if there's a deadline
        if let resumeAt = resumeAt {
          scheduleBranchResume(journey: journey, branchId: branch.id, at: resumeAt)
        }

        return .branchPaused

      case .complete(let exitReason):
        // Exit node - end entire journey
        return .journeyExited(exitReason)
      }
    }

    // No more nodes in this branch - mark completed
    branch.status = .completed
    branch.currentNodeId = nil
    journey.completeBranch(withId: branch.id)
    LogDebug("[JourneyService] Branch \(branch.id) reached end")
    return .branchCompleted
  }

  private func completeJourney(_ journey: Journey, reason: JourneyExitReason) {
    LogInfo("Completing journey \(journey.id) with reason: \(reason)")

    journey.complete(reason: reason)

    // Calculate journey duration
    let duration = journey.completedAt?.timeIntervalSince(journey.startedAt) ?? dateProvider.now().timeIntervalSince(journey.startedAt)

    // Send $journey_completed to server for cross-device tracking (fire-and-forget)
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
      userPropertiesSetOnce: nil,
      completion: nil
    )

    // Track journey errored event if this is an error exit
    if reason == .error {
      eventService.track(
        JourneyEvents.journeyErrored,
        properties: JourneyEvents.journeyErroredProperties(
          journey: journey,
          nodeId: journey.currentNodeId,
          errorMessage: nil
        ),
        userProperties: nil,
        userPropertiesSetOnce: nil,
        completion: nil
      )
    }

    // Track journey exit event for observability
    eventService.track(
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
      // Block if there's already a live journey OR if user has completed this campaign before
      // The hasLive check prevents starting a second journey while one is in progress
      // The hasCompletedCampaign check prevents re-entry after completion
      if hasLive {
        return false
      }
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

  /// Schedule resume for a specific branch within a journey
  private func scheduleBranchResume(journey: Journey, branchId: String, at date: Date) {
    // Use a composite key for branch-specific tasks
    let taskKey = "\(journey.id):\(branchId)"

    // Cancel any existing task for this branch
    activeTasks[taskKey]?.cancel()

    let delay = max(0, date.timeIntervalSince(dateProvider.now()))
    let journeyId = journey.id

    let task = Task { [weak self] in
      do {
        try await self?.sleepProvider.sleep(for: delay)
        guard let self = self, !Task.isCancelled else { return }

        // Re-read canonical instance from registry
        if let journey = await self.inMemoryJourneysById[journeyId] {
          await self.resumeBranch(journey: journey, branchId: branchId)
        }
      } catch {
        LogDebug("Branch \(branchId) resume task cancelled/failed: \(error)")
      }
      await self?.clearTask(for: taskKey)
    }

    activeTasks[taskKey] = task
    LogDebug("Scheduled branch \(branchId) of journey \(journey.id) to resume at \(date)")
  }

  /// Resume a specific branch within a journey (timer-based)
  private func resumeBranch(journey: Journey, branchId: String) async {
    guard let branch = journey.branch(withId: branchId),
          branch.status == .paused else {
      LogDebug("Branch \(branchId) not found or not paused")
      return
    }

    LogInfo("Resuming branch \(branchId) of journey \(journey.id)")

    // Get campaign
    guard let campaign = await getCampaign(id: journey.campaignId, for: journey.distinctId) else {
      LogError("Campaign not found for journey \(journey.id)")
      return
    }

    // Resume the branch
    journey.resumeBranch(withId: branchId)
    inMemoryJourneysById[journey.id] = journey

    // Track resume event
    eventService.track(
      JourneyEvents.journeyResumed,
      properties: JourneyEvents.journeyResumedProperties(
        journey: journey,
        nodeId: branch.currentNodeId,
        resumeReason: "timer"
      ),
      userProperties: nil,
      userPropertiesSetOnce: nil,
      completion: nil
    )

    // Continue execution
    await executeJourney(journey, campaign: campaign, reason: .timer)
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

  /// Try to resume paused wait-until branches for a user due to a reactive trigger (event/segment change)
  private func tryReactiveResume(for distinctId: String, event: NuxieEvent? = nil) async {
    // Get all journeys that have paused branches (not just paused journey status)
    let journeysWithPausedBranches = await getActiveJourneys(for: distinctId).filter { journey in
      journey.branches.contains(where: { $0.status == .paused })
    }
    guard !journeysWithPausedBranches.isEmpty else { return }

    // Fetch campaigns for THIS user
    guard let campaigns = await getAllCampaigns(for: distinctId) else { return }

    for journey in journeysWithPausedBranches {
      guard let campaign = campaigns.first(where: { $0.id == journey.campaignId }) else {
        continue
      }

      // Check each paused branch
      var branchesToResume: [String] = []
      for branch in journey.branches where branch.status == .paused {
        guard let nodeId = branch.currentNodeId,
              let node = journeyExecutor.findNode(id: nodeId, in: campaign) else {
          continue
        }

        // Only wait-until reacts to events (time-window/delay self-resume by schedule)
        if node.type == .waitUntil {
          branchesToResume.append(branch.id)
        }
      }

      guard !branchesToResume.isEmpty else { continue }

      // Resume matching branches
      for branchId in branchesToResume {
        // Cancel any pending timer for this branch
        let taskKey = "\(journey.id):\(branchId)"
        activeTasks[taskKey]?.cancel()
        activeTasks.removeValue(forKey: taskKey)

        journey.resumeBranch(withId: branchId)
      }

      inMemoryJourneysById[journey.id] = journey

      // Pass the event-driven resume reason for this reactive re-evaluation
      let resumeReason: ResumeReason = event != nil ? .event(event!) : .segmentChange
      let resumeReasonString = event != nil ? "event" : "segment_change"

      // Track journey resumed event
      eventService.track(
        JourneyEvents.journeyResumed,
        properties: JourneyEvents.journeyResumedProperties(
          journey: journey,
          nodeId: branchesToResume.first.flatMap { journey.branch(withId: $0)?.currentNodeId },
          resumeReason: resumeReasonString
        ),
        userProperties: nil,
        userPropertiesSetOnce: nil,
        completion: nil
      )

      await executeJourney(journey, campaign: campaign, reason: resumeReason)
    }
  }
}
