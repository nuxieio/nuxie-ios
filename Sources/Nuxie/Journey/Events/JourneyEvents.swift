import Foundation

/// Internal journey event tracking system
/// These events flow through the standard EventService for full observability
public class JourneyEvents {
    
    // MARK: - Event Names
    
    /// Journey lifecycle events
    public static let journeyStarted = "$journey_started"
    public static let journeyCompleted = "$journey_completed"
    public static let journeyPaused = "$journey_paused"
    public static let journeyResumed = "$journey_resumed"
    public static let journeyErrored = "$journey_errored"
    public static let journeyGoalMet = "$journey_goal_met"
    public static let journeyExited = "$journey_exited"
    
    /// Node execution events
    public static let nodeExecuted = "$node_executed"
    public static let nodeBranchTaken = "$node_branch_taken"
    public static let nodeRandomBranchAssigned = "$node_random_branch_assigned"
    public static let nodeWaitStarted = "$node_wait_started"
    public static let nodeWaitCompleted = "$node_wait_completed"
    public static let nodeErrored = "$node_errored"
    
    /// Flow events
    public static let flowShown = "$flow_shown"
    public static let flowCompleted = "$flow_completed"
    public static let flowDismissed = "$flow_dismissed"
    
    /// Customer events
    public static let customerUpdated = "$customer_updated"
    public static let eventSent = "$event_sent"
    
    /// Delegate events
    public static let delegateCalled = "$delegate_called"

    /// Experiment events (A/B testing)
    public static let experimentVariantAssigned = "$experiment_variant_assigned"
    
    // MARK: - Event Property Builders
    
    /// Build properties for journey.started event
    public static func journeyStartedProperties(
        journey: Journey,
        campaign: Campaign,
        triggerEvent: NuxieEvent? = nil
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": campaign.id,
            "campaign_name": campaign.name,
            "entry_node_id": campaign.entryNodeId ?? ""
        ]
        
        // Add trigger-specific properties
        switch campaign.trigger {
        case .event(let config):
            properties["trigger_type"] = "event"
            properties["trigger_event_name"] = config.eventName
            if let triggerEvent = triggerEvent {
                properties["trigger_event_properties"] = triggerEvent.properties
            }
        case .segment(_):
            properties["trigger_type"] = "segment"
            properties["trigger_segment"] = true
        }
        
