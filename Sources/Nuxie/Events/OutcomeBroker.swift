import Foundation

/// Protocol for managing event outcome callbacks
public protocol OutcomeBrokerProtocol: AnyObject {
    /// Register a completion handler for an event
    func register(eventId: String, timeout: TimeInterval, completion: @escaping (EventResult) -> Void) async
    
    /// Bind an event to a journey and flow that was immediately triggered
    func bind(eventId: String, journeyId: String, flowId: String) async
    
    /// Observe events to detect flow completions
    func observe(event: NuxieEvent) async
}

/// Manages the connection between tracked events and their immediate flow outcomes
public actor OutcomeBroker: OutcomeBrokerProtocol {
    
    private struct PendingOutcome {
        let completion: (EventResult) -> Void
        var bound: (journeyId: String, flowId: String)?
        var timeoutTask: Task<Void, Never>?
    }
    
    /// Pending outcomes by event ID
    private var pendingByEventId: [String: PendingOutcome] = [:]
    
    /// Mapping from journey ID to the originating event ID
    private var journeyToEventId: [String: String] = [:]
    
    public init() {
        LogDebug("OutcomeBroker initialized")
    }
    
    /// Register a completion handler for an event with a timeout
    public func register(eventId: String, timeout: TimeInterval, completion: @escaping (EventResult) -> Void) {
        // Skip if already registered
        guard pendingByEventId[eventId] == nil else {
            LogWarning("Event \(eventId) already has a registered completion handler")
            return
        }
        
        LogDebug("Registering outcome handler for event \(eventId) with timeout \(timeout)s")
        
        var pending = PendingOutcome(completion: completion, bound: nil, timeoutTask: nil)
        
        // Set up timeout if specified
        if timeout > 0 {
            pending.timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    await self?.handleTimeout(eventId: eventId)
                } catch {
                    // Task was cancelled, which is expected
                    LogDebug("Timeout task cancelled for event \(eventId)")
                }
            }
        }
        
        pendingByEventId[eventId] = pending
    }
    
    /// Bind an event to a journey and flow that was immediately triggered
    public func bind(eventId: String, journeyId: String, flowId: String) {
        guard var pending = pendingByEventId[eventId], pending.bound == nil else {
            LogDebug("Event \(eventId) not pending or already bound")
            return
        }
        
        LogInfo("Binding event \(eventId) to journey \(journeyId) and flow \(flowId)")
        
        // Cancel timeout since we have a bound flow
        pending.timeoutTask?.cancel()
        pending.timeoutTask = nil
        
        // Store binding
        pending.bound = (journeyId, flowId)
        pendingByEventId[eventId] = pending
        journeyToEventId[journeyId] = eventId
    }
    
    /// Observe events to detect flow completions
    public func observe(event: NuxieEvent) {
        // Check if this is a flow-ending event
        guard isFlowEndingEvent(event.name) else {
            return
        }

        let props = event.properties
        guard let journeyId = props["journey_id"] as? String,
              let flowId = props["flow_id"] as? String else {
            LogDebug("Flow event missing journey_id or flow_id")
            return
        }

        // Find the originating event ID
        guard let eventId = journeyToEventId[journeyId],
              let pending = pendingByEventId[eventId],
              let bound = pending.bound,
              bound.flowId == flowId else {
            LogDebug("No pending outcome for journey \(journeyId) flow \(flowId)")
            return
        }

        LogInfo("Flow \(flowId) ended for event \(eventId) with \(event.name)")

        // Map the outcome from event name and properties
        let outcome = mapOutcome(from: event.name, properties: props)

        // Call completion with flow result
        let flowCompletion = FlowCompletion(
            journeyId: journeyId,
            flowId: flowId,
            outcome: outcome
        )
        pending.completion(.flow(flowCompletion))

        // Clean up
        cleanup(eventId: eventId, journeyId: journeyId)
    }

    /// Check if an event name represents a flow ending
    private func isFlowEndingEvent(_ eventName: String) -> Bool {
        return eventName == JourneyEvents.flowDismissed ||
               eventName == JourneyEvents.flowPurchased ||
               eventName == JourneyEvents.flowTimedOut ||
               eventName == JourneyEvents.flowErrored
    }
    
    // MARK: - Private Methods
    
    private func handleTimeout(eventId: String) {
        guard let pending = pendingByEventId[eventId], pending.bound == nil else {
            // Either already handled or bound to a flow
            return
        }
        
        LogDebug("Event \(eventId) timed out without immediate flow")
        
        // Call completion with noInteraction result
        pending.completion(.noInteraction)
        
        // Clean up
        cleanup(eventId: eventId, journeyId: nil)
    }
    
    private func cleanup(eventId: String, journeyId: String?) {
        pendingByEventId.removeValue(forKey: eventId)
        if let journeyId = journeyId {
            journeyToEventId.removeValue(forKey: journeyId)
        }
    }
    
    private func mapOutcome(from eventName: String, properties: [String: Any]) -> FlowOutcome {
        switch eventName {
        case JourneyEvents.flowPurchased:
            return .purchased(
                productId: properties["product_id"] as? String,
                transactionId: properties["transaction_id"] as? String
            )

        case JourneyEvents.flowDismissed:
            return .dismissed

        case JourneyEvents.flowTimedOut:
            return .dismissed  // Treat timeout as dismissed

        case JourneyEvents.flowErrored:
            return .error(message: properties["error_message"] as? String)

        default:
            return .dismissed
        }
    }
}