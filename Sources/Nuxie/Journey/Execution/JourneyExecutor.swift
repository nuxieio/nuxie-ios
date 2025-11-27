import FactoryKit
import Foundation

/// Protocol for journey execution
protocol JourneyExecutorProtocol {
  /// Execute the current node in a journey
  func executeNode(
    _ node: WorkflowNode,
    journey: Journey,
    resumeReason: ResumeReason
  ) async -> NodeExecutionResult

  /// Find node by ID in campaign workflow
  func findNode(id: String, in campaign: Campaign) -> WorkflowNode?

  /// Get next nodes to execute
  func getNextNodes(from result: NodeExecutionResult, in campaign: Campaign) -> [WorkflowNode]
}

private enum JourneyContextKeys {
  static let waitState = "_wait_state"  // Dictionary<String, Any> shape (see below)
}

/// Executes journey workflow nodes
public final class JourneyExecutor: JourneyExecutorProtocol {

  // MARK: - Dependencies

  @Injected(\.flowService) private var flowService: FlowServiceProtocol
  @Injected(\.flowPresentationService) private var flowPresentationService:
    FlowPresentationServiceProtocol
  @Injected(\.eventService) private var eventService: EventServiceProtocol
  @Injected(\.identityService) private var identityService: IdentityServiceProtocol
  @Injected(\.segmentService) private var segmentService: SegmentServiceProtocol
  @Injected(\.profileService) private var profileService: ProfileServiceProtocol
  @Injected(\.dateProvider) private var dateProvider: DateProviderProtocol
  @Injected(\.irRuntime) private var irRuntime: IRRuntime
  @Injected(\.outcomeBroker) private var outcomeBroker: OutcomeBrokerProtocol

  // MARK: - Initialization

  public init() {
    LogInfo("JourneyExecutor initialized")
  }

  // MARK: - Public Methods

  /// Execute a node in the journey
  public func executeNode(
    _ node: WorkflowNode,
    journey: Journey,
    resumeReason: ResumeReason
  ) async -> NodeExecutionResult {
    LogDebug("Executing node \(node.id) of type \(node.type) for journey \(journey.id)")

    // Execute based on node type
    do {
      let result = try await executeNodeCore(node, journey: journey, resumeReason: resumeReason)
      LogDebug("Node \(node.id) execution result: \(result)")

      // Track node execution event for observability
      eventService.track(
        JourneyEvents.nodeExecuted,
        properties: JourneyEvents.nodeExecutedProperties(
          journey: journey,
          node: node,
          result: result
        ),
        userProperties: nil,
        userPropertiesSetOnce: nil,
        completion: nil
      )

      return result
    } catch {
      LogError("Node \(node.id) execution failed: \(error)")
      let errorResult = handleNodeError(node, error: error)

      // Track node error event for observability
      eventService.track(
        JourneyEvents.nodeErrored,
        properties: [
          "journey_id": journey.id,
          "campaign_id": journey.campaignId,
          "node_id": node.id,
          "node_type": node.type.rawValue,
          "error_message": error.localizedDescription,
        ],
        userProperties: nil,
        userPropertiesSetOnce: nil,
        completion: nil
      )

      return errorResult
    }
  }

  /// Find a node by ID in the campaign workflow
  public func findNode(id: String, in campaign: Campaign) -> WorkflowNode? {
    LogDebug(
      "[JourneyExecutor] findNode: looking for node \(id) in campaign with \(campaign.workflow.nodes.count) nodes"
    )
    for anyNode in campaign.workflow.nodes {
      LogDebug("[JourneyExecutor] findNode: checking node \(anyNode.node.id)")
      if anyNode.node.id == id {
        LogDebug("[JourneyExecutor] findNode: found node \(id) of type \(anyNode.node.type)")
        return anyNode.node
      }
    }
    LogDebug("[JourneyExecutor] findNode: node \(id) not found")
    return nil
  }

  /// Get next nodes to execute based on result
  public func getNextNodes(from result: NodeExecutionResult, in campaign: Campaign)
    -> [WorkflowNode]
  {
    switch result {
    case .continue(let nodeIds):
      return nodeIds.compactMap { findNode(id: $0, in: campaign) }

    case .skip(let nodeId):
      if let nodeId = nodeId {
        return [findNode(id: nodeId, in: campaign)].compactMap { $0 }
      }
      return []

    case .async, .complete:
      return []
    }
  }

