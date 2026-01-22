import Foundation

// MARK: - Flow Description

public struct FlowDescription: Codable {
    public let id: String
    public let version: String
    public let bundle: FlowBundleRef
    public let entryScreenId: String?
    public let entryActions: [InteractionAction]?
    public let screens: [FlowDescriptionScreen]
    public let interactions: FlowDescriptionInteractions
    public let viewModels: [ViewModel]
    public let viewModelInstances: [ViewModelInstance]?
    public let converters: [String: [String: AnyCodable]]?
    public let pathIndex: [String: FlowPathIndexEntry]?
}

public struct FlowBundleRef: Codable {
    public let url: String
    public let manifest: BuildManifest?
}

public struct FlowDescriptionScreen: Codable {
    public let id: String
    public let name: String?
    public let locale: String?
    public let route: String?
    public let defaultViewModelId: String?
    public let defaultInstanceId: String?
}

public struct FlowDescriptionInteractions: Codable {
    public let screens: [String: [Interaction]]
    public let components: [String: [Interaction]]?
}

public struct FlowPathIndexEntry: Codable {
    public let pathIds: [Int]
}

// MARK: - View Model Path References

public enum VmPathRef: Codable, Equatable {
    case path(String)
    case ids([Int])
    case raw(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case pathIds
    }

    private enum Kind: String, Codable {
        case path
        case ids
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let raw = try? single.decode(String.self) {
            self = .path(raw)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let kind = try? container.decode(Kind.self, forKey: .kind) {
            switch kind {
            case .path:
                let path = try container.decode(String.self, forKey: .path)
                self = .path(path)
                return
            case .ids:
                let pathIds = try container.decode([Int].self, forKey: .pathIds)
                self = .ids(pathIds)
                return
            }
        }

        if let path = try? container.decode(String.self, forKey: .path) {
            self = .path(path)
            return
        }

        self = .raw("unknown")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .path(let path):
            try container.encode(Kind.path, forKey: .kind)
            try container.encode(path, forKey: .path)
        case .ids(let pathIds):
            try container.encode(Kind.ids, forKey: .kind)
            try container.encode(pathIds, forKey: .pathIds)
        case .raw(let raw):
            try container.encode(Kind.path, forKey: .kind)
            try container.encode(raw, forKey: .path)
        }
    }

    public var normalizedPath: String {
        switch self {
        case .path(let path):
            return path
        case .ids(let ids):
            return "ids:\(ids.map(String.init).joined(separator: "."))"
        case .raw(let raw):
            return raw
        }
    }
}

// MARK: - Interaction Models

public struct Interaction: Codable {
    public let id: String
    public let trigger: InteractionTrigger
    public let actions: [InteractionAction]
    public let enabled: Bool?
}

public enum InteractionTrigger: Codable {
    case tap
    case longPress(minMs: Int?)
    case hover
    case press
    case drag(direction: DragDirection?, threshold: Double?)
    case screenShown
    case screenDismissed(method: String?)
    case afterDelay(delayMs: Int)
    case event(eventName: String, filter: IREnvelope?)
    case manual(label: String?)
    case viewModelChanged(path: VmPathRef, debounceMs: Int?)
    case unknown(type: String, payload: [String: AnyCodable]?)

    public enum DragDirection: String, Codable {
        case left
        case right
        case up
        case down
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case minMs
        case direction
        case threshold
        case method
        case delayMs
        case eventName
        case filter
        case label
        case path
        case debounceMs
    }

