import Foundation

/// Internal journey event tracking system
/// These events flow through the standard EventService for observability
public class JourneyEvents {

    // MARK: - Event Names

    public static let journeyStarted = "$journey_started"
    public static let journeyPaused = "$journey_paused"
    public static let journeyResumed = "$journey_resumed"
    public static let journeyErrored = "$journey_errored"
    public static let journeyGoalMet = "$journey_goal_met"
    public static let journeyExited = "$journey_exited"
    public static let journeyAction = "$journey_action"

    public static let flowShown = "$flow_shown"
    public static let flowDismissed = "$flow_dismissed"
    public static let flowPurchased = "$flow_purchased"
    public static let flowTimedOut = "$flow_timed_out"
    public static let flowErrored = "$flow_errored"

    public static let customerUpdated = "$customer_updated"
    public static let eventSent = "$event_sent"
    public static let delegateCalled = "$delegate_called"
    public static let experimentVariantAssigned = "$experiment_variant_assigned"

    // MARK: - Properties Builders

    public static func journeyStartedProperties(
        journey: Journey,
        campaign: Campaign,
        triggerEvent: NuxieEvent? = nil,
        entryScreenId: String? = nil
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": campaign.id,
            "campaign_name": campaign.name,
            "flow_id": campaign.flowId as Any,
        ]

        if let entryScreenId {
            properties["entry_screen_id"] = entryScreenId
        }

        switch campaign.trigger {
        case .event(let config):
            properties["trigger_type"] = "event"
            properties["trigger_event_name"] = config.eventName
            if let triggerEvent {
                properties["trigger_event_properties"] = triggerEvent.properties
            }
        case .segment:
            properties["trigger_type"] = "segment"
            properties["trigger_segment"] = true
        }

        return properties
    }

    public static func journeyPausedProperties(
        journey: Journey,
        screenId: String?,
        resumeAt: Date?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
        ]

        if let screenId {
            properties["screen_id"] = screenId
        }
        if let resumeAt {
            properties["resume_at"] = resumeAt.timeIntervalSince1970
        }

        return properties
    }

    public static func journeyResumedProperties(
        journey: Journey,
        screenId: String?,
        resumeReason: String
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "resume_reason": resumeReason
        ]

        if let screenId {
            properties["screen_id"] = screenId
        }

        return properties
    }

    public static func journeyErroredProperties(
        journey: Journey,
        screenId: String?,
        errorMessage: String?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId
        ]

        if let screenId {
            properties["screen_id"] = screenId
        }

        if let errorMessage {
            properties["error_message"] = errorMessage
        }

        return properties
    }

    public static func journeyExitedProperties(
        journey: Journey,
        reason: JourneyExitReason,
        screenId: String?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "exit_reason": reason.rawValue
        ]

        if let screenId {
            properties["screen_id"] = screenId
        }

        return properties
    }

    public static func journeyActionProperties(
        journey: Journey,
        screenId: String?,
        interactionId: String?,
        actionType: String,
        error: String?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "action_type": actionType
        ]

        if let screenId {
            properties["screen_id"] = screenId
        }
        if let interactionId {
            properties["interaction_id"] = interactionId
        }
        if let error {
            properties["error_message"] = error
        }

        return properties
    }

    public static func flowShownProperties(flowId: String, journey: Journey) -> [String: Any] {
        return [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "flow_id": flowId
        ]
    }

    public static func flowDismissedProperties(flowId: String, journey: Journey) -> [String: Any] {
        return [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "flow_id": flowId
        ]
    }

    public static func flowPurchasedProperties(flowId: String, journey: Journey, productId: String?) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "flow_id": flowId
        ]
        if let productId {
            properties["product_id"] = productId
        }
        return properties
    }

    public static func flowTimedOutProperties(flowId: String, journey: Journey) -> [String: Any] {
        return [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "flow_id": flowId
        ]
    }

    public static func flowErroredProperties(flowId: String, journey: Journey, errorMessage: String?) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "flow_id": flowId
        ]
        if let errorMessage {
            properties["error_message"] = errorMessage
        }
        return properties
    }

    public static func customerUpdatedProperties(
        journey: Journey,
        screenId: String?,
        attributesUpdated: [String]
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "attributes_updated": attributesUpdated
        ]
        if let screenId {
            properties["screen_id"] = screenId
        }
        return properties
    }

    public static func eventSentProperties(
        journey: Journey,
        screenId: String?,
        eventName: String,
        eventProperties: [String: Any]
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "event_name": eventName,
            "event_properties": eventProperties
        ]
        if let screenId {
            properties["screen_id"] = screenId
        }
        return properties
    }

    public static func delegateCalledProperties(
        journey: Journey,
        screenId: String?,
        message: String,
        payload: Any?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "message": message
        ]
        if let screenId {
            properties["screen_id"] = screenId
        }
        if let payload {
            properties["payload"] = payload
        }
        return properties
    }

    public static func experimentVariantAssignedProperties(
        journey: Journey,
        experimentId: String,
        variantId: String,
        variantName: String?,
        variantIndex: Int?,
        flowId: String?
    ) -> [String: Any] {
        return [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "flow_id": flowId as Any,
            "experiment_id": experimentId,
            "variant_id": variantId,
            "variant_name": variantName ?? "",
            "variant_index": variantIndex ?? 0
        ]
    }
}
