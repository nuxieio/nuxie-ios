import Foundation
@testable import Nuxie

/// Mock implementation of JourneyExecutor for testing
public class MockJourneyExecutor: JourneyExecutorProtocol {
    public var executeResults: [String: NodeExecutionResult] = [:]
    public var findNodeResults: [String: WorkflowNode?] = [:]
    public var executionHistory: [(nodeId: String, journeyId: String)] = []
    
    public func executeNode(
      _ node: WorkflowNode,
      journey: Journey,
      resumeReason: ResumeReason
    ) async -> NodeExecutionResult {
        executionHistory.append((nodeId: node.id, journeyId: journey.id))
        
        if let result = executeResults[node.id] {
            return result
        }
        
        // Default behavior - continue to next node
        return .continue(node.next)
    }
    
    public func findNode(id: String, in campaign: Campaign) -> WorkflowNode? {
        if let result = findNodeResults[id] {
            return result
        }
        
        // Try to find the node in the campaign's workflow
        if let anyNode = campaign.workflow.nodes.first(where: { $0.node.id == id }) {
            return anyNode.node
        }
        
        // Default - create a basic test node
        return TestNodeBuilder(id: id).build().node
    }
    
    public func getNextNodes(from result: NodeExecutionResult, in campaign: Campaign) -> [WorkflowNode] {
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
    
    // Test helpers
    public func reset() {
        executeResults.removeAll()
        findNodeResults.removeAll()
        executionHistory.removeAll()
    }
    
    public func setExecuteResult(nodeId: String, result: NodeExecutionResult) {
        executeResults[nodeId] = result
    }
    
    public func setFindResult(nodeId: String, node: WorkflowNode?) {
        findNodeResults[nodeId] = node
    }
    
    public func getExecutionHistory() -> [(nodeId: String, journeyId: String)] {
        return executionHistory
    }
}