  // MARK: - Private Methods

  private func executeNodeCore(
    _ node: WorkflowNode,
    journey: Journey,
    resumeReason: ResumeReason
  ) async throws
    -> NodeExecutionResult
  {
    switch node.type {
    case .showFlow:
      return try await executeShowFlow(node, journey: journey)

    case .timeDelay:
      return executeTimeDelay(node, journey: journey)

    case .exit:
      return executeExit(node, journey: journey)

    case .branch:
      return await executeBranch(node, journey: journey)

    case .multiBranch:
      return await executeMultiBranch(node, journey: journey)

    case .updateCustomer:
      return executeUpdateCustomer(node, journey: journey)

    case .sendEvent:
      return executeSendEvent(node, journey: journey)

    case .timeWindow:
      return executeTimeWindow(node, journey: journey)

    case .waitUntil:
      return await executeWaitUntil(node, journey: journey, resumeReason: resumeReason)

    case .randomBranch:
      return executeRandomBranch(node, journey: journey)

    case .callDelegate:
      return executeCallDelegate(node, journey: journey)

    default:
      LogWarning("Unsupported node type: \(node.type)")
      return .skip(node.next.first)
    }
  }

  // MARK: - Node Executors

  private func executeShowFlow(_ node: WorkflowNode, journey: Journey) async throws
    -> NodeExecutionResult
  {
    LogDebug("[JourneyExecutor] executeShowFlow called for node \(node.id)")
    guard let showFlowNode = node as? ShowFlowNode else {
      LogDebug("[JourneyExecutor] ERROR: Node is not a ShowFlowNode!")
      throw JourneyError.invalidNodeType
    }

    let flowId: String
    var experimentContext: (experimentId: String, variantId: String)? = nil

    // Check for experiment mode (A/B testing)
    if let experiment = showFlowNode.data.experiment {
      // Resolve variant: server assignment first, fallback to local hash
      let variant = await resolveExperimentVariant(
        distinctId: journey.distinctId,
        experiment: experiment
      )
      flowId = variant.flowId
      experimentContext = (experiment.id, variant.id)

      LogInfo(
        "Experiment '\(experiment.name ?? experiment.id)': assigned variant '\(variant.name ?? variant.id)' to user \(journey.distinctId)"
      )

      // Track experiment assignment event
      eventService.track(
        JourneyEvents.experimentVariantAssigned,
        properties: JourneyEvents.experimentVariantAssignedProperties(
          journey: journey,
          nodeId: node.id,
          experiment: experiment,
          variant: variant
        ),
        userProperties: nil,
        userPropertiesSetOnce: nil,
        completion: nil
      )

      // Store experiment context in journey for attribution on downstream events
      journey.setContext("_experiment_id", value: experiment.id)
      journey.setContext("_variant_id", value: variant.id)
    } else if let singleFlowId = showFlowNode.data.flowId {
      // Single flow mode (existing behavior)
      flowId = singleFlowId
    } else {
      LogError("ShowFlowNode has neither flowId nor experiment configured")
      return .skip(node.next.first)
    }

    LogInfo("Showing flow \(flowId) for journey \(journey.id)")
    LogDebug("[JourneyExecutor] ShowFlow node \(node.id): flowId=\(flowId), next=\(node.next)")

    // Bind the journey/flow to the originating event for outcome tracking
    if let originEventId = journey.getContext("_origin_event_id") as? String {
      await outcomeBroker.bind(eventId: originEventId, journeyId: journey.id, flowId: flowId)
    }

    // Present flow using FlowPresentationService (fire-and-forget)
    Task { @MainActor [weak self] in
      guard let self = self else { return }
      do {
        try await self.flowPresentationService.presentFlow(flowId, from: journey)
        LogInfo("Successfully presented flow \(flowId) for journey \(journey.id)")
      } catch {
        LogError("Failed to present flow \(flowId): \(error)")
      }
    }

    // Track flow shown event for observability (with experiment context if present)
    var flowShownProps = JourneyEvents.flowShownProperties(
      journey: journey,
      nodeId: node.id,
      flowId: flowId
    )
    if let expCtx = experimentContext {
      flowShownProps["experiment_id"] = expCtx.experimentId
      flowShownProps["variant_id"] = expCtx.variantId
    }
    eventService.track(
      JourneyEvents.flowShown,
      properties: flowShownProps,
      userProperties: nil,
      userPropertiesSetOnce: nil,
      completion: nil
    )

    // Continue to next node immediately (fire-and-forget pattern)
    LogDebug("[JourneyExecutor] ShowFlow returning continue to nodes: \(node.next)")
    return .continue(node.next)
  }

