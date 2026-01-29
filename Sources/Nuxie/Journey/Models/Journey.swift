import Foundation
import FactoryKit

/// Represents a user's journey through a campaign workflow
public class Journey: Codable {
    /// Unique journey identifier
    public let id: String
    
    /// Campaign this journey belongs to
    public let campaignId: String
    public let campaignVersionId: String
    public let campaignFrequencyPolicy: String
    
    /// User on this journey
    public let distinctId: String
    
    /// Current journey status
    public var status: JourneyStatus

    /// Active branches in this journey (supports concurrent execution)
    public var branches: [BranchState]

    /// Node IDs for branches waiting to be started
    public var pendingBranchStarts: [String]

    /// Current node being executed (first running branch for backward compatibility)
    public var currentNodeId: String? {
        get {
            // Return the first running branch's current node
            branches.first(where: { $0.status == .running })?.currentNodeId
        }
        set {
            // Update the first running branch, or create one if none exists
            if let index = branches.firstIndex(where: { $0.status == .running }) {
                branches[index].currentNodeId = newValue
            } else if let nodeId = newValue {
                // Create a new running branch
                branches.append(BranchState(currentNodeId: nodeId, status: .running))
            }
        }
    }

    /// Journey-specific context variables
    public var context: [String: AnyCodable]
    
    /// Timestamps
    public let startedAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    
    /// Exit reason if journey ended
    public var exitReason: JourneyExitReason?
    
    /// For async nodes, when to resume
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
        self.campaignFrequencyPolicy = campaign.frequencyPolicy
        self.distinctId = distinctId
        self.status = .pending
        self.pendingBranchStarts = []

        // Initialize with a single branch starting at the entry node
        if let entryNodeId = campaign.entryNodeId {
            self.branches = [BranchState(currentNodeId: entryNodeId, status: .running)]
        } else {
            self.branches = []
        }

        self.context = [:]

        LogDebug("[Journey] Initialized journey \(self.id) for campaign \(campaign.id) with entryNodeId: \(campaign.entryNodeId ?? "nil")")

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

        // Set conversion anchor (default to workflow_entry)
        self.conversionAnchor = ConversionAnchor(rawValue: campaign.conversionAnchor ?? "") ?? .workflowEntry
        self.conversionAnchorAt = now
    }
    
    /// Check if journey should be resumed (any branch ready to resume)
    public func shouldResume(at date: Date = Date()) -> Bool {
        // Check if any paused branch is ready to resume
        for branch in branches where branch.status == .paused {
            if let branchResumeAt = branch.resumeAt, date >= branchResumeAt {
                return true
            }
        }
        // Legacy fallback for journey-level resumeAt
        if status == .paused, let resumeAt = resumeAt, date >= resumeAt {
            return true
        }
        return false
    }

    /// Get branches that are ready to resume at a given time
    public func branchesReadyToResume(at date: Date = Date()) -> [BranchState] {
        return branches.filter { branch in
            guard branch.status == .paused, let branchResumeAt = branch.resumeAt else {
                return false
            }
            return date >= branchResumeAt
        }
    }

    /// Get the first running branch (for single-branch backward compatibility)
    public func firstRunningBranch() -> BranchState? {
        return branches.first(where: { $0.status == .running })
    }

    /// Get branch by ID
    public func branch(withId id: String) -> BranchState? {
        return branches.first(where: { $0.id == id })
    }

    /// Update a branch by ID
    public func updateBranch(_ branch: BranchState) {
        if let index = branches.firstIndex(where: { $0.id == branch.id }) {
            branches[index] = branch
        }
    }

    /// Check if journey has any active (running or paused) branches
    public func hasActiveBranches() -> Bool {
        return branches.contains(where: { $0.status == .running || $0.status == .paused })
    }

    /// Check if all branches are completed
    public func allBranchesCompleted() -> Bool {
        return branches.allSatisfy { $0.status == .completed } && pendingBranchStarts.isEmpty
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
        // Mark all branches as completed and clear pending
        for i in branches.indices {
            branches[i].status = .completed
            branches[i].currentNodeId = nil
        }
        self.pendingBranchStarts = []
    }
    
    /// Pause journey for async operation (legacy - pauses entire journey)
    public func pause(until: Date?) {
        let dateProvider = Container.shared.dateProvider()
        self.status = .paused
        self.resumeAt = until
        self.updatedAt = dateProvider.now()
    }

    /// Pause a specific branch
    public func pauseBranch(withId branchId: String, until: Date?) {
        let dateProvider = Container.shared.dateProvider()
        if let index = branches.firstIndex(where: { $0.id == branchId }) {
            branches[index].status = .paused
            branches[index].resumeAt = until
        }
        self.updatedAt = dateProvider.now()

        // Update journey status if all branches are paused
        if branches.allSatisfy({ $0.status == .paused || $0.status == .completed }) && pendingBranchStarts.isEmpty {
            self.status = .paused
            // Set journey resumeAt to earliest branch resumeAt
            self.resumeAt = branches.compactMap { $0.resumeAt }.min()
        }
    }

    /// Resume journey from pause (legacy)
    public func resume() {
        let dateProvider = Container.shared.dateProvider()
        self.status = .active
        self.resumeAt = nil
        self.updatedAt = dateProvider.now()
    }

    /// Resume a specific branch
    public func resumeBranch(withId branchId: String) {
        let dateProvider = Container.shared.dateProvider()
        if let index = branches.firstIndex(where: { $0.id == branchId }) {
            branches[index].status = .running
            branches[index].resumeAt = nil
        }
        self.status = .active
        self.updatedAt = dateProvider.now()
    }

    /// Mark a branch as completed (reached end of its path)
    public func completeBranch(withId branchId: String) {
        let dateProvider = Container.shared.dateProvider()
        if let index = branches.firstIndex(where: { $0.id == branchId }) {
            branches[index].status = .completed
            branches[index].currentNodeId = nil
        }
        self.updatedAt = dateProvider.now()
    }

    /// Start the next pending branch if any
    public func startNextPendingBranch() -> BranchState? {
        guard !pendingBranchStarts.isEmpty else { return nil }
        let dateProvider = Container.shared.dateProvider()
        let nodeId = pendingBranchStarts.removeFirst()
        let newBranch = BranchState(currentNodeId: nodeId, status: .running)
        branches.append(newBranch)
        self.updatedAt = dateProvider.now()
        return newBranch
    }

    /// Queue additional branch starts (for multi-output nodes)
    public func queueBranchStarts(_ nodeIds: [String]) {
        pendingBranchStarts.append(contentsOf: nodeIds)
    }
    
    /// Cancel journey
    public func cancel() {
        let dateProvider = Container.shared.dateProvider()
        let now = dateProvider.now()
        self.status = .cancelled
        self.exitReason = .cancelled
        self.completedAt = now
        self.updatedAt = now
        // Mark all branches as completed and clear pending
        for i in branches.indices {
            branches[i].status = .completed
            branches[i].currentNodeId = nil
        }
        self.pendingBranchStarts = []
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
