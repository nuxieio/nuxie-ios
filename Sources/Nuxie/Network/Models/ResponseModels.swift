import Foundation

// MARK: - Batch Response

public struct BatchResponse: Codable {
    public let status: String
    public let processed: Int
    public let failed: Int
    public let total: Int
    public let errors: [BatchError]?
}

public struct BatchError: Codable {
    public let index: Int
    public let event: String
    public let error: String
}

// MARK: - Profile Response

public struct ProfileResponse: Codable {
    public let campaigns: [Campaign]
    public let segments: [Segment]
    public let userProperties: [String: AnyCodable]?
    /// Server-computed experiment variant assignments (experimentId -> assignment)
    public let experiments: [String: ExperimentAssignment]?
    /// Customer's feature access (from active subscriptions)
    public let features: [Feature]?
    /// Active journeys for cross-device resume (server-assisted journeys)
    public let journeys: [ActiveJourney]?

    public init(
        campaigns: [Campaign],
        segments: [Segment],
        userProperties: [String: AnyCodable]? = nil,
        experiments: [String: ExperimentAssignment]? = nil,
        features: [Feature]? = nil,
        journeys: [ActiveJourney]? = nil
    ) {
        self.campaigns = campaigns
        self.segments = segments
        self.userProperties = userProperties
        self.experiments = experiments
        self.features = features
        self.journeys = journeys
    }
}

/// Active journey for cross-device resume
public struct ActiveJourney: Codable {
    public let sessionId: String
    public let campaignId: String
    public let currentNodeId: String
    public let context: [String: AnyCodable]

    public init(
        sessionId: String,
        campaignId: String,
        currentNodeId: String,
        context: [String: AnyCodable]
    ) {
        self.sessionId = sessionId
        self.campaignId = campaignId
        self.currentNodeId = currentNodeId
        self.context = context
    }
}

// MARK: - Feature Models

/// The type of feature
public enum FeatureType: String, Codable, Sendable {
    case boolean
    case metered
    case creditSystem
}

/// Balance information for entity-based features (per-project limits, etc.)
public struct EntityBalance: Codable, Sendable {
    public let balance: Int
}

/// Feature access state returned from server
/// Represents what features a customer has access to based on their subscriptions
public struct Feature: Codable, Sendable {
    /// External feature ID
    public let id: String
    /// Feature type (boolean, metered, creditSystem)
    public let type: FeatureType
    /// Current balance (nil if unlimited or boolean)
    public let balance: Int?
    /// Whether this feature has unlimited access
    public let unlimited: Bool
    /// When the balance resets (Unix timestamp ms, nil if no reset)
    public let nextResetAt: Int?
    /// Reset interval (minute, hour, day, week, month, etc.)
    public let interval: String?
    /// Entity-based balances for per-entity limits (optional)
    public let entities: [String: EntityBalance]?
}

/// Pre-computed experiment variant assignment from server
public struct ExperimentAssignment: Codable {
    public let experimentId: String
    public let variantId: String
    public let flowId: String? // nil = holdout (control group that shows nothing)
}

// MARK: - Campaign Models

// MARK: - Trigger Models

public struct EventTriggerConfig: Codable {
    public let eventName: String
    public let condition: IREnvelope? // Optional IR condition for event properties
}

public struct SegmentTriggerConfig: Codable {
    public let condition: IREnvelope // Required IR condition for segment membership
}

public enum CampaignTrigger: Codable {
    case event(EventTriggerConfig)
    case segment(SegmentTriggerConfig)
    
    private enum CodingKeys: String, CodingKey {
        case type
        case config
    }
    
    private enum TriggerType: String, Codable {
        case event
        case segment
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(TriggerType.self, forKey: .type)
        
