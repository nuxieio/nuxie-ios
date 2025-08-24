import Foundation
@testable import Nuxie

/// Spy implementation of JourneyExecutor that wraps the real executor and records interactions
public class SpyJourneyExecutor: JourneyExecutorProtocol {
    
    // MARK: - Properties
    
    /// The real executor that performs actual execution
    private let realExecutor: JourneyExecutor
    
    /// The spy that records all interactions
    private let spy: JourneyTestSpy
    
    // MARK: - Initialization
    
    public init(spy: JourneyTestSpy) {
        self.realExecutor = JourneyExecutor()
        self.spy = spy
    }
    
    // MARK: - JourneyExecutorProtocol
    
    public func executeNode(
        _ node: any WorkflowNode,
        journey: Journey,
        resumeReason: ResumeReason
    ) async -> NodeExecutionResult {
        // Record that we're about to execute this node
        let nodeType = node.type
        let nodeId = node.id
        let journeyId = journey.id
        
        // Execute the real node with the resume reason
        let result = await realExecutor.executeNode(
            node,
            journey: journey,
            resumeReason: resumeReason
        )
        
        // Record the execution with its result
        spy.recordNodeExecution(
            nodeId: nodeId,
            nodeType: nodeType,
            result: result,
            journeyId: journeyId
        )
        
        // Special handling for Show Flow nodes to record flow display attempts
        if nodeType == .showFlow,
           let showFlowNode = node as? ShowFlowNode {
            let flowId = showFlowNode.data.flowId
            spy.recordFlowDisplay(
                flowId: flowId,
                journeyId: journeyId,
                nodeId: nodeId
            )
        }
        
        // Special handling for Call Delegate nodes to record delegate calls
        if nodeType == .callDelegate,
           let delegateNode = node as? CallDelegateNode {
            spy.recordDelegateCall(
                message: delegateNode.data.message,
                journeyId: journeyId,
                nodeId: nodeId,
                payload: delegateNode.data.payload?.value
            )
        }
        
        return result
    }
    
    public func findNode(id: String, in campaign: Campaign) -> (any WorkflowNode)? {
        // Delegate to real executor
        return realExecutor.findNode(id: id, in: campaign)
    }
    
    public func getNextNodes(from result: NodeExecutionResult, in campaign: Campaign) -> [any WorkflowNode] {
        // Delegate to real executor
        return realExecutor.getNextNodes(from: result, in: campaign)
    }
}

/// Extension to spy on JourneyStore operations
public class SpyJourneyStore: JourneyStoreProtocol {
    
    // MARK: - Properties
    
    /// The real store that performs actual operations
    private let realStore: JourneyStoreProtocol
    
    /// The spy that records all interactions
    private let spy: JourneyTestSpy
    
    // MARK: - Initialization
    
    public init(realStore: JourneyStoreProtocol, spy: JourneyTestSpy) {
        self.realStore = realStore
        self.spy = spy
    }
    
    // MARK: - JourneyStoreProtocol
    
    public func saveJourney(_ journey: Journey) throws {
        spy.recordPersistence(action: .save, journeyId: journey.id)
        try realStore.saveJourney(journey)
    }
    
    public func loadActiveJourneys() -> [Journey] {
        // Note: We don't record loads in bulk, but could if needed
        return realStore.loadActiveJourneys()
    }
    
    public func loadJourney(id: String) -> Journey? {
        spy.recordPersistence(action: .load, journeyId: id)
        return realStore.loadJourney(id: id)
    }
    
    public func deleteJourney(id: String) {
        spy.recordPersistence(action: .delete, journeyId: id)
        realStore.deleteJourney(id: id)
    }
    
    public func recordCompletion(_ record: JourneyCompletionRecord) throws {
        // Could track this separately if needed
        try realStore.recordCompletion(record)
    }
    
    public func hasCompletedCampaign(distinctId: String, campaignId: String) -> Bool {
        return realStore.hasCompletedCampaign(distinctId: distinctId, campaignId: campaignId)
    }
    
    public func lastCompletionTime(distinctId: String, campaignId: String) -> Date? {
        return realStore.lastCompletionTime(distinctId: distinctId, campaignId: campaignId)
    }
    
    public func cleanup(olderThan date: Date) {
        realStore.cleanup(olderThan: date)
    }
    
    public func getActiveJourneyIds(distinctId: String, campaignId: String) -> Set<String> {
        return realStore.getActiveJourneyIds(distinctId: distinctId, campaignId: campaignId)
    }
    
    public func updateCache(for journey: Journey) {
        spy.recordPersistence(action: .update, journeyId: journey.id)
        realStore.updateCache(for: journey)
    }
    
    public func clearCache() {
        realStore.clearCache()
    }
}
