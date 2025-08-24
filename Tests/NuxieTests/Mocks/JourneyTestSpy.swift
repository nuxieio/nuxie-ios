import Foundation
import Quick
import Nimble
@testable import Nuxie

/// Test spy for monitoring journey execution without modifying production code
public class JourneyTestSpy {
    // MARK: - Recorded Data
    
    /// Node executions with details
    private(set) var nodeExecutions: [(
        nodeId: String,
        nodeType: NodeType,
        result: NodeExecutionResult,
        journeyId: String,
        timestamp: Date
    )] = []
    
    /// Journey state transitions
    private(set) var stateTransitions: [(
        journeyId: String,
        from: JourneyStatus?,
        to: JourneyStatus,
        timestamp: Date
    )] = []
    
    /// Persistence operations
    private(set) var persistenceOperations: [(
        action: PersistAction,
        journeyId: String,
        timestamp: Date
    )] = []
    
    /// Journey lifecycle events
    private(set) var lifecycleEvents: [(
        event: LifecycleEvent,
        journeyId: String,
        campaignId: String,
        timestamp: Date,
        metadata: [String: Any]
    )] = []
    
    /// Context changes in journeys
    private(set) var contextChanges: [(
        journeyId: String,
        key: String,
        oldValue: Any?,
        newValue: Any,
        timestamp: Date
    )] = []
    
    /// Flow display attempts
    private(set) var flowDisplayAttempts: [(
        flowId: String,
        journeyId: String,
        nodeId: String,
        timestamp: Date
    )] = []
    
    /// Delegate calls
    private(set) var delegateCalls: [(
        message: String,
        journeyId: String,
        nodeId: String,
        payload: Any?,
        timestamp: Date
    )] = []
    
    // MARK: - Types
    
    public enum PersistAction {
        case save
        case load
        case delete
        case update
    }
    
    public enum LifecycleEvent {
        case started
        case completed
        case paused
        case resumed
        case errored
    }
    
    // MARK: - Recording Methods
    
    public func recordNodeExecution(
        nodeId: String,
        nodeType: NodeType,
        result: NodeExecutionResult,
        journeyId: String,
        timestamp: Date = Date()
    ) {
        nodeExecutions.append((nodeId, nodeType, result, journeyId, timestamp))
    }
    
    public func recordStateTransition(
        journeyId: String,
        from: JourneyStatus?,
        to: JourneyStatus,
        timestamp: Date = Date()
    ) {
        stateTransitions.append((journeyId, from, to, timestamp))
    }
    
    public func recordPersistence(
        action: PersistAction,
        journeyId: String,
        timestamp: Date = Date()
    ) {
        persistenceOperations.append((action, journeyId, timestamp))
    }
    
    public func recordLifecycleEvent(
        event: LifecycleEvent,
        journeyId: String,
        campaignId: String,
        timestamp: Date = Date(),
        metadata: [String: Any] = [:]
    ) {
        lifecycleEvents.append((event, journeyId, campaignId, timestamp, metadata))
    }
    
    public func recordContextChange(
        journeyId: String,
        key: String,
        oldValue: Any?,
        newValue: Any,
        timestamp: Date = Date()
    ) {
        contextChanges.append((journeyId, key, oldValue, newValue, timestamp))
    }
    
    public func recordFlowDisplay(
        flowId: String,
        journeyId: String,
        nodeId: String,
        timestamp: Date = Date()
    ) {
        flowDisplayAttempts.append((flowId, journeyId, nodeId, timestamp))
    }
    
    public func recordDelegateCall(
        message: String,
        journeyId: String,
        nodeId: String,
        payload: Any? = nil,
        timestamp: Date = Date()
    ) {
        delegateCalls.append((message, journeyId, nodeId, payload, timestamp))
    }
    
    // MARK: - Query Methods
    
    /// Get all node executions for a specific journey
    public func nodeExecutions(for journeyId: String) -> [(nodeId: String, nodeType: NodeType, result: NodeExecutionResult)] {
        nodeExecutions
            .filter { $0.journeyId == journeyId }
            .map { ($0.nodeId, $0.nodeType, $0.result) }
    }
    
    /// Get execution path (node IDs) for a journey
    public func executionPath(for journeyId: String) -> [String] {
        nodeExecutions
            .filter { $0.journeyId == journeyId }
            .map { $0.nodeId }
    }
    
    /// Check if a specific node was executed
    public func wasNodeExecuted(_ nodeId: String, in journeyId: String) -> Bool {
        nodeExecutions.contains { $0.nodeId == nodeId && $0.journeyId == journeyId }
    }
    
