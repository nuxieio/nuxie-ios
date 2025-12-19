import Foundation

/// Base protocol for all workflow nodes
public protocol WorkflowNode: Codable {
    var id: String { get }
    var type: NodeType { get }
    var next: [String] { get }
}

/// Types of nodes in a journey workflow
public enum NodeType: String, Codable {
    // Trigger nodes (not part of workflow, handled by campaign trigger)
    case eventTrigger = "event_trigger"
    case segmentTrigger = "segment_trigger"

    // Action nodes
    case showFlow = "show_flow"
    case showPaywall = "show_paywall"
    case updateCustomer = "update_customer"
    case sendEvent = "send_event"
    case callDelegate = "call_delegate"

    // Delay nodes
    case timeDelay = "time_delay"
    case timeWindow = "time_window"
    case waitUntil = "wait_until"

    // Branch nodes
    case branch = "branch"
    case multiBranch = "multi_branch"
    case randomBranch = "random_branch"

    // Control nodes
    case exit = "exit"
}

// MARK: - Experiment Types (A/B Testing)

/// A single variant in an A/B test experiment
public struct ExperimentVariant: Codable {
    public let id: String
    public let flowId: String? // nil = holdout (control group that shows nothing)
    public let percentage: Double // 0-100, all variants must sum to 100
    public let name: String? // Display name (e.g., "Control", "Variant A")

    public init(id: String, flowId: String?, percentage: Double, name: String? = nil) {
        self.id = id
        self.flowId = flowId
        self.percentage = percentage
        self.name = name
    }
}

/// Configuration for an A/B test experiment on a show_flow node
public struct ExperimentConfig: Codable {
    public let id: String // Unique experiment identifier
    public let name: String? // Display name for the experiment
    public let variants: [ExperimentVariant] // At least 2 variants (control + variation)

    public init(id: String, name: String? = nil, variants: [ExperimentVariant]) {
        self.id = id
        self.name = name
        self.variants = variants
    }
}

// MARK: - Phase 1 Node Implementations (MVP)

/// Show a flow/paywall to the user
public struct ShowFlowNode: WorkflowNode {
    public let id: String
    public let type = NodeType.showFlow
    public let next: [String]
    public let data: ShowFlowData

    public struct ShowFlowData: Codable {
        // Single flow mode
        public let flowId: String?
        // Experiment mode (A/B testing)
        public let experiment: ExperimentConfig?

        public init(flowId: String? = nil, experiment: ExperimentConfig? = nil) {
            self.flowId = flowId
            self.experiment = experiment
        }
    }
}

/// Show a paywall to the user (emits paywall-specific events)
public struct ShowPaywallNode: WorkflowNode {
    public let id: String
    public let type = NodeType.showPaywall
    public let next: [String]
    public let data: ShowPaywallData

    public struct ShowPaywallData: Codable {
        // Single flow mode
        public let flowId: String?
        // Experiment mode (A/B testing)
        public let experiment: ExperimentConfig?

        public init(flowId: String? = nil, experiment: ExperimentConfig? = nil) {
            self.flowId = flowId
            self.experiment = experiment
        }
    }
}

/// Delay execution for a specified duration
public struct TimeDelayNode: WorkflowNode {
    public let id: String
    public let type = NodeType.timeDelay
    public let next: [String]
    public let data: TimeDelayData
    
    public struct TimeDelayData: Codable {
        public let duration: TimeInterval // Duration in seconds
    }
}

/// Exit the journey
public struct ExitNode: WorkflowNode {
    public let id: String
    public let type = NodeType.exit
    public let next: [String] // Always empty for exit nodes
    public let data: ExitData?
    
    public struct ExitData: Codable {
        public let reason: String?
    }
}

// MARK: - Phase 3 Node Implementations (Advanced Timing)

/// Execute only during specific time windows
public struct TimeWindowNode: WorkflowNode {
    public let id: String
    public let type = NodeType.timeWindow
    public let next: [String]
    public let data: TimeWindowData

    public struct TimeWindowData: Codable {
        /// Start time in "HH:mm" format (24-hour), e.g., "09:00"
        public let startTime: String
        /// End time in "HH:mm" format (24-hour), e.g., "17:00"
        public let endTime: String
        /// IANA timezone identifier (e.g., "America/New_York", "UTC") or nil for device local time
        public let timezone: String?
        /// Days of week to execute (iOS Calendar weekday format)
        /// 1 = Sunday, 2 = Monday, 3 = Tuesday, 4 = Wednesday, 5 = Thursday, 6 = Friday, 7 = Saturday
        /// Example: [2,3,4,5,6] = Mon-Fri (business days)
        /// nil or empty = all days
        public let daysOfWeek: [Int]?
    }
}

/// Wait until conditions are met with multiple paths
public struct WaitUntilNode: WorkflowNode {
    public let id: String
    public let type = NodeType.waitUntil
    public let next: [String] // Not used, paths defined in data
    public let data: WaitUntilData
    
