import Foundation

/// Internal journey event tracking system
/// These events flow through the standard EventService for full observability
public class JourneyEvents {
    
    // MARK: - Event Names
    
    /// Journey lifecycle events
    public static let journeyStarted = "$journey_started"
    public static let journeyPaused = "$journey_paused"
    public static let journeyResumed = "$journey_resumed"
    public static let journeyErrored = "$journey_errored"
    public static let journeyGoalMet = "$journey_goal_met"
    public static let journeyExited = "$journey_exited"
    
    /// Node execution events
    public static let nodeExecuted = "$journey_node_executed"
    public static let nodeBranchTaken = "$node_branch_taken"
    public static let nodeRandomBranchAssigned = "$node_random_branch_assigned"
    public static let nodeWaitStarted = "$node_wait_started"
    public static let nodeWaitCompleted = "$node_wait_completed"
    public static let nodeErrored = "$node_errored"
    
    /// Flow events
    public static let flowShown = "$flow_shown"
    public static let flowDismissed = "$flow_dismissed"
    public static let flowPurchased = "$flow_purchased"
    public static let flowTimedOut = "$flow_timed_out"
    public static let flowErrored = "$flow_errored"
    
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
    
    /// Build properties for journey.paused event
    public static func journeyPausedProperties(
        journey: Journey,
        nodeId: String,
        resumeAt: Date?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "node_id": nodeId
        ]

        if let resumeAt = resumeAt {
            properties["resume_at"] = resumeAt.timeIntervalSince1970
        }

        return properties
    }

    /// Build properties for journey.resumed event
    public static func journeyResumedProperties(
        journey: Journey,
        nodeId: String?,
        resumeReason: String
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "resume_reason": resumeReason
        ]

        if let nodeId = nodeId {
            properties["node_id"] = nodeId
        }

        return properties
    }

    /// Build properties for journey.errored event
    public static func journeyErroredProperties(
        journey: Journey,
        nodeId: String?,
        errorMessage: String?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId
        ]

        if let nodeId = nodeId {
            properties["node_id"] = nodeId
        }

        if let errorMessage = errorMessage {
            properties["error_message"] = errorMessage
        }

        return properties
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
    
    /// Build base properties for flow events
    private static func flowBaseProperties(
        flowId: String,
        journey: Journey
    ) -> [String: Any] {
        return [
            "flow_id": flowId,
            "journey_id": journey.id,
            "campaign_id": journey.campaignId
        ]
    }

    /// Build properties for flow.dismissed event
    public static func flowDismissedProperties(
        flowId: String,
        journey: Journey
    ) -> [String: Any] {
        return flowBaseProperties(flowId: flowId, journey: journey)
    }

    /// Build properties for flow.purchased event
    public static func flowPurchasedProperties(
        flowId: String,
        journey: Journey,
        productId: String? = nil
    ) -> [String: Any] {
        var properties = flowBaseProperties(flowId: flowId, journey: journey)
        if let productId = productId {
            properties["product_id"] = productId
        }
        return properties
    }

    /// Build properties for flow.timed_out event
    public static func flowTimedOutProperties(
        flowId: String,
        journey: Journey
    ) -> [String: Any] {
        return flowBaseProperties(flowId: flowId, journey: journey)
    }

    /// Build properties for flow.errored event
    public static func flowErroredProperties(
        flowId: String,
        journey: Journey,
        errorMessage: String? = nil
    ) -> [String: Any] {
        var properties = flowBaseProperties(flowId: flowId, journey: journey)
        if let errorMessage = errorMessage {
            properties["error_message"] = errorMessage
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