    /// Get the result of a specific node execution
    public func nodeResult(_ nodeId: String, in journeyId: String) -> NodeExecutionResult? {
        nodeExecutions
            .first { $0.nodeId == nodeId && $0.journeyId == journeyId }?
            .result
    }
    
    /// Get persistence operations for a journey
    public func persistenceOperations(for journeyId: String) -> [PersistAction] {
        persistenceOperations
            .filter { $0.journeyId == journeyId }
            .map { $0.action }
    }
    
    /// Check if journey was persisted
    public func wasJourneyPersisted(_ journeyId: String) -> Bool {
        persistenceOperations.contains { 
            $0.journeyId == journeyId && $0.action == .save 
        }
    }
    
    /// Get lifecycle events for a journey
    public func lifecycleEvents(for journeyId: String) -> [LifecycleEvent] {
        lifecycleEvents
            .filter { $0.journeyId == journeyId }
            .map { $0.event }
    }
    
    // MARK: - Assertion Helpers
    
    /// Assert that a journey followed a specific path
    public func assertPath(_ expectedPath: [String], for journeyId: String) {
        let actualPath = executionPath(for: journeyId)
        expect(actualPath).to(equal(expectedPath), 
            description: "Expected path \(expectedPath) but got \(actualPath)")
    }
    
    /// Assert that a journey completed with a specific status
    public func assertCompleted(journeyId: String, withStatus status: JourneyStatus) {
        let lastTransition = stateTransitions
            .filter { $0.journeyId == journeyId }
            .last
        expect(lastTransition?.to).to(equal(status))
    }
    
    /// Assert that no persistence occurred for a journey
    public func assertNoPersistence(for journeyId: String) {
        let saves = persistenceOperations
            .filter { $0.journeyId == journeyId && $0.action == .save }
        expect(saves).to(beEmpty(), 
            description: "Expected no persistence but found \(saves.count) save operations")
    }
    
    /// Assert persistence count for a journey
    public func assertPersistenceCount(_ count: Int, for journeyId: String) {
        let saves = persistenceOperations
            .filter { $0.journeyId == journeyId && $0.action == .save }
        expect(saves).to(haveCount(count))
    }
    
    /// Assert that a specific node was executed with expected result
    public func assertNodeExecuted(
        _ nodeId: String,
        in journeyId: String,
        withResult expectedResult: NodeExecutionResult? = nil
    ) {
        let execution = nodeExecutions
            .first { $0.nodeId == nodeId && $0.journeyId == journeyId }
        
        expect(execution).toNot(beNil(), 
            description: "Expected node \(nodeId) to be executed")
        
        if let expectedResult = expectedResult, let actualResult = execution?.result {
            // Manual comparison since NodeExecutionResult doesn't conform to Equatable
            switch (expectedResult, actualResult) {
            case (.continue(let expected), .continue(let actual)):
                expect(actual).to(equal(expected))
            case (.async(let expected), .async(let actual)):
                expect(actual).to(equal(expected))
            case (.skip(let expected), .skip(let actual)):
                expect(actual).to(equal(expected))
            case (.complete(let expected), .complete(let actual)):
                expect(actual).to(equal(expected))
            default:
                fail("Expected \(expectedResult) but got \(actualResult)")
            }
        }
    }
    
    /// Assert that a flow was displayed
    public func assertFlowDisplayed(_ flowId: String, for journeyId: String) {
        let displays = flowDisplayAttempts
            .filter { $0.flowId == flowId && $0.journeyId == journeyId }
        expect(displays).toNot(beEmpty(),
            description: "Expected flow \(flowId) to be displayed")
    }
    
    /// Assert that a delegate was called
    public func assertDelegateCalled(_ message: String, for journeyId: String) {
        let calls = delegateCalls
            .filter { $0.message == message && $0.journeyId == journeyId }
        expect(calls).toNot(beEmpty(),
            description: "Expected delegate to be called with message '\(message)'")
    }
    
    /// Assert lifecycle event occurred
    public func assertLifecycleEvent(_ event: LifecycleEvent, for journeyId: String) {
        let events = lifecycleEvents
            .filter { $0.journeyId == journeyId && $0.event == event }
        expect(events).toNot(beEmpty(),
            description: "Expected lifecycle event \(event) for journey \(journeyId)")
    }
    
    // MARK: - Reset
    
    public func reset() {
        nodeExecutions.removeAll()
        stateTransitions.removeAll()
        persistenceOperations.removeAll()
        lifecycleEvents.removeAll()
        contextChanges.removeAll()
        flowDisplayAttempts.removeAll()
        delegateCalls.removeAll()
    }
}