    private enum TriggerType: String, Codable {
        case tap
        case longPress = "long_press"
        case hover
        case press
        case drag
        case screenShown = "screen_shown"
        case screenDismissed = "screen_dismissed"
        case afterDelay = "after_delay"
        case event
        case manual
        case viewModelChanged = "view_model_changed"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeValue = (try? container.decode(TriggerType.self, forKey: .type))
        switch typeValue {
        case .tap:
            self = .tap
        case .longPress:
            self = .longPress(minMs: try container.decodeIfPresent(Int.self, forKey: .minMs))
        case .hover:
            self = .hover
        case .press:
            self = .press
        case .drag:
            let direction = try container.decodeIfPresent(DragDirection.self, forKey: .direction)
            let threshold = try container.decodeIfPresent(Double.self, forKey: .threshold)
            self = .drag(direction: direction, threshold: threshold)
        case .screenShown:
            self = .screenShown
        case .screenDismissed:
            self = .screenDismissed(method: try container.decodeIfPresent(String.self, forKey: .method))
        case .afterDelay:
            let delayMs = (try? container.decode(Int.self, forKey: .delayMs))
                ?? Int(try container.decode(Double.self, forKey: .delayMs))
            self = .afterDelay(delayMs: delayMs)
        case .event:
            let eventName = try container.decode(String.self, forKey: .eventName)
            let filter = try container.decodeIfPresent(IREnvelope.self, forKey: .filter)
            self = .event(eventName: eventName, filter: filter)
        case .manual:
            self = .manual(label: try container.decodeIfPresent(String.self, forKey: .label))
        case .viewModelChanged:
            let path = (try? container.decode(VmPathRef.self, forKey: .path)) ?? .raw("")
            let debounceMs = try container.decodeIfPresent(Int.self, forKey: .debounceMs)
            self = .viewModelChanged(path: path, debounceMs: debounceMs)
        case .none:
            let rawType = (try? container.decode(String.self, forKey: .type)) ?? "unknown"
            var payload: [String: AnyCodable] = [:]
            for key in container.allKeys {
                if key == .type { continue }
                payload[key.stringValue] = (try? container.decode(AnyCodable.self, forKey: key)) ?? AnyCodable(nil)
            }
            self = .unknown(type: rawType, payload: payload)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tap:
            try container.encode(TriggerType.tap, forKey: .type)
        case .longPress(let minMs):
            try container.encode(TriggerType.longPress, forKey: .type)
            try container.encodeIfPresent(minMs, forKey: .minMs)
        case .hover:
            try container.encode(TriggerType.hover, forKey: .type)
        case .press:
            try container.encode(TriggerType.press, forKey: .type)
        case .drag(let direction, let threshold):
            try container.encode(TriggerType.drag, forKey: .type)
            try container.encodeIfPresent(direction, forKey: .direction)
            try container.encodeIfPresent(threshold, forKey: .threshold)
        case .screenShown:
            try container.encode(TriggerType.screenShown, forKey: .type)
        case .screenDismissed(let method):
            try container.encode(TriggerType.screenDismissed, forKey: .type)
            try container.encodeIfPresent(method, forKey: .method)
        case .afterDelay(let delayMs):
            try container.encode(TriggerType.afterDelay, forKey: .type)
            try container.encode(delayMs, forKey: .delayMs)
        case .event(let eventName, let filter):
            try container.encode(TriggerType.event, forKey: .type)
            try container.encode(eventName, forKey: .eventName)
            try container.encodeIfPresent(filter, forKey: .filter)
        case .manual(let label):
            try container.encode(TriggerType.manual, forKey: .type)
            try container.encodeIfPresent(label, forKey: .label)
        case .viewModelChanged(let path, let debounceMs):
            try container.encode(TriggerType.viewModelChanged, forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(debounceMs, forKey: .debounceMs)
        case .unknown(let type, let payload):
            try container.encode(type, forKey: .type)
            if let payload {
                for (key, value) in payload {
                    if let codingKey = CodingKeys(rawValue: key) {
                        try container.encode(AnyCodable(value.value), forKey: codingKey)
                    }
                }
            }
        }
    }
}

public enum InteractionAction: Codable {
    case navigate(NavigateAction)
    case back(BackAction)
    case delay(DelayAction)
    case timeWindow(TimeWindowAction)
    case waitUntil(WaitUntilAction)
    case condition(ConditionAction)
    case experiment(ExperimentAction)
    case sendEvent(SendEventAction)
    case updateCustomer(UpdateCustomerAction)
    case callDelegate(CallDelegateAction)
    case remote(RemoteAction)
    case setViewModel(SetViewModelAction)
    case fireTrigger(FireTriggerAction)
    case listInsert(ListInsertAction)
    case listRemove(ListRemoveAction)
    case listSwap(ListSwapAction)
    case exit(ExitAction)
    case unknown(type: String, payload: [String: AnyCodable])

    private enum CodingKeys: String, CodingKey {
        case type
    }

