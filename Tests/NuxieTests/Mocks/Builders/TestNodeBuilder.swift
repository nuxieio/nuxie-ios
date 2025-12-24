import Foundation
@testable import Nuxie

/// Builder for creating test workflow nodes with fluent API
class TestNodeBuilder {
    internal let id: String
    private var nodeType: NodeType = .exit
    private var next: [String] = []
    private var condition: IREnvelope?
    private var waitPaths: [WaitUntilNode.WaitUntilData.WaitPath] = []
    private var branchConditions: [IREnvelope] = []
    private var randomBranches: [RandomBranchNode.RandomBranchData.RandomBranch] = []
    
    // Additional properties to store node-specific data
    private var flowId: String?
    private var duration: TimeInterval?
    private var remoteAction: String?
    private var remotePayload: AnyCodable?
    private var remoteAsync: Bool?
    
    init(id: String) {
        self.id = id
    }
    
    func withType(_ type: NodeType) -> TestNodeBuilder {
        self.nodeType = type
        return self
    }
    
    func withNext(_ nextNodes: [String]) -> TestNodeBuilder {
        self.next = nextNodes
        return self
    }
    
    func withCondition(_ condition: IREnvelope) -> TestNodeBuilder {
        self.condition = condition
        return self
    }
    
    func addWaitPath(_ pathId: String, condition: IREnvelope, maxTime: TimeInterval? = nil, next: String) -> TestNodeBuilder {
        let path = WaitUntilNode.WaitUntilData.WaitPath(
            id: pathId,
            condition: condition,
            maxTime: maxTime,
            next: next
        )
        waitPaths.append(path)
        return self
    }
    
    func addBranchCondition(_ condition: IREnvelope) -> TestNodeBuilder {
        branchConditions.append(condition)
        return self
    }
    
    func addRandomBranch(percentage: Double, name: String? = nil) -> TestNodeBuilder {
        let branch = RandomBranchNode.RandomBranchData.RandomBranch(
            percentage: percentage,
            name: name
        )
        randomBranches.append(branch)
        return self
    }
    
    func build() -> AnyWorkflowNode {
        switch nodeType {
        case .exit:
            return AnyWorkflowNode(ExitNode(
                id: id,
                next: next,
                data: nil
            ))
        case .showFlow:
            return AnyWorkflowNode(ShowFlowNode(
                id: id,
                next: next,
                data: ShowFlowNode.ShowFlowData(flowId: flowId ?? "test-flow")
            ))
        case .timeDelay:
            return AnyWorkflowNode(TimeDelayNode(
                id: id,
                next: next,
                data: TimeDelayNode.TimeDelayData(duration: duration ?? 60) // Default 1 minute
            ))
        case .branch:
            return AnyWorkflowNode(BranchNode(
                id: id,
                next: next, // [truePath, falsePath]
                data: BranchNode.BranchData(
                    condition: condition ?? TestIRBuilder.alwaysTrue()
                )
            ))
        case .multiBranch:
            return AnyWorkflowNode(MultiBranchNode(
                id: id,
                next: next, // Each index maps to condition, last is default
                data: MultiBranchNode.MultiBranchData(
                    conditions: branchConditions
                )
            ))
        case .updateCustomer:
            return AnyWorkflowNode(UpdateCustomerNode(
                id: id,
                next: next,
                data: UpdateCustomerNode.UpdateCustomerData(attributes: [:])
            ))
        case .sendEvent:
            return AnyWorkflowNode(SendEventNode(
                id: id,
                next: next,
                data: SendEventNode.SendEventData(eventName: "test_event", properties: nil)
            ))
        case .waitUntil:
            return AnyWorkflowNode(WaitUntilNode(
                id: id,
                next: [], // Wait Until nodes use paths for next nodes
                data: WaitUntilNode.WaitUntilData(paths: waitPaths)
            ))
        case .randomBranch:
            return AnyWorkflowNode(RandomBranchNode(
                id: id,
                next: next, // Each index maps to branch
                data: RandomBranchNode.RandomBranchData(branches: randomBranches)
            ))
        case .remote:
            return AnyWorkflowNode(RemoteNode(
                id: id,
                next: next,
                data: RemoteNode.RemoteData(
                    action: remoteAction ?? "webhook",
                    payload: remotePayload,
                    async: remoteAsync
                )
            ))
        default:
            // Default node for unsupported types
            return AnyWorkflowNode(ExitNode(
                id: id,
                next: [],
                data: nil
            ))
        }
    }
    
    // Static factory methods for common node types
    static func exit(id: String) -> TestNodeBuilder {
        return TestNodeBuilder(id: id).withType(.exit)
    }
    
    static func showFlow(id: String, flowId: String) -> TestNodeBuilder {
        let builder = TestNodeBuilder(id: id).withType(.showFlow)
        // Store the flowId for later use in build()
        builder.flowId = flowId
        return builder
    }
    
    static func timeDelay(id: String, duration: TimeInterval) -> TestNodeBuilder {
        let builder = TestNodeBuilder(id: id).withType(.timeDelay)
        // Store the duration for later use in build()
        builder.duration = duration
        return builder
    }
    
    static func waitUntil(id: String) -> TestNodeBuilder {
        return TestNodeBuilder(id: id).withType(.waitUntil)
    }

    static func remote(id: String, action: String, payload: Any? = nil, async: Bool? = nil) -> TestNodeBuilder {
        let builder = TestNodeBuilder(id: id).withType(.remote)
        builder.remoteAction = action
        builder.remotePayload = payload.map { AnyCodable($0) }
        builder.remoteAsync = async
        return builder
    }

    func withRemoteAction(_ action: String) -> TestNodeBuilder {
        self.remoteAction = action
        return self
    }

    func withRemotePayload(_ payload: Any) -> TestNodeBuilder {
        self.remotePayload = AnyCodable(payload)
        return self
    }

    func withRemoteAsync(_ async: Bool) -> TestNodeBuilder {
        self.remoteAsync = async
        return self
    }

    func next(_ nodes: String...) -> TestNodeBuilder {
        return withNext(nodes)
    }
}