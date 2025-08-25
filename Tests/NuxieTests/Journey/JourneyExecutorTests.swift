import Foundation
import Quick
import Nimble
import UIKit
import FactoryKit
@testable import Nuxie

// MARK: - Mock Services

class JourneyExecutorTestFlowService: FlowServiceProtocol {
    private(set) var viewControllerCalled = false
    private(set) var lastFlowId: String?
    var shouldFailViewController = false
    
    func prefetchFlows(_ flows: [RemoteFlow]) {
        // No-op for tests
    }
    
    func removeFlows(_ flowIds: [String]) async {
        // No-op for tests
    }
    
    @MainActor
    func viewController(for flowId: String) async throws -> FlowViewController {
        viewControllerCalled = true
        lastFlowId = flowId
        if shouldFailViewController {
            throw JourneyTestFlowError.presentationFailed
        }
        // Return a dummy view controller for testing
        let remoteFlow = RemoteFlow(
            id: flowId, 
            name: "Test Flow", 
            url: "https://test.com", 
            products: [], 
            manifest: BuildManifest(totalFiles: 0, totalSize: 0, contentHash: "", files: [])
        )
        let flow = Flow(remoteFlow: remoteFlow, products: [])
        // Create a mock FlowArchiver for testing
        let mockArchiver = FlowArchiver()
        return FlowViewController(flow: flow, archiveService: mockArchiver)
    }
    
    func clearCache() async {
        // No-op for tests
    }
    
    func reset() {
        viewControllerCalled = false
        lastFlowId = nil
        shouldFailViewController = false
    }
}

class JourneyExecutorTestEventService: EventServiceProtocol {
    private(set) var routeCalled = false
    private(set) var lastEvent: NuxieEvent?
    private(set) var routedEvents: [NuxieEvent] = []
    private(set) var trackedEvents: [(name: String, properties: [String: Any]?)] = []
    
    func beginIdentityTransition() {
        // Mock implementation - no-op for tests
    }
    