  // MARK: - Experiment Helpers

  /// Resolve experiment variant: server assignment first, fallback to local hash
  /// Server is source of truth; local hash used for offline/cache scenarios
  private func resolveExperimentVariant(
    distinctId: String,
    experiment: ExperimentConfig
  ) async -> ExperimentVariant {
    // Try server assignment first (from cached profile)
    if let assignment = await getServerAssignment(
      distinctId: distinctId,
      experimentId: experiment.id
    ) {
      // Find the variant matching the server's assignment
      if let variant = experiment.variants.first(where: { $0.id == assignment.variantId }) {
        LogDebug("Using server-assigned variant '\(variant.id)' for experiment '\(experiment.id)'")
        return variant
      }
      LogWarning("Server assigned variant '\(assignment.variantId)' not found in experiment config, falling back to local hash")
    }

    // Fallback to local deterministic hash (for offline/old cache)
    LogDebug("Using local hash for experiment '\(experiment.id)' (no server assignment)")
    return computeVariantLocally(distinctId: distinctId, experiment: experiment)
  }

  /// Get server-computed experiment assignment from cached profile
  private func getServerAssignment(
    distinctId: String,
    experimentId: String
  ) async -> ExperimentAssignment? {
    guard let profile = await profileService.getCachedProfile(distinctId: distinctId) else {
      return nil
    }
    return profile.experimentAssignments?[experimentId]
  }

  /// Compute variant locally using deterministic FNV-1a hash
  /// Used as fallback when server assignment isn't available
  private func computeVariantLocally(
    distinctId: String,
    experiment: ExperimentConfig
  ) -> ExperimentVariant {
    let seed = "\(distinctId):\(experiment.id)"
    let bucket = stableHash(seed) % 100

    var cumulative: Double = 0
    for variant in experiment.variants {
      cumulative += variant.percentage
      if Double(bucket) < cumulative {
        return variant
      }
    }

    // Fallback to first variant (shouldn't happen if percentages sum to 100)
    return experiment.variants[0]
  }

  /// Deterministic hash function (FNV-1a)
  /// Produces consistent results across sessions for the same input
  private func stableHash(_ input: String) -> Int {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in input.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return Int(hash & 0x7FFF_FFFF_FFFF_FFFF)
  }

  private func executeTimeDelay(_ node: WorkflowNode, journey: Journey) -> NodeExecutionResult {
    guard let delayNode = node as? TimeDelayNode else { return .skip(node.next.first) }
    let duration = delayNode.data.duration
    if duration <= 0 {
      LogInfo("Journey \(journey.id) timeDelay <= 0s, continuing immediately")
      return .continue(node.next)
    }
    let resumeAt = dateProvider.date(byAddingTimeInterval: duration, to: dateProvider.now())
    LogInfo("Journey \(journey.id) entering delay until \(resumeAt) (\(Int(duration))s)")
    return .async(resumeAt)
  }

  private func executeExit(_ node: WorkflowNode, journey: Journey) -> NodeExecutionResult {
    let exitNode = node as? ExitNode
    let reason = exitNode?.data?.reason ?? "completed"

    LogInfo("Journey \(journey.id) exiting: \(reason)")

    // Map reason string to exit reason enum
    let exitReason: JourneyExitReason = {
      switch reason {
      case "goal_met": return .goalMet
      case "expired": return .expired
      case "error": return .error
      default: return .completed
      }
    }()

    return .complete(exitReason)
  }

  // MARK: - Phase 2 Node Executors