        switch type {
        case .event:
            let config = try container.decode(EventTriggerConfig.self, forKey: .config)
            self = .event(config)
        case .segment:
            let config = try container.decode(SegmentTriggerConfig.self, forKey: .config)
            self = .segment(config)
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .event(let config):
            try container.encode(TriggerType.event, forKey: .type)
            try container.encode(config, forKey: .config)
        case .segment(let config):
            try container.encode(TriggerType.segment, forKey: .type)
            try container.encode(config, forKey: .config)
        }
    }
}

// MARK: - Reentry Policy

public struct Window: Codable {
    public let amount: Int
    public let unit: WindowUnit
}

public enum WindowUnit: String, Codable {
    case minute
    case hour
    case day
    case week
}

public enum CampaignReentry: Codable {
    case oneTime
    case everyTime
    case oncePerWindow(Window)

    private enum CodingKeys: String, CodingKey {
        case type
        case window
    }

    private enum ReentryType: String, Codable {
        case oneTime = "one_time"
        case everyTime = "every_time"
        case oncePerWindow = "once_per_window"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ReentryType.self, forKey: .type)

        switch type {
        case .oneTime:
            self = .oneTime
        case .everyTime:
            self = .everyTime
        case .oncePerWindow:
            let window = try container.decode(Window.self, forKey: .window)
            self = .oncePerWindow(window)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .oneTime:
            try container.encode(ReentryType.oneTime, forKey: .type)
        case .everyTime:
            try container.encode(ReentryType.everyTime, forKey: .type)
        case .oncePerWindow(let window):
            try container.encode(ReentryType.oncePerWindow, forKey: .type)
            try container.encode(window, forKey: .window)
        }
    }
}

public struct Campaign: Codable {
    public let id: String
    public let name: String
    public let versionId: String
    public let versionNumber: Int
    public let versionName: String?
    public let reentry: CampaignReentry
    public let publishedAt: String
    
    // Trigger configuration (discriminated union)
    public let trigger: CampaignTrigger
    public let flowId: String?
    
    // Goal and exit configuration (optional for backward compatibility)
    public let goal: GoalConfig?
    public let exitPolicy: ExitPolicy?
    public let conversionAnchor: String? // Default: "workflow_entry"
    public let campaignType: String? // Used for default conversion windows
}

public struct Segment: Codable {
    public let id: String
    public let name: String
    public let condition: IREnvelope  // Compiled IR expression from backend
}

public struct BuildManifest: Codable, Equatable {
    public let totalFiles: Int
    public let totalSize: Int
    public let contentHash: String
    public let files: [BuildFile]
}

public struct BuildFile: Codable, Equatable, Hashable {
    public let path: String
    public let size: Int
    public let contentType: String
}

// MARK: - Event Response

public struct EventResponse: Codable {
    public let status: String
    public let payload: [String: AnyCodable]?
    public let customer: Customer?
    public let event: EventInfo?
    public let message: String?
    public let featuresMatched: Int?
    public let usage: Usage?

    // Journey-specific response fields (for $journey_start, $journey_node_executed, $journey_completed)
    public let journey: JourneyInfo?
    public let execution: ExecutionResult?

    public struct Customer: Codable {
        public let id: String
        public let properties: [String: AnyCodable]?
    }

    public struct EventInfo: Codable {
        public let id: String
        public let processed: Bool
    }

    public struct Usage: Codable {
        public let current: Double
        public let limit: Double?
        public let remaining: Double?
    }

    /// Journey state returned from server (for cross-device tracking)
    public struct JourneyInfo: Codable {
        public let sessionId: String?
        public let currentNodeId: String?
        public let status: String?  // "active" or "completed"
    }

    /// Execution result for remote nodes
    public struct ExecutionResult: Codable {
        public let success: Bool
        public let statusCode: Int?
        public let error: ExecutionError?
        public let contextUpdates: [String: AnyCodable]?

        public struct ExecutionError: Codable {
            public let message: String
            public let retryable: Bool
            public let retryAfter: Int?
        }
    }
}


// MARK: - Error Response

struct APIErrorResponse: Codable {
    let message: String
    let code: String?
    let details: [String: AnyCodable]?
}
