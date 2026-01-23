import Foundation

// MARK: - Remote Flow

public struct RemoteFlow: Codable {
    public let id: String
    public let bundle: FlowBundleRef
    public let screens: [RemoteFlowScreen]
    public let interactions: [String: [Interaction]]
    public let viewModels: [ViewModel]
    public let viewModelInstances: [ViewModelInstance]?
    public let converters: [String: [String: AnyCodable]]?
}

public struct FlowBundleRef: Codable {
    public let url: String
    public let manifest: BuildManifest
}

public struct RemoteFlowScreen: Codable {
    public let id: String
    public let defaultViewModelId: String?
    public let defaultInstanceId: String?
}

public typealias RemoteFlowInteractions = [String: [Interaction]]

@available(*, deprecated, renamed: "RemoteFlow")
public typealias FlowDescription = RemoteFlow

@available(*, deprecated, renamed: "RemoteFlowScreen")
public typealias FlowDescriptionScreen = RemoteFlowScreen

@available(*, deprecated, renamed: "RemoteFlowInteractions")
public typealias FlowDescriptionInteractions = RemoteFlowInteractions

// MARK: - View Model Path References

public struct VmPathIds: Codable, Equatable {
    public let pathIds: [Int]
    public let isRelative: Bool?
    public let nameBased: Bool?

    public init(pathIds: [Int], isRelative: Bool? = nil, nameBased: Bool? = nil) {
        self.pathIds = pathIds
        self.isRelative = isRelative
        self.nameBased = nameBased
    }
}

public enum VmPathRef: Codable, Equatable {
    case ids(VmPathIds)

    private enum CodingKeys: String, CodingKey {
        case kind
        case pathIds
        case isRelative
        case nameBased
    }

    private enum Kind: String, Codable {
        case ids
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let kind = try? container.decode(Kind.self, forKey: .kind), kind == .ids {
            let pathIds = try container.decode([Int].self, forKey: .pathIds)
            let isRelative = try? container.decode(Bool.self, forKey: .isRelative)
            let nameBased = try? container.decode(Bool.self, forKey: .nameBased)
            self = .ids(VmPathIds(pathIds: pathIds, isRelative: isRelative, nameBased: nameBased))
            return
        }

        if let pathIds = try? container.decode([Int].self, forKey: .pathIds) {
            let isRelative = try? container.decode(Bool.self, forKey: .isRelative)
            let nameBased = try? container.decode(Bool.self, forKey: .nameBased)
            self = .ids(VmPathIds(pathIds: pathIds, isRelative: isRelative, nameBased: nameBased))
            return
        }

        throw DecodingError.dataCorruptedError(
            forKey: .pathIds,
            in: container,
            debugDescription: "VmPathRef requires pathIds"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ids(let ref):
            try container.encode(Kind.ids, forKey: .kind)
            try container.encode(ref.pathIds, forKey: .pathIds)
            if ref.isRelative == true {
                try container.encode(true, forKey: .isRelative)
            }
            if ref.nameBased == true {
                try container.encode(true, forKey: .nameBased)
            }
        }
    }

