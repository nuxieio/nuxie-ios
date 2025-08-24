import Foundation
@testable import Nuxie
import FactoryKit

/// Mock implementation of EventService for testing
public class MockEventService: EventServiceProtocol {
    public var routedEvents: [NuxieEvent] = []
    public var trackedEvents: [(name: String, properties: [String: Any]?)] = []
    public var eventHandlers: [(String, (NuxieEvent) -> Void)] = []
    
    // Test helper: track last event times
    private var lastEventTimes: [String: Date] = [:]
    
    // Primary protocol method - matches EventServiceProtocol
    public func trackAsync(
        _ event: String,
        properties: [String: Any]?,
        userProperties: [String: Any]?,
        userPropertiesSetOnce: [String: Any]?,
        completion: ((EventResult) -> Void)?
    ) async {
        // Track the event for test verification
        trackedEvents.append((name: event, properties: properties))
        
        // Create a simple NuxieEvent for mock purposes (without enrichment)
        let nuxieEvent = TestEventBuilder(name: event)
            .withDistinctId("test-distinct-id")
            .withProperties(properties ?? [:])
            .build()
        
        await route(nuxieEvent)
        completion?(.noInteraction)
    }
    
    // Convenience method for synchronous tracking (test helper)
    public func track(
        _ event: String,
        properties: [String: Any]? = nil,
        userProperties: [String: Any]? = nil,
        userPropertiesSetOnce: [String: Any]? = nil,
        completion: ((EventResult) -> Void)? = nil
    ) {
        Task {
            await trackAsync(
                event,
                properties: properties,
                userProperties: userProperties,
                userPropertiesSetOnce: userPropertiesSetOnce,
                completion: completion
            )
        }
    }
    
    @discardableResult
    public func route(_ event: NuxieEvent) async -> NuxieEvent? {
        routedEvents.append(event)
        
        // Notify handlers
        eventHandlers.forEach { (pattern, handler) in
            if pattern == event.name || pattern == "*" {
                handler(event)
            }
        }
        
        return event
    }
    
    public func routeBatch(_ events: [NuxieEvent]) async -> [NuxieEvent] {
        var routed: [NuxieEvent] = []
        for event in events {
            if let e = await route(event) {
                routed.append(e)
            }
        }
        return routed
    }
    
    public func configure(
        networkQueue: NuxieNetworkQueue?,
        journeyService: JourneyServiceProtocol?,
        contextBuilder: NuxieContextBuilder?,
        configuration: NuxieConfiguration?
    ) async throws {
        // Mock implementation - no-op
    }
    
    public func getRecentEvents(limit: Int) async -> [StoredEvent] {
        // Convert NuxieEvents to StoredEvents for mock
        return routedEvents.suffix(limit).compactMap { event in
            try? StoredEvent(
                id: UUID.v7().uuidString,
                name: event.name,
                properties: event.properties,
                timestamp: event.timestamp,
                distinctId: event.distinctId
            )
        }
    }
    
    public func getEventsForUser(_ distinctId: String, limit: Int) async -> [StoredEvent] {
        let userEvents = routedEvents.filter { $0.distinctId == distinctId }
        return userEvents.suffix(limit).compactMap { event in
            try? StoredEvent(
                id: UUID.v7().uuidString,
                name: event.name,
                properties: event.properties,
                timestamp: event.timestamp,
                distinctId: event.distinctId
            )
        }
    }
    
    public func getEvents(for sessionId: String) async -> [StoredEvent] {
        // Return all events for specified session (mock)
        return await getRecentEvents(limit: routedEvents.count)
    }
    
    public func hasEvent(name: String, distinctId: String, since: Date?) async -> Bool {
        let userEvents = routedEvents.filter { $0.distinctId == distinctId && $0.name == name }
        if let since = since {
            return userEvents.contains { $0.timestamp >= since }
        }
        return !userEvents.isEmpty
    }
    
    public func countEvents(name: String, distinctId: String, since: Date?, until: Date?) async -> Int {
        var userEvents = routedEvents.filter { $0.distinctId == distinctId && $0.name == name }
        if let since = since {
            userEvents = userEvents.filter { $0.timestamp >= since }
        }
        if let until = until {
            userEvents = userEvents.filter { $0.timestamp <= until }
        }
        return userEvents.count
    }
    
    public func getLastEventTime(name: String, distinctId: String, since: Date?, until: Date?) async -> Date? {
        let key = "\(distinctId):\(name)"
        LogDebug("[MockEventService] getLastEventTime called for event '\(name)', user '\(distinctId)'")
        LogDebug("[MockEventService] Current lastEventTimes dictionary: \(lastEventTimes)")
        LogDebug("[MockEventService] Bounds: since=\(String(describing: since)), until=\(String(describing: until))")
        
        // Check test helper dictionary first
        if let time = lastEventTimes[key] {
            LogDebug("[MockEventService] Found cached time for key '\(key)': \(time)")
            // Apply bounds to the cached time
            if let since = since, time < since {
                LogDebug("[MockEventService] Cached time is before 'since' bound, skipping")
            } else if let until = until, time > until {
                LogDebug("[MockEventService] Cached time is after 'until' bound, skipping")
            } else {
                LogDebug("[MockEventService] Cached time is within bounds, returning \(time)")
                return time
            }
        }
        
        // Fall back to routed events
        var userEvents = routedEvents.filter { $0.distinctId == distinctId && $0.name == name }
        if let since = since {
            userEvents = userEvents.filter { $0.timestamp >= since }
        }
        if let until = until {
            userEvents = userEvents.filter { $0.timestamp <= until }
        }
        
        LogDebug("[MockEventService] Checking \(routedEvents.count) routed events, found \(userEvents.count) matching events")
        
        // Return the most recent event within the bounds
        let result = userEvents.max(by: { $0.timestamp < $1.timestamp })?.timestamp
        LogDebug("[MockEventService] Returning: \(String(describing: result))")
        return result
    }
    