  private func executeBranch(_ node: WorkflowNode, journey: Journey) async -> NodeExecutionResult {
    guard let branchNode = node as? BranchNode else {
      return .skip(node.next.first)
    }

    let condition = branchNode.data.condition
    LogInfo("Evaluating branch condition")

    let result = await evalConditionIR(condition, journey: journey)
    // Use next[0] for true path, next[1] for false path
    guard branchNode.next.count >= 2 else {
      LogError("Branch node \(node.id) missing required paths")
      return .complete(.error)
    }
    let nextNodeId = result ? branchNode.next[0] : branchNode.next[1]

    LogInfo("Branch condition evaluated to \(result), taking path to node: \(nextNodeId)")

    // Track branch decision for observability
    eventService.track(
      JourneyEvents.nodeBranchTaken,
      properties: JourneyEvents.branchTakenProperties(
        journey: journey,
        nodeId: node.id,
        branchPath: result ? "true" : "false",
        conditionResult: result
      ),
      userProperties: nil,
      userPropertiesSetOnce: nil,
      completion: nil
    )
    return .continue([nextNodeId])
  }

  private func executeMultiBranch(_ node: WorkflowNode, journey: Journey) async
    -> NodeExecutionResult
  {
    guard let branchNode = node as? MultiBranchNode else {
      return .skip(node.next.first)
    }

    LogInfo("Evaluating multi-branch with \(branchNode.data.conditions.count) conditions")
    
    // Validate configuration and log warning if paths don't match expected count
    let expectedPathCount = branchNode.data.conditions.count + 1  // conditions + default
    if branchNode.next.count < expectedPathCount {
      LogWarning("Multi-branch node \(node.id) has \(branchNode.next.count) paths but \(expectedPathCount) expected (including default).")
    }

    // Evaluate conditions in order
    for (index, condition) in branchNode.data.conditions.enumerated() {
      if await evalConditionIR(condition, journey: journey) {
        guard index < branchNode.next.count else {
          LogError("Multi-branch node missing path for condition \(index)")
          break
        }
        let nextNodeId = branchNode.next[index]
        LogInfo("Multi-split condition \(index) matched, taking path to node: \(nextNodeId)")

        // Track branch taken for observability
        eventService.track(
          JourneyEvents.nodeBranchTaken,
          properties: JourneyEvents.branchTakenProperties(
            journey: journey,
            nodeId: node.id,
            branchPath: "condition_\(index)",
            conditionResult: true
          ),
          userProperties: nil,
          userPropertiesSetOnce: nil,
          completion: nil
        )

        return .continue([nextNodeId])
      }
    }

    // No branches matched. Use default path = LAST element, if present.
    let hasDefault = branchNode.next.count > branchNode.data.conditions.count
    if hasDefault, let defaultNodeId = branchNode.next.last {
      LogInfo("No branches matched, taking default path to node: \(defaultNodeId)")

      // Track default branch taken
      eventService.track(
        JourneyEvents.nodeBranchTaken,
        properties: JourneyEvents.branchTakenProperties(
          journey: journey,
          nodeId: node.id,
          branchPath: "default",
          conditionResult: false
        ),
        userProperties: nil,
        userPropertiesSetOnce: nil,
        completion: nil
      )

      return .continue([defaultNodeId])
    }

    LogWarning("Multi-split branch has no matching branches and no default path (node \(node.id))")
    return .complete(.completed)
  }

  private func executeUpdateCustomer(_ node: WorkflowNode, journey: Journey) -> NodeExecutionResult
  {
    guard let updateNode = node as? UpdateCustomerNode else {
      return .skip(node.next.first)
    }

    LogInfo("Updating customer attributes for user \(journey.distinctId)")

    // Convert AnyCodable to regular dictionary
    var attributes: [String: Any] = [:]
    for (key, value) in updateNode.data.attributes {
      attributes[key] = value.value
    }

    // Update user properties via identity service
    identityService.setUserProperties(attributes)

    // Track customer update event for observability
    eventService.track(
      JourneyEvents.customerUpdated,
      properties: JourneyEvents.customerUpdatedProperties(
        journey: journey,
        nodeId: node.id,
        attributesUpdated: Array(attributes.keys)
      ),
      userProperties: nil,
      userPropertiesSetOnce: nil,
      completion: nil
    )

    LogInfo("Updated \(attributes.count) attributes for user \(journey.distinctId)")
    return .continue(node.next)
  }