    public var normalizedPath: String {
        switch self {
        case .ids(let ref):
            let prefix: String
            if ref.isRelative == true {
                prefix = "ids:rel"
            } else if ref.nameBased == true {
                prefix = "ids:name"
            } else {
                prefix = "ids"
            }
            return "\(prefix):\(ref.pathIds.map(String.init).joined(separator: "."))"
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
    case flowEntered
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
        case flowEntered = "flow_entered"
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
        case .flowEntered:
            self = .flowEntered
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
            let delayMs: Int
            if let intValue = try? container.decode(Int.self, forKey: .delayMs) {
                delayMs = intValue
            } else {
                delayMs = Int(try container.decode(Double.self, forKey: .delayMs))
            }
            self = .afterDelay(delayMs: delayMs)
        case .event:
            let eventName = try container.decode(String.self, forKey: .eventName)
            let filter = try container.decodeIfPresent(IREnvelope.self, forKey: .filter)
            self = .event(eventName: eventName, filter: filter)
        case .manual:
            self = .manual(label: try container.decodeIfPresent(String.self, forKey: .label))
        case .viewModelChanged:
            let path = try container.decode(VmPathRef.self, forKey: .path)
            let debounceMs = try container.decodeIfPresent(Int.self, forKey: .debounceMs)
            self = .viewModelChanged(path: path, debounceMs: debounceMs)
        case .none:
            let rawType = (try? container.decode(String.self, forKey: .type)) ?? "unknown"
            var payload: [String: AnyCodable] = [:]
            for key in container.allKeys {
                if key == .type { continue }
                payload[key.stringValue] = (try? container.decode(AnyCodable.self, forKey: key)) ?? AnyCodable(NSNull())
            }
            self = .unknown(type: rawType, payload: payload)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .flowEntered:
            try container.encode(TriggerType.flowEntered, forKey: .type)
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
    case listMove(ListMoveAction)
    case listSet(ListSetAction)
    case listClear(ListClearAction)
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
        case listMove = "list_move"
        case listSet = "list_set"
        case listClear = "list_clear"
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
        case .listMove:
            self = .listMove(try ListMoveAction(from: decoder))
        case .listSet:
            self = .listSet(try ListSetAction(from: decoder))
        case .listClear:
            self = .listClear(try ListClearAction(from: decoder))
        case .exit:
            self = .exit(try ExitAction(from: decoder))
        case .none:
            let rawType = (try? container.decode(String.self, forKey: .type)) ?? "unknown"
            let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
            var payload: [String: AnyCodable] = [:]
            for key in dynamic.allKeys where key.stringValue != "type" {
                payload[key.stringValue] = (try? dynamic.decode(AnyCodable.self, forKey: key)) ?? AnyCodable(NSNull())
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
        case .listMove(let action):
            try action.encode(to: encoder)
        case .listSet(let action):
            try action.encode(to: encoder)
        case .listClear(let action):
            try action.encode(to: encoder)
        case .exit(let action):
            try action.encode(to: encoder)
        case .unknown(let type, let payload):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            if !payload.isEmpty {
                var extra = encoder.container(keyedBy: DynamicCodingKey.self)
                for (key, value) in payload {
                    if let codingKey = DynamicCodingKey(stringValue: key) {
                        try extra.encode(value, forKey: codingKey)
                    }
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

public struct ListMoveAction: Codable {
    public let type: String
    public let path: VmPathRef
    public let from: Int
    public let to: Int

    public init(type: String = "list_move", path: VmPathRef, from: Int, to: Int) {
        self.type = type
        self.path = path
        self.from = from
        self.to = to
    }
}

public struct ListSetAction: Codable {
    public let type: String
    public let path: VmPathRef
    public let index: Int
    public let value: AnyCodable

    public init(type: String = "list_set", path: VmPathRef, index: Int, value: AnyCodable) {
        self.type = type
        self.path = path
        self.index = index
        self.value = value
    }
}

public struct ListClearAction: Codable {
    public let type: String
    public let path: VmPathRef

    public init(type: String = "list_clear", path: VmPathRef) {
        self.type = type
        self.path = path
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
    public let viewModelPathId: Int?
    public let properties: [String: ViewModelProperty]
}

public enum ViewModelPropertyType: String, Codable {
    case string
    case number
    case boolean
    case color
    case `enum`
    case list
    case list_index
    case object
    case image
    case product
    case trigger
    case viewModel = "viewModel"
}

public final class ViewModelProperty: Codable {
    public let type: ViewModelPropertyType
    public let propertyId: Int?
    public let defaultValue: AnyCodable?
    public let required: Bool?
    public let enumValues: [String]?
    public let itemType: ViewModelProperty?
    public let schema: [String: ViewModelProperty]?
    public let viewModelId: String?
    public let validation: ViewModelValidation?

    public init(
        type: ViewModelPropertyType,
        propertyId: Int? = nil,
        defaultValue: AnyCodable? = nil,
        required: Bool? = nil,
        enumValues: [String]? = nil,
        itemType: ViewModelProperty? = nil,
        schema: [String: ViewModelProperty]? = nil,
        viewModelId: String? = nil,
        validation: ViewModelValidation? = nil
    ) {
        self.type = type
        self.propertyId = propertyId
        self.defaultValue = defaultValue
        self.required = required
        self.enumValues = enumValues
        self.itemType = itemType
        self.schema = schema
        self.viewModelId = viewModelId
        self.validation = validation
    }
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
}