        return properties
    }
    
    /// Build properties for journey.completed event
    public static func journeyCompletedProperties(
        journey: Journey,
        campaign: Campaign,
        exitReason: JourneyExitReason,
        nodesExecuted: Int = 0
    ) -> [String: Any] {
        let duration = journey.completedAt?.timeIntervalSince(journey.startedAt) ?? 0
        
        return [
            "journey_id": journey.id,
            "campaign_id": campaign.id,
            "exit_reason": exitReason.rawValue,
            "duration_seconds": Int(duration),
            "nodes_executed": nodesExecuted
        ]
    }
    
    /// Build properties for node.executed event
    public static func nodeExecutedProperties(
        journey: Journey,
        node: any WorkflowNode,
        result: NodeExecutionResult
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "node_id": node.id,
            "node_type": node.type.rawValue
        ]
        
        // Add result details
        switch result {
        case .continue(let nextNodes):
            properties["result"] = "continue"
            properties["next_nodes"] = nextNodes
        case .async(let deadline):
            properties["result"] = "async"
            if let deadline = deadline {
                properties["resume_at"] = deadline.timeIntervalSince1970
            }
        case .skip(let nextNode):
            properties["result"] = "skip"
            if let nextNode = nextNode {
                properties["skip_to"] = nextNode
            }
        case .complete(let reason):
            properties["result"] = "complete"
            properties["exit_reason"] = reason.rawValue
        }
        
        return properties
    }
    
    /// Build properties for node.branch_taken event
    public static func branchTakenProperties(
        journey: Journey,
        nodeId: String,
        branchPath: String,
        conditionResult: Bool
    ) -> [String: Any] {
        return [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "node_id": nodeId,
            "branch_path": branchPath,
            "condition_result": conditionResult
        ]
    }
    
    /// Build properties for node.random_branch_assigned event
    public static func randomBranchAssignedProperties(
        journey: Journey,
        nodeId: String,
        cohortName: String?,
        cohortValue: Double
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "node_id": nodeId,
            "cohort_value": cohortValue
        ]
        
        if let cohortName = cohortName {
            properties["cohort_name"] = cohortName
        }
        
        return properties
    }
    
    /// Build properties for node.wait_started event
    public static func waitStartedProperties(
        journey: Journey,
        nodeId: String,
        pathCount: Int,
        timeoutSeconds: TimeInterval?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "node_id": nodeId,
            "wait_paths": pathCount
        ]
        
        if let timeout = timeoutSeconds {
            properties["timeout_seconds"] = Int(timeout)
        }
        
        return properties
    }
    
    /// Build properties for node.wait_completed event
    public static func waitCompletedProperties(
        journey: Journey,
        nodeId: String,
        matchedPath: String,
        waitDurationSeconds: TimeInterval
    ) -> [String: Any] {
        return [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "node_id": nodeId,
            "matched_path": matchedPath,
            "wait_duration_seconds": Int(waitDurationSeconds)
        ]
    }
    
    /// Build properties for flow.shown event
    public static func flowShownProperties(
        journey: Journey,
        nodeId: String,
        flowId: String
    ) -> [String: Any] {
        return [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "node_id": nodeId,
            "flow_id": flowId
        ]
    }
    
    /// Build properties for flow.completed event
    public static func flowCompletedProperties(
        flowId: String,
        journey: Journey,
        completionType: String,
        productsShown: [String]? = nil
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "flow_id": flowId,
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "completion_type": completionType
        ]
        
        if let products = productsShown {
            properties["products_shown"] = products
        }
        
        return properties
    }
    
    /// Build properties for customer.updated event
    public static func customerUpdatedProperties(
        journey: Journey,
        nodeId: String,
        attributesUpdated: [String]
    ) -> [String: Any] {
        return [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "node_id": nodeId,
            "attributes_updated": attributesUpdated
        ]
    }
    
    /// Build properties for event.sent event
    public static func eventSentProperties(
        journey: Journey,
        nodeId: String,
        eventName: String,
        eventProperties: [String: Any]
    ) -> [String: Any] {
        return [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "node_id": nodeId,
            "event_name": eventName,
            "event_properties": eventProperties
        ]
    }
    
    /// Build properties for delegate.called event
    public static func delegateCalledProperties(
        journey: Journey,
        nodeId: String,
        message: String,
        payload: Any?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "node_id": nodeId,
            "message": message
        ]
        
        if let payload = payload {
            properties["payload"] = payload
        }
        
        return properties
    }
    
    /// Build properties for journey.exited event
    public static func journeyExitedProperties(
        journey: Journey,
        exitReason: JourneyExitReason,
        durationSeconds: TimeInterval? = nil
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "exit_reason": exitReason.rawValue,
            "had_conversion": journey.convertedAt != nil
        ]

        if let duration = durationSeconds {
            properties["duration_seconds"] = Int(duration)
        }

        if let convertedAt = journey.convertedAt {
            properties["converted_at"] = convertedAt.timeIntervalSince1970
        }

        if let goalKind = journey.goalSnapshot?.kind {
            properties["goal_kind"] = goalKind.rawValue
        }

        return properties
    }

    // MARK: - Experiment Event Properties

    /// Build properties for experiment_variant_assigned event
    /// Follows Customer.io's "Experiment Viewed" semantic event schema
    public static func experimentVariantAssignedProperties(
        journey: Journey,
        nodeId: String,
        experiment: ExperimentConfig,
        variant: ExperimentVariant
    ) -> [String: Any] {
        return [
            "experiment_id": experiment.id,
            "experiment_name": experiment.name ?? "",
            "variant_id": variant.id,
            "variant_name": variant.name ?? "",
            "flow_id": variant.flowId,
            "campaign_id": journey.campaignId,
            "journey_id": journey.id,
            "node_id": nodeId
        ]
    }
}