  private func executeSendEvent(_ node: WorkflowNode, journey: Journey) -> NodeExecutionResult {
    guard let eventNode = node as? SendEventNode else {
      return .skip(node.next.first)
    }

    LogInfo("Sending event '\(eventNode.data.eventName)' from journey \(journey.id)")

    // Create event with properties
    var properties: [String: Any] = [:]
    if let eventProperties = eventNode.data.properties {
      for (key, value) in eventProperties {
        properties[key] = value.value
      }
    }

    // Add journey context to event
    properties["journeyId"] = journey.id
    properties["campaignId"] = journey.campaignId
    properties["nodeId"] = node.id

    // Create and route event
    eventService.track(
      eventNode.data.eventName,
      properties: properties,
      userProperties: nil,
      userPropertiesSetOnce: nil,
      completion: nil
    )

    // Track event sent for observability
    eventService.track(
      JourneyEvents.eventSent,
      properties: JourneyEvents.eventSentProperties(
        journey: journey,
        nodeId: node.id,
        eventName: eventNode.data.eventName,
        eventProperties: properties
      ),
      userProperties: nil,
      userPropertiesSetOnce: nil,
      completion: nil
    )

    LogInfo("Sent event '\(eventNode.data.eventName)' with \(properties.count) properties")
    return .continue(node.next)
  }

  // MARK: - Phase 3 Node Executors (Advanced Timing)

  private func executeTimeWindow(_ node: WorkflowNode, journey: Journey) -> NodeExecutionResult {
    guard let windowNode = node as? TimeWindowNode else { return .skip(node.next.first) }

    let data = windowNode.data
    LogInfo("Evaluating time window for journey \(journey.id)")

    let now = dateProvider.now()
    let tz = data.useUTC ? TimeZone(identifier: "UTC")! : TimeZone.current
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz

    // 1) Extract start/end H:M in the correct timezone
    let startHM = cal.dateComponents([.hour, .minute], from: data.startTime)
    let endHM = cal.dateComponents([.hour, .minute], from: data.endTime)

    guard let sh = startHM.hour, let sm = startHM.minute,
      let eh = endHM.hour, let em = endHM.minute
    else {
      LogError("Invalid time window times")
      return .skip(node.next.first)
    }

    // 2) Day-of-week filter (in tz)
    // iOS Calendar weekday: 1=Sunday, 2=Monday, ..., 7=Saturday
    let weekday = cal.component(.weekday, from: now)
    if let days = data.daysOfWeek, !days.isEmpty, !days.contains(weekday) {
      let nextValidDay = calculateNextValidDay(from: now, validDays: days, timezone: tz)
      LogInfo("Not a valid day; waiting until start of next valid day: \(nextValidDay)")
      return .async(nextValidDay)
    }

    // 3) In-window check (in tz)
    let currentHM = cal.dateComponents([.hour, .minute], from: now)
    let curMin = (currentHM.hour ?? 0) * 60 + (currentHM.minute ?? 0)
    let startMin = sh * 60 + sm
    let endMin = eh * 60 + em

    // Treat start == end as always-open (optional; xit test depends on this)
    if startMin == endMin {
      LogInfo("Window start == end; treating as always open")
      return .continue(node.next)
    }

    let inWindow =
      (startMin <= endMin)
      ? (curMin >= startMin && curMin < endMin)
      : (curMin >= startMin || curMin < endMin)  // overnight

    if inWindow {
      LogInfo("Within time window; continuing")
      return .continue(node.next)
    }

    // 4) Next open (in tz)
    let nextOpen = calculateNextWindowOpen(
      from: now, startTime: data.startTime, timezone: tz, validDays: data.daysOfWeek)
    LogInfo("Outside window; waiting for next open at \(nextOpen)")
    return .async(nextOpen)
  }