    private enum ActionType: String, Codable {
        case navigate
        case back
        case delay
        case timeWindow = "time_window"
        case waitUntil = "wait_until"
        case condition
        case experiment
        case sendEvent = "send_event"
        case updateCustomer = "update_customer"
        case callDelegate = "call_delegate"
        case remote
        case setViewModel = "set_view_model"
        case fireTrigger = "fire_trigger"
        case listInsert = "list_insert"
        case listRemove = "list_remove"
        case listSwap = "list_swap"
        case exit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeValue = (try? container.decode(ActionType.self, forKey: .type))
        switch typeValue {
        case .navigate:
            self = .navigate(try NavigateAction(from: decoder))
        case .back:
            self = .back(try BackAction(from: decoder))
        case .delay:
            self = .delay(try DelayAction(from: decoder))
        case .timeWindow:
            self = .timeWindow(try TimeWindowAction(from: decoder))
        case .waitUntil:
            self = .waitUntil(try WaitUntilAction(from: decoder))
        case .condition:
            self = .condition(try ConditionAction(from: decoder))
        case .experiment:
            self = .experiment(try ExperimentAction(from: decoder))
        case .sendEvent:
            self = .sendEvent(try SendEventAction(from: decoder))
        case .updateCustomer:
            self = .updateCustomer(try UpdateCustomerAction(from: decoder))
        case .callDelegate:
            self = .callDelegate(try CallDelegateAction(from: decoder))
        case .remote:
            self = .remote(try RemoteAction(from: decoder))
        case .setViewModel:
            self = .setViewModel(try SetViewModelAction(from: decoder))
        case .fireTrigger:
            self = .fireTrigger(try FireTriggerAction(from: decoder))
        case .listInsert:
            self = .listInsert(try ListInsertAction(from: decoder))
        case .listRemove:
            self = .listRemove(try ListRemoveAction(from: decoder))
        case .listSwap:
            self = .listSwap(try ListSwapAction(from: decoder))
        case .exit:
            self = .exit(try ExitAction(from: decoder))
        case .none:
            let rawType = (try? container.decode(String.self, forKey: .type)) ?? "unknown"
            let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
            var payload: [String: AnyCodable] = [:]
            for key in dynamic.allKeys where key.stringValue != "type" {
                payload[key.stringValue] = (try? dynamic.decode(AnyCodable.self, forKey: key)) ?? AnyCodable(nil)
            }
            self = .unknown(type: rawType, payload: payload)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .navigate(let action):
            try action.encode(to: encoder)
        case .back(let action):
            try action.encode(to: encoder)
        case .delay(let action):
            try action.encode(to: encoder)
        case .timeWindow(let action):
            try action.encode(to: encoder)
        case .waitUntil(let action):
            try action.encode(to: encoder)
        case .condition(let action):
            try action.encode(to: encoder)
        case .experiment(let action):
            try action.encode(to: encoder)
        case .sendEvent(let action):
            try action.encode(to: encoder)
        case .updateCustomer(let action):
            try action.encode(to: encoder)
        case .callDelegate(let action):
            try action.encode(to: encoder)
        case .remote(let action):
            try action.encode(to: encoder)
        case .setViewModel(let action):
            try action.encode(to: encoder)
        case .fireTrigger(let action):
            try action.encode(to: encoder)
        case .listInsert(let action):
            try action.encode(to: encoder)
        case .listRemove(let action):
            try action.encode(to: encoder)
        case .listSwap(let action):
            try action.encode(to: encoder)
        case .exit(let action):
            try action.encode(to: encoder)
        case .unknown(let type, let payload):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            if !payload.isEmpty {
                var extra = encoder.container(keyedBy: DynamicCodingKey.self)
                for (key, value) in payload {
                    try extra.encode(value, forKey: DynamicCodingKey(stringValue: key))
                }
            }
        }
    }
}

public struct NavigateAction: Codable {
    public let type: String
    public let screenId: String
    public let transition: AnyCodable?

    public init(type: String = "navigate", screenId: String, transition: AnyCodable? = nil) {
        self.type = type
        self.screenId = screenId
        self.transition = transition
    }
}

public struct BackAction: Codable {
    public let type: String
    public let steps: Int?

    public init(type: String = "back", steps: Int? = nil) {
        self.type = type
        self.steps = steps
    }
}

public struct DelayAction: Codable {
    public let type: String
    public let durationMs: Int

    public init(type: String = "delay", durationMs: Int) {
        self.type = type
        self.durationMs = durationMs
    }
}

public struct TimeWindowAction: Codable {
    public let type: String
    public let startTime: String
    public let endTime: String
    public let timezone: String
    public let daysOfWeek: [Int]?

    public init(
        type: String = "time_window",
        startTime: String,
        endTime: String,
        timezone: String,
        daysOfWeek: [Int]? = nil
    ) {
        self.type = type
        self.startTime = startTime
        self.endTime = endTime
        self.timezone = timezone
        self.daysOfWeek = daysOfWeek
    }
}

public struct WaitUntilAction: Codable {
    public let type: String
    public let condition: IREnvelope?
    public let maxTimeMs: Int?

    public init(type: String = "wait_until", condition: IREnvelope?, maxTimeMs: Int? = nil) {
        self.type = type
        self.condition = condition
        self.maxTimeMs = maxTimeMs
    }
}

public struct ConditionAction: Codable {
    public let type: String
    public let branches: [ConditionBranch]
    public let defaultActions: [InteractionAction]?

