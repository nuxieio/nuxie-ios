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
    public let flows: [RemoteFlow]
    public let userProperties: [String: AnyCodable]?
    /// Server-computed experiment variant assignments (experimentId -> assignment)
    public let experimentAssignments: [String: ExperimentAssignment]?
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

public struct Campaign: Codable {
    public let id: String
    public let name: String
    public let versionId: String
    public let versionNumber: Int
    public let frequencyPolicy: String
    public let frequencyInterval: TimeInterval?
    public let messageLimit: Int?
    public let publishedAt: String
    
    // Trigger configuration (discriminated union)
    public let trigger: CampaignTrigger
    public let entryNodeId: String? // First node to execute after trigger
    
    // Workflow contains only action nodes
    public let workflow: Workflow
    
    // Goal and exit configuration (optional for backward compatibility)
    public let goal: GoalConfig?
    public let exitPolicy: ExitPolicy?
    public let conversionAnchor: String? // Default: "workflow_entry"
    public let campaignType: String? // Used for default conversion windows
}

public struct Workflow: Codable {
    public let nodes: [AnyWorkflowNode]
}



public struct Segment: Codable {
    public let id: String
    public let name: String
    public let condition: IREnvelope  // Compiled IR expression from backend
}

// RemoteFlow represents immutable flow data from the server
public struct RemoteFlow: Codable {
    public let id: String
    public let name: String
    public let url: String
    public let products: [RemoteFlowProduct]
    public let manifest: BuildManifest
}

public struct Frame: Codable {
    public let id: String
    public let name: String
    public let url: String
    public let products: [RemoteFlowProduct]
    public let manifest: BuildManifest?
}

public struct RemoteFlowProduct: Codable, Equatable {
    public let id: String
    public let extId: String
    public let name: String
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
    let status: String
    let payload: [String: AnyCodable]?
    let customer: Customer?
    let event: EventInfo?
    let message: String?
    let featuresMatched: Int?
    let usage: Usage?
    
    struct Customer: Codable {
        let id: String
        let properties: [String: AnyCodable]?
    }
    
    struct EventInfo: Codable {
        let id: String
        let processed: Bool
    }
    
    struct Usage: Codable {
        let current: Double
        let limit: Double?
        let remaining: Double?
    }
}


// MARK: - Error Response

struct APIErrorResponse: Codable {
    let message: String
    let code: String?
    let details: [String: AnyCodable]?
}