    func identifyUser(distinctId: String, anonymousId: String?, wasIdentified: Bool, userProperties: [String: Any]?, userPropertiesSetOnce: [String: Any]?) async {
        // Mock implementation - track as identify event
        var identifyProperties: [String: Any] = ["distinct_id": distinctId]
        
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
    
    func trackAsync(
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
    
    func route(_ event: NuxieEvent) async -> NuxieEvent? {
        routeCalled = true
        lastEvent = event
        routedEvents.append(event)
        return event
    }
    
    func routeBatch(_ events: [NuxieEvent]) async -> [NuxieEvent] {
        for event in events {
            _ = await route(event)
        }
        return events
    }
    
    func configure(
        networkQueue: NuxieNetworkQueue?,
        journeyService: JourneyServiceProtocol?,
        contextBuilder: NuxieContextBuilder?,
        configuration: NuxieConfiguration?
    ) async throws {
        // No-op for tests
    }
    
    func getRecentEvents(limit: Int) async -> [StoredEvent] {
        return []
    }
    
    func getEventsForUser(_ distinctId: String, limit: Int) async -> [StoredEvent] {
        return []
    }
    
    func getEvents(for sessionId: String) async -> [StoredEvent] {
        return []
    }
    
    func hasEvent(name: String, distinctId: String, since: Date?) async -> Bool {
        return false
    }
    
    func countEvents(name: String, distinctId: String, since: Date?, until: Date?) async -> Int {
        return 0
    }
    
    func getLastEventTime(name: String, distinctId: String, since: Date?, until: Date?) async -> Date? {
        return nil
    }
    
    // MARK: - Network Queue Management (Mock implementations)
    
    @discardableResult
    func flushEvents() async -> Bool {
        return true
    }
    
    func getQueuedEventCount() async -> Int {
        return routedEvents.count
    }
    
    func pauseEventQueue() async {
        // Mock implementation - no-op
    }
    
    func resumeEventQueue() async {
        // Mock implementation - no-op
    }
    
    // MARK: - IR Evaluation Support
    
    func exists(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Bool {
        return false
    }
    
    func count(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Int {
        return 0
    }
    
    func firstTime(name: String, where predicate: IRPredicate?) async -> Date? {
        return nil
    }
    
    func lastTime(name: String, where predicate: IRPredicate?) async -> Date? {
        return nil
    }
    
    func aggregate(_ agg: Aggregate, name: String, prop: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Double? {
        return nil
    }
    
    func inOrder(steps: [StepQuery], overallWithin: TimeInterval?, perStepWithin: TimeInterval?, since: Date?, until: Date?) async -> Bool {
        return false
    }
    
    func activePeriods(name: String, period: Period, total: Int, min: Int, where predicate: IRPredicate?) async -> Bool {
        return false
    }
    
    func stopped(name: String, inactiveFor: TimeInterval, where predicate: IRPredicate?) async -> Bool {
        return false
    }
    
    func restarted(name: String, inactiveFor: TimeInterval, within: TimeInterval, where predicate: IRPredicate?) async -> Bool {
        return false
    }
    
    func reset() {
        routeCalled = false
        lastEvent = nil
        routedEvents.removeAll()
        trackedEvents.removeAll()
    }
    
    func reassignEvents(from fromUserId: String, to toUserId: String) async throws -> Int {
        // Mock implementation - return 0 for no events reassigned
        return 0
    }
    
    func close() async {
        // Mock implementation - just reset state
        reset()
    }
    
    func onAppDidEnterBackground() async {
        // Mock implementation - no-op for tests
    }
    
    func onAppBecameActive() async {
        // Mock implementation - no-op for tests
    }
}

class JourneyExecutorTestIdentityService: IdentityServiceProtocol {
    private var distinctId = "test-user"
    private var userProperties: [String: Any] = [:]
    private var _isIdentified = true
    
    func getDistinctId() -> String {
        return distinctId
    }
    
    func getRawDistinctId() -> String? {
        return _isIdentified ? distinctId : nil
    }
    
    func getAnonymousId() -> String {
        return "anonymous-id"
    }
    
    var isIdentified: Bool {
        return _isIdentified
    }
    
    func setDistinctId(_ distinctId: String) {
        self.distinctId = distinctId
        self._isIdentified = true
    }
    
    func reset(keepAnonymousId: Bool) {
        distinctId = "anonymous"
        userProperties.removeAll()
        _isIdentified = false
    }
    
    func clearUserCache(distinctId: String?) {
        // No-op for tests
    }
    
    func getUserProperties() -> [String: Any] {
        return userProperties
    }
    
    func setUserProperties(_ properties: [String: Any]) {
        for (key, value) in properties {
            userProperties[key] = value
        }
    }
    
    func setOnceUserProperties(_ properties: [String: Any]) {
        for (key, value) in properties {
            if userProperties[key] == nil {
                userProperties[key] = value
            }
        }
    }
    
    func userProperty(for key: String) async -> Any? {
        return userProperties[key]
    }
    
    func reset() {
        reset(keepAnonymousId: false)
    }
}

class JourneyExecutorTestEventStore: EventStoreProtocol {
    private(set) var storedEvents: [StoredEvent] = []
    // Session management moved to SessionService
    private let defaultSessionId = "test-session"
    private var eventCount = 0
    
    func initialize(path: URL?) throws {
        // No-op for tests
    }
    
    func reset() {
        storedEvents.removeAll()
        eventCount = 0
    }
    
    func storeEvent(name: String, properties: [String: Any], distinctId: String?) throws {
        // Add session ID to properties
        var propertiesWithSession = properties
        propertiesWithSession["$session_id"] = defaultSessionId
        
        let event = try StoredEvent(
            name: name,
            properties: propertiesWithSession,
            distinctId: distinctId
        )
        storedEvents.append(event)
        eventCount += 1
    }
    
    func getRecentEvents(limit: Int) throws -> [StoredEvent] {
        return Array(storedEvents.suffix(limit))
    }
    
    func getEventsForUser(_ distinctId: String, limit: Int) throws -> [StoredEvent] {
        return Array(storedEvents.filter { $0.distinctId == distinctId }.suffix(limit))
    }
    
    func getEvents(for sessionId: String) throws -> [StoredEvent] {
        // Filter events by session ID (using the field, not properties)
        return storedEvents.filter { event in
            return event.sessionId == sessionId
        }
    }
    
    func getEventCount() throws -> Int {
        return eventCount
    }
    
    @discardableResult
    func forceCleanup() throws -> Int {
        let oldCount = storedEvents.count
        storedEvents.removeAll()
        eventCount = 0
        return oldCount
    }
    
    func close() {
        // No-op for tests
    }
    
    func hasEvent(name: String, distinctId: String, since: Date?) throws -> Bool {
        return storedEvents.contains { event in
            if event.name != name || event.distinctId != distinctId {
                return false
            }
            if let since = since {
                return event.timestamp >= since
            }
            return true
        }
    }
    
    func countEvents(name: String, distinctId: String, since: Date?, until: Date?) throws -> Int {
        return storedEvents.filter { event in
            if event.name != name || event.distinctId != distinctId {
                return false
            }
            if let since = since, event.timestamp < since {
                return false
            }
            if let until = until, event.timestamp > until {
                return false
            }
            return true
        }.count
    }
    
    func getLastEventTime(name: String, distinctId: String, since: Date?, until: Date?) throws -> Date? {
        let filtered = storedEvents.filter { event in
            if event.name != name || event.distinctId != distinctId {
                return false
            }
            if let since = since, event.timestamp < since {
                return false
            }
            if let until = until, event.timestamp > until {
                return false
            }
            return true
        }
        return filtered.max { $0.timestamp < $1.timestamp }?.timestamp
    }
    
    func reassignEvents(from fromUserId: String, to toUserId: String) throws -> Int {
        // Mock implementation - update distinctId in stored events
        var reassignedCount = 0
        for i in 0..<storedEvents.count {
            if storedEvents[i].distinctId == fromUserId {
                let oldEvent = storedEvents[i]
                storedEvents[i] = StoredEvent(
                    id: oldEvent.id,
                    name: oldEvent.name,
                    properties: oldEvent.properties,
                    timestamp: oldEvent.timestamp,
                    distinctId: toUserId,
                    sessionId: oldEvent.sessionId
                )
                reassignedCount += 1
            }
        }
        return reassignedCount
    }
}

actor JourneyExecutorTestSegmentService: SegmentServiceProtocol {
    private var memberships: [SegmentService.SegmentMembership] = []
    private var distinctId: String?
    private var segmentChangesContinuation: AsyncStream<SegmentService.SegmentEvaluationResult>.Continuation?
    public let segmentChanges: AsyncStream<SegmentService.SegmentEvaluationResult>
    
    init() {
        var continuation: AsyncStream<SegmentService.SegmentEvaluationResult>.Continuation?
        self.segmentChanges = AsyncStream { cont in
            continuation = cont
        }
        self.segmentChangesContinuation = continuation
    }
    
    deinit {
        segmentChangesContinuation?.finish()
    }
    
    func getCurrentMemberships() async -> [SegmentService.SegmentMembership] {
        return memberships
    }
    
    func updateSegments(_ segments: [Segment], for distinctId: String) async {
        // No-op for tests
    }
    
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
        self.distinctId = newDistinctId
    }
    
    func clearSegments(for distinctId: String) async {
        memberships.removeAll()
    }
    
    func isInSegment(_ segmentId: String) async -> Bool {
        return memberships.contains { $0.segmentId == segmentId }
    }
    
    func isMember(_ segmentId: String) async -> Bool {
        return memberships.contains { $0.segmentId == segmentId }
    }
    
    func enteredAt(_ segmentId: String) async -> Date? {
        return memberships.first { $0.segmentId == segmentId }?.enteredAt
    }
    
    func addMembership(segmentId: String, segmentName: String) {
        let membership = SegmentService.SegmentMembership(
            segmentId: segmentId,
            segmentName: segmentName,
            enteredAt: Date(),
            lastEvaluated: Date()
        )
        memberships.append(membership)
    }
    
    func reset() {
        memberships.removeAll()
        distinctId = nil
    }
}

enum JourneyTestFlowError: Error {
    case presentationFailed
}

// MARK: - Test Spec

final class JourneyExecutorTests: AsyncSpec {
    override class func spec() {
        describe("JourneyExecutor") {
            var executor: JourneyExecutor!
            var mockFlowService: JourneyExecutorTestFlowService!
            var mockEventService: JourneyExecutorTestEventService!
            var mockIdentityService: JourneyExecutorTestIdentityService!
            var mockEventStore: JourneyExecutorTestEventStore!
            var mockSegmentService: JourneyExecutorTestSegmentService!
            var journey: Journey!
            var campaign: Campaign!
            
            beforeEach {
                // Create mock services
                mockFlowService = JourneyExecutorTestFlowService()
                mockEventService = JourneyExecutorTestEventService()
                mockIdentityService = JourneyExecutorTestIdentityService()
                mockEventStore = JourneyExecutorTestEventStore()
                mockSegmentService = JourneyExecutorTestSegmentService()
                
                // Set up Factory container with mocks
                Container.shared.flowService.register { mockFlowService }
                Container.shared.segmentService.register { mockSegmentService }
                Container.shared.eventService.register { mockEventService }
                Container.shared.identityService.register { mockIdentityService }
                Container.shared.dateProvider.register { MockDateProvider() }
                
                // Create test campaign with nodes
                let campaignJSON = """
                {
                    "id": "test-campaign",
                    "name": "Test Campaign",
                    "versionId": "v1",
                    "versionNumber": 1,
                    "frequencyPolicy": "every_rematch",
                    "publishedAt": "2024-01-01",
                    "trigger": {
                        "type": "event",
                        "config": {
                            "eventName": "test_event"
                        }
                    },
                    "entryNodeId": "node1",
                    "workflow": {
                        "nodes": [
                            {
                                "id": "node1",
                                "type": "show_flow",
                                "next": ["node2"],
                                "data": {
                                    "flowId": "test-flow"
                                }
                            },
                            {
                                "id": "node2",
                                "type": "time_delay",
                                "next": ["node3"],
                                "data": {
                                    "duration": 3600
                                }
                            },
                            {
                                "id": "node3",
                                "type": "exit",
                                "next": [],
                                "data": {
                                    "reason": "completed"
                                }
                            }
                        ]
                    }
                }
                """.data(using: .utf8)!
                
                let decoder = JSONDecoder()
                campaign = try! decoder.decode(Campaign.self, from: campaignJSON)
                journey = Journey(campaign: campaign, distinctId: "test-user")
                
                // Create executor AFTER DI setup
                executor = JourneyExecutor()
            }
            
            afterEach {
                mockFlowService?.reset()
                mockEventService?.reset()
                mockIdentityService?.reset()
                mockEventStore?.reset()
                await mockSegmentService?.reset()
                Container.shared.reset()
            }
            
            // MARK: - Node Finding Tests
            
            describe("findNode") {
                it("should find existing node by ID") {
                    let node = executor.findNode(id: "node1", in: campaign)
                    expect(node).toNot(beNil())
                    expect(node?.id).to(equal("node1"))
                    expect(node?.type).to(equal(.showFlow))
                }
                
                it("should return nil for non-existent node") {
                    let node = executor.findNode(id: "nonexistent", in: campaign)
                    expect(node).to(beNil())
                }
            }
            
            // MARK: - Error Handling Tests
            
            describe("error handling") {
                it("should handle unsupported node types") {
                    // Create a mock node with unsupported type
                    struct UnsupportedNode: WorkflowNode {
                        var id: String { "unsupported" }
                        var type: NodeType { .eventTrigger } // Not handled in execution
                        var condition: String? { nil }
                        var next: [String] { ["next-node"] }
                    }
                    
                    let unsupportedNode = UnsupportedNode()
                    let result = await executor.executeNode(unsupportedNode, journey: journey, resumeReason: .start)
                    
                    switch result {
                    case .skip(let skipToNode):
                        expect(skipToNode).to(equal("next-node"))
                    default:
                        fail("Expected skip result for unsupported node")
                    }
                }
                
                it("should handle branch errors gracefully") {
                    let branchNode = BranchNode(
                        id: "branch-node",
                        next: ["true-node", "false-node"],
                        data: BranchNode.BranchData(
                            condition: IREnvelope(
                                ir_version: 1,
                                engine_min: nil,
                                compiled_at: nil,
                                expr: .bool(false) // Invalid expression will evaluate to false
                            )
                        )
                    )
                    
                    let result = await executor.executeNode(branchNode, journey: journey, resumeReason: .start)
                    
                    switch result {
                    case .continue(let nextNodes):
                        // Should take false path on error
                        expect(nextNodes).to(equal(["false-node"]))
                    default:
                        fail("Expected continue result")
                    }
                }
            }
            
            // MARK: - Get Next Nodes Tests
            
            describe("getNextNodes") {
                it("should return nodes for continue result") {
                    let result = NodeExecutionResult.continue(["node1", "node2"])
                    let nextNodes = executor.getNextNodes(from: result, in: campaign)
                    
                    expect(nextNodes.count).to(equal(2))
                    expect(nextNodes[0].id).to(equal("node1"))
                    expect(nextNodes[1].id).to(equal("node2"))
                }
                
                it("should return node for skip result") {
                    let result = NodeExecutionResult.skip("node2")
                    let nextNodes = executor.getNextNodes(from: result, in: campaign)
                    
                    expect(nextNodes.count).to(equal(1))
                    expect(nextNodes[0].id).to(equal("node2"))
                }
                
                it("should return empty for async result") {
                    let result = NodeExecutionResult.async(Date())
                    let nextNodes = executor.getNextNodes(from: result, in: campaign)
                    
                    expect(nextNodes).to(beEmpty())
                }
                
                it("should return empty for complete result") {
                    let result = NodeExecutionResult.complete(.completed)
                    let nextNodes = executor.getNextNodes(from: result, in: campaign)
                    
                    expect(nextNodes).to(beEmpty())
                }
            }
        }
    }
}
