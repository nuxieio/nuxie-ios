import FactoryKit
import Foundation

// MARK: - Goal Evaluator Protocol

/// Protocol for evaluating journey goals
public protocol GoalEvaluatorProtocol {
  /// Check if a journey's goal has been met
  /// - Parameters:
  ///   - journey: The journey to evaluate
  ///   - campaign: The campaign containing the workflow
  /// - Returns: Tuple of (met: whether goal was met, at: when it was met)
  func isGoalMet(journey: Journey, campaign: Campaign) async -> (met: Bool, at: Date?)
}

// MARK: - Goal Evaluator Implementation

/// Service for evaluating journey goals against user behavior
public actor GoalEvaluator: GoalEvaluatorProtocol {

  // MARK: - Dependencies

  @Injected(\.eventService) private var eventService: EventServiceProtocol
  @Injected(\.segmentService) private var segmentService: SegmentServiceProtocol
  @Injected(\.identityService) private var identityService: IdentityServiceProtocol
  @Injected(\.dateProvider) private var dateProvider: DateProviderProtocol
  @Injected(\.irRuntime) private var irRuntime: IRRuntime

  // MARK: - Initialization

  public init() {
    LogDebug(
      "GoalEvaluator deps: event=\(type(of: eventService)), id=\(type(of: identityService)), seg=\(type(of: segmentService))"
    )
  }

  // MARK: - Public Methods

  /// Check if a journey's goal has been met
  public func isGoalMet(journey: Journey, campaign: Campaign) async -> (met: Bool, at: Date?) {
    guard let goal = journey.goalSnapshot else {
      // No goal configured - never met
      return (false, nil)
    }

    let anchor = journey.conversionAnchorAt

    // Evaluate based on goal type
    switch goal.kind {
    case .event:
      return await evaluateEventGoal(goal, journey: journey, anchor: anchor)

    case .segmentEnter:
      return await evaluateSegmentEnterGoal(goal, journey: journey, anchor: anchor)

    case .segmentLeave:
      return await evaluateSegmentLeaveGoal(goal, journey: journey, anchor: anchor)

    case .attribute:
      return await evaluateAttributeGoal(goal, journey: journey, anchor: anchor)
    }
  }

  // MARK: - Private Methods

  private func evaluateEventGoal(_ goal: GoalConfig, journey: Journey, anchor: Date) async -> (
    met: Bool, at: Date?
  ) {
    guard let eventName = goal.eventName else {
      LogError("Event goal missing event name")
      return (false, nil)
    }

    LogDebug("[GoalEvaluator] Evaluating event goal '\(eventName)' for journey \(journey.id)")
    LogDebug("[GoalEvaluator] Journey anchor: \(anchor), window: \(journey.conversionWindow)")
    LogDebug("[GoalEvaluator] Journey.convertedAt: \(String(describing: journey.convertedAt))")

    // Event-time semantics:
    // - We only care whether the qualifying event's *timestamp* lies within the window.
    // - We do NOT reject just because "now" is past the window (late evaluation is OK).

    // If already latched by JourneyService, trust that.
    if let convertedAt = journey.convertedAt {
      LogDebug("[GoalEvaluator] Already converted at \(convertedAt), returning true")
      return (true, convertedAt)
    }

    // Calculate window boundaries
    let windowEnd = journey.conversionWindow > 0 
      ? anchor.addingTimeInterval(journey.conversionWindow) 
      : nil
    
    // Query for the last event within the window boundaries
    let lastEventTime = await eventService.getLastEventTime(
      name: eventName, 
      distinctId: journey.distinctId,
      since: anchor,
      until: windowEnd
    )
    
    LogDebug("[GoalEvaluator] Last event time for '\(eventName)' within window: \(String(describing: lastEventTime))")
    LogDebug("[GoalEvaluator] Window: anchor=\(anchor), end=\(String(describing: windowEnd))")

    guard let lastTime = lastEventTime else {
      LogDebug("[GoalEvaluator] No qualifying event found within window, returning false")
      return (false, nil)
    }

    // Phase 1: Skip event filter evaluation (will add in Phase 2)
    if goal.eventFilter != nil {
      LogDebug("Event filter evaluation not yet implemented - accepting any \(eventName) event")
    }

    LogDebug("[GoalEvaluator] Goal met! Returning true with time \(lastTime)")
    return (true, lastTime)
  }

  private func evaluateSegmentEnterGoal(_ goal: GoalConfig, journey: Journey, anchor: Date) async
    -> (met: Bool, at: Date?)
  {
    guard let segmentId = goal.segmentId else {
      LogError("Segment enter goal missing segment ID")
      return (false, nil)
    }

    // Check if we're within the conversion window for segment goals
    let now = dateProvider.now()
    if journey.conversionWindow > 0 {
      let windowEnd = anchor.addingTimeInterval(journey.conversionWindow)
      if now > windowEnd {
        LogDebug(
          "Segment enter goal evaluation outside conversion window for journey \(journey.id)")
        return (false, nil)
      }
    }

    let isMember = await segmentService.isInSegment(segmentId)

    if isMember {
      return (true, now)
    }

    return (false, nil)
  }

  private func evaluateSegmentLeaveGoal(_ goal: GoalConfig, journey: Journey, anchor: Date) async
    -> (met: Bool, at: Date?)
  {
    guard let segmentId = goal.segmentId else {
      LogError("Segment leave goal missing segment ID")
      return (false, nil)
    }

    // Check if we're within the conversion window for segment goals
    let now = dateProvider.now()
    if journey.conversionWindow > 0 {
      let windowEnd = anchor.addingTimeInterval(journey.conversionWindow)
      if now > windowEnd {
        LogDebug(
          "Segment leave goal evaluation outside conversion window for journey \(journey.id)")
        return (false, nil)
      }
    }

    let isMember = await segmentService.isInSegment(segmentId)

    if !isMember {
      return (true, now)
    }

    return (false, nil)
  }

  private func evaluateAttributeGoal(_ goal: GoalConfig, journey: Journey, anchor: Date) async -> (
    met: Bool, at: Date?
  ) {
    guard let attributeExpr = goal.attributeExpr else {
      LogError("Attribute goal missing expression")
      return (false, nil)
    }

    LogDebug("[GoalEvaluator] Evaluating attribute goal for journey \(journey.id)")
    LogDebug("[GoalEvaluator] Journey anchor: \(anchor), window: \(journey.conversionWindow)")

    // Check if we're within the conversion window for attribute goals
    let now = dateProvider.now()
    if journey.conversionWindow > 0 {
      let windowEnd = anchor.addingTimeInterval(journey.conversionWindow)
      LogDebug("[GoalEvaluator] Window end: \(windowEnd), now: \(now)")
      if now > windowEnd {
        LogDebug("[GoalEvaluator] Attribute goal evaluation outside conversion window")
        LogDebug("Attribute goal evaluation outside conversion window for journey \(journey.id)")
        return (false, nil)
      }
    }

    // Use centralized IR runtime for evaluation with adapters
    let userAdapter = IRUserPropsAdapter(identityService: identityService)
    let eventsAdapter = IREventQueriesAdapter(eventService: eventService)
    let segmentsAdapter = IRSegmentQueriesAdapter(segmentService: segmentService)

    let config = IRRuntime.Config(
      user: userAdapter,
      events: eventsAdapter,
      segments: segmentsAdapter
    )

    LogDebug("[GoalEvaluator] Evaluating IR expression: \(attributeExpr)")
    let result = await irRuntime.eval(attributeExpr, config)
    LogDebug("[GoalEvaluator] IR evaluation result: \(result)")
    
    if result {
      LogDebug("[GoalEvaluator] Attribute goal met! Returning true with time \(now)")
      return (true, now)
    }

    LogDebug("[GoalEvaluator] Attribute goal not met, returning false")
    return (false, nil)
  }
}