  private func executeWaitUntil(
    _ node: WorkflowNode,
    journey: Journey,
    resumeReason: ResumeReason
  ) async -> NodeExecutionResult {
    guard let waitNode = node as? WaitUntilNode else { return .skip(node.next.first) }
    let now = dateProvider.now()
    LogInfo("Evaluating wait until (\(waitNode.data.paths.count) paths) for journey \(journey.id)")
    
    // Extract reactive event from resume reason if present
    let reactiveEvent: NuxieEvent? = {
      if case .event(let event) = resumeReason {
        return event
      }
      return nil
    }()

    // 1) Load/Create wait state
    var waitState = loadWaitState(for: journey, nodeId: waitNode.id)
    if waitState == nil {
      waitState = buildInitialWaitState(for: waitNode, now: now)
      saveWaitState(waitState!, into: journey)
    }

    // Helper to compute wait duration
    func waitDurationSeconds(_ now: Date) -> Int {
      guard let started = waitState?["startedAt"] as? Double else { return 0 }
      return Int(now.timeIntervalSince(Date(timeIntervalSince1970: started)))
    }

    // 2) Immediate (non-timeout) conditions left->right
    for path in waitNode.data.paths where path.maxTime == nil {
      if await evalConditionIR(path.condition, journey: journey, event: reactiveEvent) {
        LogInfo("WaitUntil condition met immediately for path \(path.id)")
        // Track, clear state, and continue
        eventService.track(
          JourneyEvents.nodeWaitCompleted,
          properties: JourneyEvents.waitCompletedProperties(
            journey: journey,
            nodeId: waitNode.id,
            matchedPath: path.id,
            waitDurationSeconds: TimeInterval(waitDurationSeconds(now))
          ),
          userProperties: nil,
          userPropertiesSetOnce: nil,
          completion: nil
        )
        clearWaitState(in: journey)
        return .continue([path.next])
      }
    }

    // 3) Check matured timeouts (only on timer/start resumes, not reactive)
    if !resumeReason.isReactive {
      if let (path, maturedAt) = earliestMaturedTimeout(
        waitNode: waitNode, waitState: waitState!, now: now)
      {
        LogInfo("WaitUntil timeout matured for path \(path.id) at \(maturedAt)")
        eventService.track(
          JourneyEvents.nodeWaitCompleted,
          properties: JourneyEvents.waitCompletedProperties(
            journey: journey,
            nodeId: waitNode.id,
            matchedPath: path.id,
            waitDurationSeconds: TimeInterval(waitDurationSeconds(now))
          ),
          userProperties: nil,
          userPropertiesSetOnce: nil,
          completion: nil
        )
        clearWaitState(in: journey)
        return .continue([path.next])
      }
    } else {
      LogInfo("WaitUntil skipping timeout evaluation on reactive resume (reason: \(resumeReason))")
    }

    // 4) Not ready: (re)schedule next earliest timeout if any, else indefinite wait
    let nextResume = nextUnmaturedDeadline(waitState: waitState!, now: now)
    
    // Clamp reschedule on reactive resumes to avoid immediate re-entry
    let effectiveResume: Date? = {
      if resumeReason.isReactive, let deadline = nextResume, deadline <= now {
        return now.addingTimeInterval(0.5)
      }
      return nextResume
    }()
    
    LogInfo("WaitUntil continuing to wait; next deadline = \(String(describing: effectiveResume))")
    return .async(effectiveResume)
  }

  // MARK: - Phase 4 Node Executors (Testing & Experimentation)

  private func executeRandomBranch(_ node: WorkflowNode, journey: Journey) -> NodeExecutionResult {
    guard let randomNode = node as? RandomBranchNode else {
      return .skip(node.next.first)
    }

    LogInfo(
      "Executing random branch with \(randomNode.data.branches.count) branches for journey \(journey.id)"
    )

    // Generate random value
    let random = Double.random(in: 0..<100)
    var cumulative: Double = 0

    // Find matching branch
    for (index, branch) in randomNode.data.branches.enumerated() {
      cumulative += branch.percentage
      if random < cumulative {
        let cohortName = branch.name ?? "Branch \(branch.percentage)%"
        LogInfo(
          "Journey \(journey.id) assigned to cohort '\(cohortName)' (random: \(random), threshold: \(cumulative))"
        )

        // Track random branch assignment for observability
        eventService.track(
          JourneyEvents.nodeRandomBranchAssigned,
          properties: JourneyEvents.randomBranchAssignedProperties(
            journey: journey,
            nodeId: node.id,
            cohortName: cohortName,
            cohortValue: random
          ),
          userProperties: nil,
          userPropertiesSetOnce: nil,
          completion: nil
        )

        guard index < randomNode.next.count else {
          LogError("Random branch node missing path for branch \(index)")
          return .continue(node.next)
        }

        return .continue([randomNode.next[index]])
      }
    }

    // Fallback to default path if percentages don't add up to 100
    LogWarning("Random branch percentages don't add up properly, using default path")
    return .continue(node.next)
  }