    public struct WaitUntilData: Codable {
        public let paths: [WaitPath]
        
        public struct WaitPath: Codable {
            public let id: String
            public let condition: IREnvelope // IR expression to evaluate
            public let maxTime: TimeInterval? // Timeout in seconds
            public let next: String // Node to go to when conditions met
        }
    }
}

// MARK: - Phase 2 Node Implementations (Branching & Actions)

/// Branch into two paths based on a condition
public struct BranchNode: WorkflowNode {
    public let id: String
    public let type = NodeType.branch
    public let next: [String] // [truePath, falsePath]
    public let data: BranchData
    
    public struct BranchData: Codable {
        public let condition: IREnvelope // IR expression to evaluate
    }
}

/// Branch into multiple paths based on conditions
/// 
/// IMPORTANT INVARIANT: The `next` array must have exactly `conditions.count + 1` elements:
/// - Indices [0..<conditions.count] map to the corresponding condition paths
/// - The LAST element (next.last) is the default path taken when no conditions match
/// - In error scenarios, the executor will also use next.last as the fallback path
///
/// Example: For 2 conditions, next should be [cond0Path, cond1Path, defaultPath]
public struct MultiBranchNode: WorkflowNode {
    public let id: String
    public let type = NodeType.multiBranch
    public let next: [String] // Each index maps to corresponding condition, last one is default path
    public let data: MultiBranchData
    
    public struct MultiBranchData: Codable {
        public let conditions: [IREnvelope] // IR expressions to evaluate in order
    }
}

/// Update customer attributes
public struct UpdateCustomerNode: WorkflowNode {
    public let id: String
    public let type = NodeType.updateCustomer
    public let next: [String]
    public let data: UpdateCustomerData
    
    public struct UpdateCustomerData: Codable {
        public let attributes: [String: AnyCodable] // Attributes to set/update
    }
}

/// Send a custom event
public struct SendEventNode: WorkflowNode {
    public let id: String
    public let type = NodeType.sendEvent
    public let next: [String]
    public let data: SendEventData
    
    public struct SendEventData: Codable {
        public let eventName: String
        public let properties: [String: AnyCodable]?
    }
}

// MARK: - Phase 4 Node Implementations (Testing & Experimentation)

/// Random split for A/B testing
public struct RandomBranchNode: WorkflowNode {
    public let id: String
    public let type = NodeType.randomBranch
    public let next: [String] // Each index maps to corresponding branch
    public let data: RandomBranchData
    
    public struct RandomBranchData: Codable {
        public let branches: [RandomBranch]
        
        public struct RandomBranch: Codable {
            public let percentage: Double // 0-100, must sum to 100 across all branches
            public let name: String? // Optional name for this cohort
        }
    }
}

/// Call delegate for custom app integration
public struct CallDelegateNode: WorkflowNode {
    public let id: String
    public let type = NodeType.callDelegate
    public let next: [String]
    public let data: CallDelegateData
    
    public struct CallDelegateData: Codable {
        public let message: String
        public let payload: AnyCodable?
    }
}

// MARK: - Type-erased container for decoding

/// Container for any workflow node type
public struct AnyWorkflowNode: Codable {
    public let node: WorkflowNode
    
    public init(_ node: WorkflowNode) {
        self.node = node
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, type, next, data
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "show_flow":
            self.node = try ShowFlowNode(from: decoder)
        case "show_paywall":
            self.node = try ShowPaywallNode(from: decoder)
        case "time_delay":
            self.node = try TimeDelayNode(from: decoder)
        case "exit":
            self.node = try ExitNode(from: decoder)
        case "branch":
            self.node = try BranchNode(from: decoder)
        case "multi_branch":
            self.node = try MultiBranchNode(from: decoder)
        case "update_customer":
            self.node = try UpdateCustomerNode(from: decoder)
        case "send_event":
            self.node = try SendEventNode(from: decoder)
        case "time_window":
            self.node = try TimeWindowNode(from: decoder)
        case "wait_until":
            self.node = try WaitUntilNode(from: decoder)
        case "random_branch":
            self.node = try RandomBranchNode(from: decoder)
        case "call_delegate":
            self.node = try CallDelegateNode(from: decoder)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown node type: \(type)"
            )
        }
    }
        
    private enum ServerNodeKeys: String, CodingKey {
        case id, type, next, data
    }
    
    public func encode(to encoder: Encoder) throws {
        try node.encode(to: encoder)
    }
}

// MARK: - Helper Extensions

extension TimeInterval {
    /// Common time intervals for convenience
    static let oneMinute: TimeInterval = 60
    static let oneHour: TimeInterval = 3600
    static let oneDay: TimeInterval = 86400
    static let oneWeek: TimeInterval = 604800
}