    // Test helper method to set last event time
    public func setLastEventTime(name: String, distinctId: String, time: Date) {
        let key = "\(distinctId):\(name)"
        lastEventTimes[key] = time
    }
    
    // MARK: - Network Queue Management (Mock implementations)
    
    @discardableResult
    public func flushEvents() async -> Bool {
        // Mock implementation - return true
        return true
    }
    
    public func getQueuedEventCount() async -> Int {
        // Mock implementation - return count of routed events
        return routedEvents.count
    }
    
    public func pauseEventQueue() async {
        // Mock implementation - no-op
    }
    
    public func resumeEventQueue() async {
        // Mock implementation - no-op
    }
    
    // MARK: - IR Evaluation Support
    
    public func exists(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Bool {
        return await count(name: name, since: since, until: until, where: predicate) > 0
    }
    
    public func count(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Int {
        let events = routedEvents.filter { $0.name == name }
            .filter { event in
                if let s = since, event.timestamp < s { return false }
                if let u = until, event.timestamp > u { return false }
                return true
            }
        return events.count
    }
    
    public func firstTime(name: String, where predicate: IRPredicate?) async -> Date? {
        let events = routedEvents.filter { $0.name == name }
            .sorted(by: { $0.timestamp < $1.timestamp })
        return events.first?.timestamp
    }
    
    public func lastTime(name: String, where predicate: IRPredicate?) async -> Date? {
        let events = routedEvents.filter { $0.name == name }
            .sorted(by: { $0.timestamp > $1.timestamp })
        return events.first?.timestamp
    }
    
    public func aggregate(_ agg: Aggregate, name: String, prop: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Double? {
        return nil // Mock implementation
    }
    
    public func inOrder(steps: [StepQuery], overallWithin: TimeInterval?, perStepWithin: TimeInterval?, since: Date?, until: Date?) async -> Bool {
        return false // Mock implementation
    }
    
    public func activePeriods(name: String, period: Period, total: Int, min: Int, where predicate: IRPredicate?) async -> Bool {
        return false // Mock implementation
    }
    
    public func stopped(name: String, inactiveFor: TimeInterval, where predicate: IRPredicate?) async -> Bool {
        return false // Mock implementation
    }
    
    public func restarted(name: String, inactiveFor: TimeInterval, within: TimeInterval, where predicate: IRPredicate?) async -> Bool {
        return false // Mock implementation
    }
    
    // Test helpers
    public func reset() {
        routedEvents.removeAll()
        trackedEvents.removeAll()
        eventHandlers.removeAll()
        lastEventTimes.removeAll()
    }
    
    public func addEventHandler(pattern: String, handler: @escaping (NuxieEvent) -> Void) {
        eventHandlers.append((pattern, handler))
    }
    
    // MARK: - User Identity Management
    
    public func beginIdentityTransition() {
        // Mock implementation - no-op
    }
    
    public func identifyUser(
        distinctId: String,
        anonymousId: String?,
        wasIdentified: Bool,
        userProperties: [String: Any]?,
        userPropertiesSetOnce: [String: Any]?
    ) async {
        // Mock implementation: build properties like the real implementation
        var identifyProperties: [String: Any] = [:]
        identifyProperties["distinct_id"] = distinctId
        
        if !wasIdentified, let anonymousId = anonymousId {
            identifyProperties["$anon_distinct_id"] = anonymousId
        }
        
        if let userProperties = userProperties {
            identifyProperties["$set"] = userProperties
        }
        
        if let userPropertiesSetOnce = userPropertiesSetOnce {
            identifyProperties["$set_once"] = userPropertiesSetOnce
        }
        
        let identifyEvent = NuxieEvent(
            name: "$identify",
            distinctId: distinctId,
            properties: identifyProperties
        )
        
        await route(identifyEvent)
    }
    
    public func reassignEvents(from fromUserId: String, to toUserId: String) async throws -> Int {
        // Mock implementation: Update distinctId in routed events
        var reassignedCount = 0
        for i in 0..<routedEvents.count {
            if routedEvents[i].distinctId == fromUserId {
                // Create new event with updated distinctId
                let oldEvent = routedEvents[i]
                routedEvents[i] = NuxieEvent(
                    id: oldEvent.id,
                    name: oldEvent.name,
                    distinctId: toUserId,
                    properties: oldEvent.properties,
                    timestamp: oldEvent.timestamp
                )
                reassignedCount += 1
            }
        }
        return reassignedCount
    }
    
    // MARK: - Cleanup
    
    public func close() async {
        // Mock implementation: just reset state
        reset()
    }
}
