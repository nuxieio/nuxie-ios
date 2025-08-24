import Foundation
@testable import Nuxie
import FactoryKit

/// Builder for creating test campaigns with fluent API
class TestCampaignBuilder {
    private var id: String
    private var name: String
    private var versionId: String
    private var versionNumber: Int
    private var frequencyPolicy: String
    private var frequencyInterval: TimeInterval?
    private var messageLimit: Int?
    private var publishedAt: String
    private var trigger: CampaignTrigger
    private var entryNodeId: String?
    private var workflow: Workflow
    private var goal: GoalConfig?
    private var exitPolicy: ExitPolicy?
    private var conversionAnchor: String?
    private var campaignType: String?
    
    init(id: String = "test-campaign") {
        self.id = id
        self.name = "Test Campaign"
        self.versionId = "v1"
        self.versionNumber = 1
        self.frequencyPolicy = "once"
        self.frequencyInterval = nil
        self.messageLimit = nil
        self.publishedAt = "2024-01-01T00:00:00Z"
        // Default to a simple segment trigger
        self.trigger = .segment(SegmentTriggerConfig(
            condition: IREnvelope(
                ir_version: 1,
                engine_min: nil,
                compiled_at: nil,
                expr: .bool(true)
            )
        ))
        self.entryNodeId = nil
        self.workflow = Workflow(nodes: [])
    }
    
    func withId(_ id: String) -> TestCampaignBuilder {
        self.id = id
        return self
    }
    
    func withName(_ name: String) -> TestCampaignBuilder {
        self.name = name
        return self
    }
    
    func withFrequencyPolicy(_ policy: String) -> TestCampaignBuilder {
        self.frequencyPolicy = policy
        return self
    }
    
    func withFrequencyInterval(_ interval: TimeInterval?) -> TestCampaignBuilder {
        self.frequencyInterval = interval
        return self
    }
    
    func withMessageLimit(_ limit: Int?) -> TestCampaignBuilder {
        self.messageLimit = limit
        return self
    }
    
    func withTrigger(_ trigger: CampaignTrigger) -> TestCampaignBuilder {
        self.trigger = trigger
        return self
    }
    
    // Convenience method for segment triggers with IR condition
    func withSegmentTrigger(condition: IREnvelope) -> TestCampaignBuilder {
        self.trigger = .segment(SegmentTriggerConfig(condition: condition))
        return self
    }
    
    // Helper for segment triggers by segment ID
    func withSegmentTrigger(segmentId: String) -> TestCampaignBuilder {
        self.trigger = .segment(SegmentTriggerConfig(
            condition: IREnvelope(
                ir_version: 1,
                engine_min: nil,
                compiled_at: nil,
                expr: .segment(op: "in", id: segmentId, within: nil)
            )
        ))
        return self
    }
    
    // Helper for simple segment membership condition
    func withSegmentTrigger(condition: String) -> TestCampaignBuilder {
        // For backward compatibility - interpret string as segment ID
        return withSegmentTrigger(segmentId: condition)
    }
    
    // Convenience method for event triggers
    func withEventTrigger(eventName: String, condition: IREnvelope? = nil) -> TestCampaignBuilder {
        self.trigger = .event(EventTriggerConfig(
            eventName: eventName,
            condition: condition
        ))
        return self
    }
    
    func withEntryNodeId(_ nodeId: String?) -> TestCampaignBuilder {
        self.entryNodeId = nodeId
        return self
    }
    
    func withWorkflow(_ workflow: Workflow) -> TestCampaignBuilder {
        self.workflow = workflow
        return self
    }
    
    func withNodes(_ nodes: [AnyWorkflowNode]) -> TestCampaignBuilder {
        self.workflow = Workflow(nodes: nodes)
        return self
    }
    
    func withGoal(_ goal: GoalConfig?) -> TestCampaignBuilder {
        self.goal = goal
        return self
    }
    
    func withEventGoal(eventName: String, window: TimeInterval? = nil) -> TestCampaignBuilder {
        self.goal = GoalConfig(
            kind: .event,
            eventName: eventName,
            window: window
        )
        return self
    }
    
    func withSegmentEnterGoal(segmentId: String, window: TimeInterval? = nil) -> TestCampaignBuilder {
        self.goal = GoalConfig(
            kind: .segmentEnter,
            segmentId: segmentId,
            window: window
        )
        return self
    }
    
    func withSegmentLeaveGoal(segmentId: String, window: TimeInterval? = nil) -> TestCampaignBuilder {
        self.goal = GoalConfig(
            kind: .segmentLeave,
            segmentId: segmentId,
            window: window
        )
        return self
    }
    
    func withAttributeGoal(expr: IREnvelope, window: TimeInterval? = nil) -> TestCampaignBuilder {
        self.goal = GoalConfig(
            kind: .attribute,
            attributeExpr: expr,
            window: window
        )
        return self
    }
    
    func withExitPolicy(_ policy: ExitPolicy?) -> TestCampaignBuilder {
        self.exitPolicy = policy
        return self
    }
    
    func withExitPolicy(_ mode: ExitPolicy.Mode) -> TestCampaignBuilder {
        self.exitPolicy = ExitPolicy(mode: mode)
        return self
    }
    
    func withConversionAnchor(_ anchor: String?) -> TestCampaignBuilder {
        self.conversionAnchor = anchor
        return self
    }
    
    func withCampaignType(_ type: String?) -> TestCampaignBuilder {
        self.campaignType = type
        return self
    }
    
    func build() -> Campaign {
        return Campaign(
            id: id,
            name: name,
            versionId: versionId,
            versionNumber: versionNumber,
            frequencyPolicy: frequencyPolicy,
            frequencyInterval: frequencyInterval,
            messageLimit: messageLimit,
            publishedAt: publishedAt,
            trigger: trigger,
            entryNodeId: entryNodeId,
            workflow: workflow,
            goal: goal,
            exitPolicy: exitPolicy,
            conversionAnchor: conversionAnchor,
            campaignType: campaignType
        )
    }
}