    public init(type: String = "condition", branches: [ConditionBranch], defaultActions: [InteractionAction]? = nil) {
        self.type = type
        self.branches = branches
        self.defaultActions = defaultActions
    }
}

public struct ConditionBranch: Codable {
    public let id: String
    public let label: String?
    public let condition: IREnvelope?
    public let actions: [InteractionAction]
}

public struct ExperimentAction: Codable {
    public let type: String
    public let experimentId: String
    public let variants: [ExperimentVariant]

    public init(type: String = "experiment", experimentId: String, variants: [ExperimentVariant]) {
        self.type = type
        self.experimentId = experimentId
        self.variants = variants
    }
}

public struct ExperimentVariant: Codable {
    public let id: String
    public let name: String?
    public let percentage: Double
    public let actions: [InteractionAction]
}

public struct SendEventAction: Codable {
    public let type: String
    public let eventName: String
    public let properties: [String: AnyCodable]?

    public init(type: String = "send_event", eventName: String, properties: [String: AnyCodable]? = nil) {
        self.type = type
        self.eventName = eventName
        self.properties = properties
    }
}

public struct UpdateCustomerAction: Codable {
    public let type: String
    public let attributes: [String: AnyCodable]

    public init(type: String = "update_customer", attributes: [String: AnyCodable]) {
        self.type = type
        self.attributes = attributes
    }
}

public struct CallDelegateAction: Codable {
    public let type: String
    public let message: String
    public let payload: AnyCodable?

    public init(type: String = "call_delegate", message: String, payload: AnyCodable? = nil) {
        self.type = type
        self.message = message
        self.payload = payload
    }
}

public struct RemoteAction: Codable {
    public let type: String
    public let action: String
    public let payload: AnyCodable
    public let async: Bool?

    public init(type: String = "remote", action: String, payload: AnyCodable, async: Bool? = nil) {
        self.type = type
        self.action = action
        self.payload = payload
        self.async = async
    }
}

public struct SetViewModelAction: Codable {
    public let type: String
    public let path: VmPathRef
    public let value: AnyCodable

    public init(type: String = "set_view_model", path: VmPathRef, value: AnyCodable) {
        self.type = type
        self.path = path
        self.value = value
    }
}

public struct FireTriggerAction: Codable {
    public let type: String
    public let path: VmPathRef

    public init(type: String = "fire_trigger", path: VmPathRef) {
        self.type = type
        self.path = path
    }
}

public struct ListInsertAction: Codable {
    public let type: String
    public let path: VmPathRef
    public let index: Int?
    public let value: AnyCodable

    public init(type: String = "list_insert", path: VmPathRef, index: Int? = nil, value: AnyCodable) {
        self.type = type
        self.path = path
        self.index = index
        self.value = value
    }
}

public struct ListRemoveAction: Codable {
    public let type: String
    public let path: VmPathRef
    public let index: Int

    public init(type: String = "list_remove", path: VmPathRef, index: Int) {
        self.type = type
        self.path = path
        self.index = index
    }
}

public struct ListSwapAction: Codable {
    public let type: String
    public let path: VmPathRef
    public let indexA: Int
    public let indexB: Int

    public init(type: String = "list_swap", path: VmPathRef, indexA: Int, indexB: Int) {
        self.type = type
        self.path = path
        self.indexA = indexA
        self.indexB = indexB
    }
}

public struct ExitAction: Codable {
    public let type: String
    public let reason: String?

    public init(type: String = "exit", reason: String? = nil) {
        self.type = type
        self.reason = reason
    }
}

// MARK: - View Model Models

public struct ViewModel: Codable {
    public let id: String
    public let name: String
    public let properties: [String: ViewModelProperty]
}

public enum ViewModelPropertyType: String, Codable {
    case string
    case number
    case boolean
    case color
    case `enum`
    case list
    case object
    case image
    case product
    case trigger
    case viewModel = "viewModel"
}

public struct ViewModelProperty: Codable {
    public let type: ViewModelPropertyType
    public let propertyId: Int?
    public let defaultValue: AnyCodable?
    public let required: Bool?
    public let enumValues: [String]?
    public let itemType: ViewModelProperty?
    public let schema: [String: ViewModelProperty]?
    public let viewModelId: String?
    public let validation: ViewModelValidation?
}

public struct ViewModelValidation: Codable {
    public let min: Double?
    public let max: Double?
    public let minLength: Int?
    public let maxLength: Int?
    public let regex: String?
}

public struct ViewModelInstance: Codable {
    public let viewModelId: String
    public let instanceId: String
    public let name: String?
    public let values: [String: AnyCodable]
}

// MARK: - Dynamic Coding Key

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    init(stringValue: String) { self.stringValue = stringValue }
}