  private func executeCallDelegate(_ node: WorkflowNode, journey: Journey) -> NodeExecutionResult {
    guard let delegateNode = node as? CallDelegateNode else {
      return .skip(node.next.first)
    }

    LogInfo(
      "Calling delegate with message '\(delegateNode.data.message)' for journey \(journey.id)")

    // Post notification that the app can observe
    var userInfo: [String: Any] = [
      "message": delegateNode.data.message,
      "journeyId": journey.id,
      "campaignId": journey.campaignId,
      "nodeId": node.id,
    ]

    if let payload = delegateNode.data.payload {
      userInfo["payload"] = payload.value
    }

    NotificationCenter.default.post(
      name: .nuxieCallDelegate,
      object: nil,
      userInfo: userInfo
    )

    // Track delegate call for observability
    eventService.track(
      JourneyEvents.delegateCalled,
      properties: JourneyEvents.delegateCalledProperties(
        journey: journey,
        nodeId: node.id,
        message: delegateNode.data.message,
        payload: delegateNode.data.payload?.value
      ),
      userProperties: nil,
      userPropertiesSetOnce: nil,
      completion: nil
    )

    LogInfo("Delegate called with message '\(delegateNode.data.message)'")
    return .continue(node.next)
  }

  // MARK: - Helper Methods

  private func parseTime(_ timeString: String) -> DateComponents? {
    let parts = timeString.split(separator: ":")
    guard parts.count == 2,
      let hour = Int(parts[0]),
      let minute = Int(parts[1])
    else {
      return nil
    }

    var components = DateComponents()
    components.hour = hour
    components.minute = minute
    return components
  }

  private func calculateNextValidDay(from date: Date, validDays: [Int], timezone: TimeZone) -> Date
  {
    // Use a calendar pinned to the provided timezone for all computations.
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timezone

    // Find next valid day (1=Sun ... 7=Sat)
    for i in 1...7 {
      guard let nextDate = cal.date(byAdding: .day, value: i, to: date) else { continue }
      let weekday = cal.component(.weekday, from: nextDate)
      if validDays.contains(weekday) {
        // Start of that valid day in tz
        var comps = cal.dateComponents([.year, .month, .day], from: nextDate)
        comps.hour = 0
        comps.minute = 0
        comps.second = 0
        comps.timeZone = timezone
        return cal.date(from: comps) ?? nextDate
      }
    }

    // Fallback: return the given date (should not happen)
    return date
  }

  private func calculateNextWindowOpen(
    from date: Date, startTime: Date, timezone: TimeZone, validDays: [Int]?
  ) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timezone

    // Extract H:M of the configured start in the correct tz
    let startHM = cal.dateComponents([.hour, .minute], from: startTime)
    guard let sh = startHM.hour, let sm = startHM.minute else { return date }

    // Build "today at sh:sm" in tz
    var today = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    today.hour = sh
    today.minute = sm
    today.second = 0
    today.timeZone = timezone

    var nextOpen = cal.date(from: today) ?? date

    // If already past today's start, roll to tomorrow
    if nextOpen <= date {
      nextOpen = cal.date(byAdding: .day, value: 1, to: nextOpen) ?? nextOpen
    }

    // Honor valid days, if provided
    // validDays uses iOS weekday format: 1=Sunday, 2=Monday, ..., 7=Saturday
    if let days = validDays, !days.isEmpty {
      while true {
        let wd = cal.component(.weekday, from: nextOpen)
        if days.contains(wd) { break }
        nextOpen = cal.date(byAdding: .day, value: 1, to: nextOpen) ?? nextOpen
      }
    }

