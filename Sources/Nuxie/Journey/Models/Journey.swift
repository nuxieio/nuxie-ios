import Foundation
import FactoryKit

public struct FlowAfterDelaySnapshot: Codable, Equatable {
    public let interactionId: String
    public let screenId: String
    public let fireAt: Date
}

public enum FlowPendingActionKind: String, Codable {
    case delay
    case timeWindow
    case waitUntil
    case remoteRetry
}

public struct FlowPendingAction: Codable {
    public let interactionId: String
    public let screenId: String?
    public let componentId: String?
    public let actionIndex: Int
    public let kind: FlowPendingActionKind
    public let resumeAt: Date?
    public let condition: IREnvelope?
    public let maxTimeMs: Int?
    public let startedAt: Date
}

public struct FlowJourneyState: Codable {
    public var currentScreenId: String?
    public var navigationStack: [String]
    public var viewModelSnapshot: FlowViewModelSnapshot?
    public var pendingAfterDelay: [FlowAfterDelaySnapshot]
    public var pendingAction: FlowPendingAction?

    public init(
        currentScreenId: String? = nil,
        navigationStack: [String] = [],
        viewModelSnapshot: FlowViewModelSnapshot? = nil,
        pendingAfterDelay: [FlowAfterDelaySnapshot] = [],
        pendingAction: FlowPendingAction? = nil
    ) {
        self.currentScreenId = currentScreenId
        self.navigationStack = navigationStack
        self.viewModelSnapshot = viewModelSnapshot
        self.pendingAfterDelay = pendingAfterDelay
        self.pendingAction = pendingAction
    }
}

/// Represents a user's journey through a campaign flow
public class Journey: Codable {
    /// Unique journey identifier
    public let id: String

    /// Campaign this journey belongs to
    public let campaignId: String
    public let campaignVersionId: String
    public let flowId: String?

    /// User on this journey
    public let distinctId: String

    /// Current journey status
    public var status: JourneyStatus

    /// Journey-specific context variables (synced to server)
    public var context: [String: AnyCodable]

    /// Flow execution state for local resume
    public var flowState: FlowJourneyState

    /// Timestamps
    public let startedAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    /// Exit reason if journey ended
    public var exitReason: JourneyExitReason?

    /// For async waits, when to resume
    public var resumeAt: Date?

    /// Journey expiration (optional)
    public var expiresAt: Date?

    // MARK: - Goal and Conversion Tracking

    /// Snapshot of campaign goal at journey start
    public var goalSnapshot: GoalConfig?

    /// Snapshot of exit policy at journey start
    public var exitPolicySnapshot: ExitPolicy?

    /// Conversion window in seconds
    public var conversionWindow: TimeInterval

    /// Conversion anchor type
    public var conversionAnchor: ConversionAnchor

    /// Timestamp when conversion window starts
    public var conversionAnchorAt: Date

    /// Timestamp when goal was achieved (if applicable)
    public var convertedAt: Date?

    /// Initialize a new journey
    /// - Parameters:
    ///   - id: Optional journey ID (for cross-device resume). If nil, generates a new UUID v7.
    ///   - campaign: The campaign this journey belongs to
    ///   - distinctId: The user identifier
    public init(
        id: String? = nil,
        campaign: Campaign,
        distinctId: String
    ) {
        self.id = id ?? UUID.v7().uuidString
        self.campaignId = campaign.id
        self.campaignVersionId = campaign.versionId
        self.flowId = campaign.flowId
        self.distinctId = distinctId
        self.status = .pending
        self.context = [:]
        self.flowState = FlowJourneyState()

        let dateProvider = Container.shared.dateProvider()
        let now = dateProvider.now()
        self.startedAt = now
        self.updatedAt = now

        // Snapshot goal and exit policy
        self.goalSnapshot = campaign.goal
        self.exitPolicySnapshot = campaign.exitPolicy

        // Set conversion window (use default if not specified)
        if let window = campaign.goal?.window {
            self.conversionWindow = window
        } else {
            self.conversionWindow = ConversionWindowDefaults.defaultWindow(for: campaign.campaignType)
        }

        // Set conversion anchor (default to flow entry)
        self.conversionAnchor = ConversionAnchor(rawValue: campaign.conversionAnchor ?? "") ?? .workflowEntry
        self.conversionAnchorAt = now
    }

    /// Check if journey should be resumed
    public func shouldResume(at date: Date = Date()) -> Bool {
        if status == .paused, let resumeAt = resumeAt, date >= resumeAt {
            return true
        }
        return false
    }

    /// Check if journey has expired
    public func hasExpired(at date: Date = Date()) -> Bool {
        guard let expiresAt = expiresAt else {
            return false
        }
        return date >= expiresAt
    }

    /// Mark journey as complete
    public func complete(reason: JourneyExitReason) {
        let dateProvider = Container.shared.dateProvider()
        let now = dateProvider.now()
        self.status = .completed
        self.exitReason = reason
        self.completedAt = now
        self.updatedAt = now
    }

    /// Pause journey for async operation
    public func pause(until: Date?) {
        let dateProvider = Container.shared.dateProvider()
        self.status = .paused
        self.resumeAt = until
        self.updatedAt = dateProvider.now()
    }

    /// Resume journey from pause
    public func resume() {
        let dateProvider = Container.shared.dateProvider()
        self.status = .active
        self.resumeAt = nil
        self.updatedAt = dateProvider.now()
    }

    /// Cancel journey
    public func cancel() {
        let dateProvider = Container.shared.dateProvider()
        let now = dateProvider.now()
        self.status = .cancelled
        self.exitReason = .cancelled
        self.completedAt = now
        self.updatedAt = now
    }

    /// Update context value
    public func setContext(_ key: String, value: Any) {
        let dateProvider = Container.shared.dateProvider()
        self.context[key] = AnyCodable(value)
        self.updatedAt = dateProvider.now()
    }

    /// Get context value
    public func getContext(_ key: String) -> Any? {
        return context[key]?.value
    }
}

// MARK: - Journey Completion Record

/// Record of a completed journey (for frequency tracking)
public struct JourneyCompletionRecord: Codable {
    public let campaignId: String
    public let distinctId: String
    public let journeyId: String
    public let completedAt: Date
    public let exitReason: JourneyExitReason

    public init(journey: Journey) {
        let dateProvider = Container.shared.dateProvider()
        self.campaignId = journey.campaignId
        self.distinctId = journey.distinctId
        self.journeyId = journey.id
        self.completedAt = journey.completedAt ?? dateProvider.now()
        self.exitReason = journey.exitReason ?? .completed
    }

    /// Test-specific initializer for creating records with custom dates
    public init(campaignId: String, distinctId: String, journeyId: String, completedAt: Date, exitReason: JourneyExitReason) {
        self.campaignId = campaignId
        self.distinctId = distinctId
        self.journeyId = journeyId
        self.completedAt = completedAt
        self.exitReason = exitReason
    }
}
