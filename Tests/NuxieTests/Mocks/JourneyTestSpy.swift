import Foundation
import Quick
import Nimble
@testable import Nuxie

/// Test spy for monitoring journey execution without modifying production code
public class JourneyTestSpy {
    private let lock = NSLock()
    // MARK: - Recorded Data
    
    /// Node executions with details
    private var _nodeExecutions: [(
        nodeId: String,
        nodeType: NodeType,
        result: NodeExecutionResult,
        journeyId: String,
        timestamp: Date
    )] = []
    public private(set) var nodeExecutions: [(
        nodeId: String,
        nodeType: NodeType,
        result: NodeExecutionResult,
        journeyId: String,
        timestamp: Date
    )] {
        get { lock.withLock { _nodeExecutions } }
        set { lock.withLock { _nodeExecutions = newValue } }
    }
    
    /// Journey state transitions
    private var _stateTransitions: [(
        journeyId: String,
        from: JourneyStatus?,
        to: JourneyStatus,
        timestamp: Date
    )] = []
    public private(set) var stateTransitions: [(
        journeyId: String,
        from: JourneyStatus?,
        to: JourneyStatus,
        timestamp: Date
    )] {
        get { lock.withLock { _stateTransitions } }
        set { lock.withLock { _stateTransitions = newValue } }
    }
    
    /// Persistence operations
    private var _persistenceOperations: [(
        action: PersistAction,
        journeyId: String,
        timestamp: Date
    )] = []
    public private(set) var persistenceOperations: [(
        action: PersistAction,
        journeyId: String,
        timestamp: Date
    )] {
        get { lock.withLock { _persistenceOperations } }
        set { lock.withLock { _persistenceOperations = newValue } }
    }
    
    /// Journey lifecycle events
    private var _lifecycleEvents: [(
        event: LifecycleEvent,
        journeyId: String,
        campaignId: String,
        timestamp: Date,
        metadata: [String: Any]
    )] = []
    public private(set) var lifecycleEvents: [(
        event: LifecycleEvent,
        journeyId: String,
        campaignId: String,
        timestamp: Date,
        metadata: [String: Any]
    )] {
        get { lock.withLock { _lifecycleEvents } }
        set { lock.withLock { _lifecycleEvents = newValue } }
    }
    
    /// Context changes in journeys
    private var _contextChanges: [(
        journeyId: String,
        key: String,
        oldValue: Any?,
        newValue: Any,
        timestamp: Date
    )] = []
    public private(set) var contextChanges: [(
        journeyId: String,
        key: String,
        oldValue: Any?,
        newValue: Any,
        timestamp: Date
    )] {
        get { lock.withLock { _contextChanges } }
        set { lock.withLock { _contextChanges = newValue } }
    }
    
    /// Flow display attempts
    private var _flowDisplayAttempts: [(
        flowId: String,
        journeyId: String,
        nodeId: String,
        timestamp: Date
    )] = []
    public private(set) var flowDisplayAttempts: [(
        flowId: String,
        journeyId: String,
        nodeId: String,
        timestamp: Date
    )] {
        get { lock.withLock { _flowDisplayAttempts } }
        set { lock.withLock { _flowDisplayAttempts = newValue } }
    }
    
    /// Delegate calls
    private var _delegateCalls: [(
        message: String,
        journeyId: String,
        nodeId: String,
        payload: Any?,
        timestamp: Date
    )] = []
    public private(set) var delegateCalls: [(
        message: String,
        journeyId: String,
        nodeId: String,
        payload: Any?,
        timestamp: Date
    )] {
        get { lock.withLock { _delegateCalls } }
        set { lock.withLock { _delegateCalls = newValue } }
    }
    
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
        lock.withLock {
            _nodeExecutions.append((nodeId, nodeType, result, journeyId, timestamp))
        }
    }
    
    public func recordStateTransition(
        journeyId: String,
        from: JourneyStatus?,
        to: JourneyStatus,
        timestamp: Date = Date()
    ) {
        lock.withLock {
            _stateTransitions.append((journeyId, from, to, timestamp))
        }
    }
    
    public func recordPersistence(
        action: PersistAction,
        journeyId: String,
        timestamp: Date = Date()
    ) {
        lock.withLock {
            _persistenceOperations.append((action, journeyId, timestamp))
        }
    }
    
    public func recordLifecycleEvent(
        event: LifecycleEvent,
        journeyId: String,
        campaignId: String,
        timestamp: Date = Date(),
        metadata: [String: Any] = [:]
    ) {
        lock.withLock {
            _lifecycleEvents.append((event, journeyId, campaignId, timestamp, metadata))
        }
    }
    
    public func recordContextChange(
        journeyId: String,
        key: String,
        oldValue: Any?,
        newValue: Any,
        timestamp: Date = Date()
    ) {
        lock.withLock {
            _contextChanges.append((journeyId, key, oldValue, newValue, timestamp))
        }
    }
    
    public func recordFlowDisplay(
        flowId: String,
        journeyId: String,
        nodeId: String,
        timestamp: Date = Date()
    ) {
        lock.withLock {
            _flowDisplayAttempts.append((flowId, journeyId, nodeId, timestamp))
        }
    }
    
    public func recordDelegateCall(
        message: String,
        journeyId: String,
        nodeId: String,
        payload: Any? = nil,
        timestamp: Date = Date()
    ) {
        lock.withLock {
            _delegateCalls.append((message, journeyId, nodeId, payload, timestamp))
        }
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
        lock.withLock {
            _nodeExecutions.removeAll()
            _stateTransitions.removeAll()
            _persistenceOperations.removeAll()
            _lifecycleEvents.removeAll()
            _contextChanges.removeAll()
            _flowDisplayAttempts.removeAll()
            _delegateCalls.removeAll()
        }
    }
}