    return nextOpen
  }

  // MARK: - WaitState helpers

  private func buildInitialWaitState(for waitNode: WaitUntilNode, now: Date) -> [String: Any] {
    var deadlines: [String: Double?] = [:]
    for path in waitNode.data.paths {
      if let max = path.maxTime {  // seconds
        let at = dateProvider.date(byAddingTimeInterval: max, to: now)
        deadlines[path.id] = at.timeIntervalSince1970
      } else {
        deadlines[path.id] = nil
      }
    }
    return [
      "nodeId": waitNode.id,
      "startedAt": now.timeIntervalSince1970,
      "deadlines": deadlines,
    ]
  }

  private func loadWaitState(for journey: Journey, nodeId: String) -> [String: Any]? {
    guard let raw = journey.context[JourneyContextKeys.waitState]?.value as? [String: Any],
      (raw["nodeId"] as? String) == nodeId
    else { return nil }
    return raw
  }

  private func saveWaitState(_ state: [String: Any], into journey: Journey) {
    journey.setContext(JourneyContextKeys.waitState, value: state)
  }

  private func clearWaitState(in journey: Journey) {
    journey.context.removeValue(forKey: JourneyContextKeys.waitState)
  }

  /// Returns earliest matured timeout path (if any)
  private func earliestMaturedTimeout(waitNode: WaitUntilNode, waitState: [String: Any], now: Date)
    -> (WaitUntilNode.WaitUntilData.WaitPath, Date)?
  {
    guard let deadlines = waitState["deadlines"] as? [String: Any] else { return nil }
    var candidate: (path: WaitUntilNode.WaitUntilData.WaitPath, at: Date)?
    for path in waitNode.data.paths {
      guard let ts = deadlines[path.id] as? Double else { continue }  // skip non-timeout paths (nil in saved map)
      let at = Date(timeIntervalSince1970: ts)
      if now >= at {
        if candidate == nil || at < candidate!.at {
          candidate = (path, at)
        }
      }
    }
    return candidate
  }

  /// Next not-yet-matured timeout (absolute) used to schedule resume; nil means indefinite.
  private func nextUnmaturedDeadline(waitState: [String: Any], now: Date) -> Date? {
    guard let deadlines = waitState["deadlines"] as? [String: Any] else { return nil }
    var minFuture: Date?
    for (_, anyTs) in deadlines {
      guard let ts = anyTs as? Double else { continue }  // skip non-timeout paths
      let at = Date(timeIntervalSince1970: ts)
      if at > now {
        if minFuture == nil || at < minFuture! {
          minFuture = at
        }
      }
    }
    return minFuture
  }

  // MARK: - Condition Evaluation

  private func evalConditionIR(
    _ envelope: IREnvelope?, journey: Journey? = nil, event: NuxieEvent? = nil
  ) async -> Bool {
    // No condition means always true
    guard let envelope = envelope else { return true }
    
    // Create adapters for the services
    let userAdapter = IRUserPropsAdapter(identityService: identityService)
    let eventsAdapter = IREventQueriesAdapter(eventService: eventService)
    let segmentsAdapter = IRSegmentQueriesAdapter(segmentService: segmentService)
    
    let config = IRRuntime.Config(
      event: event,
      user: userAdapter,
      events: eventsAdapter,
      segments: segmentsAdapter
    )
    
    return await irRuntime.eval(envelope, config)
  }

  // MARK: - Error Handling

  private func handleNodeError(_ node: WorkflowNode, error: Error) -> NodeExecutionResult {
    switch node.type {
    case .timeDelay, .waitUntil:
      // Critical timing nodes - must fail
      return .complete(.error)

    case .branch:
      // On error, take the false path (index 1)
      // Branch nodes should always have exactly 2 paths [true, false]
      if node.next.count >= 2 {
        return .continue([node.next[1]])
      }
      // This shouldn't happen - branch nodes must have 2 paths
      LogError("Branch node has invalid path count: \(node.next.count)")
      return .complete(.error)

    case .multiBranch:
      // On error, take the configured default path, which is the LAST element.
      if let defaultPath = node.next.last {
        return .continue([defaultPath])
      }
      return .complete(.error)

    default:
      // Everything else: skip and continue
      return .skip(node.next.first)
    }
  }
}

// MARK: - Supporting Types

enum JourneyError: LocalizedError {
  case invalidNodeType
  case nodeNotFound(String)
  case executionFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidNodeType:
      return "Invalid node type for operation"
    case .nodeNotFound(let id):
      return "Node not found: \(id)"
    case .executionFailed(let reason):
      return "Node execution failed: \(reason)"
    }
  }
}

// MARK: - Notifications

extension Notification.Name {
  /// Posted when a flow should be shown
  static let nuxieShowFlow = Notification.Name("com.nuxie.showFlow")

  /// Posted when a call delegate node is executed
  static let nuxieCallDelegate = Notification.Name("com.nuxie.callDelegate")
}
