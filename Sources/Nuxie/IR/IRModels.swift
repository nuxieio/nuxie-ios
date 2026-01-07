import Foundation

// MARK: - Envelope

/// Top-level IR container with version and metadata
public struct IREnvelope: Codable {
    public let ir_version: Int
    public let engine_min: String?
    public let compiled_at: Double?
    public let expr: IRExpr
    
    enum CodingKeys: String, CodingKey {
        case ir_version
        case engine_min
        case compiled_at
        case expr
    }
}

// MARK: - Expression nodes (v1)

/// IR expression node types
public indirect enum IRExpr: Codable {
    // Scalars / containers
    case bool(Bool)
    case number(Double)
    case string(String)
    case timestamp(Double)       // epoch seconds
    case duration(Double)        // seconds
    case list([IRExpr])
    
    // Boolean composition
    case and([IRExpr])
    case or([IRExpr])
    case not(IRExpr)
    
    // Generic compare (used when both sides are values)
    case compare(op: String, left: IRExpr, right: IRExpr)
    
    // User (identity)
    case user(op: String, key: String, value: IRExpr?)
    
    // Event (current trigger event)
    case event(op: String, key: String, value: IRExpr?)
    
    // Segment membership
    case segment(op: String, id: String, within: IRExpr?)

    // Feature access (entitlements)
    case feature(op: String, id: String, value: IRExpr?)

    // Predicates over event properties
    case pred(op: String, key: String, value: IRExpr?)
    case predAnd([IRExpr])
    case predOr([IRExpr])
    
    // Event queries
    case eventsExists(name: String, since: IRExpr?, until: IRExpr?, within: IRExpr?, where_: IRExpr?)
    case eventsCount(name: String, since: IRExpr?, until: IRExpr?, within: IRExpr?, where_: IRExpr?)
    case eventsFirstTime(name: String, where_: IRExpr?)
    case eventsLastTime(name: String, where_: IRExpr?)
    case eventsLastAge(name: String, where_: IRExpr?)
    case eventsAggregate(agg: String, name: String, prop: String, since: IRExpr?, until: IRExpr?, within: IRExpr?, where_: IRExpr?)
    case eventsInOrder(steps: [Step], overallWithin: IRExpr?, perStepWithin: IRExpr?, since: IRExpr?, until: IRExpr?)
    case eventsActivePeriods(name: String, period: String, totalPeriods: Int, minPeriods: Int, where_: IRExpr?)
    case eventsStopped(name: String, inactiveFor: IRExpr, where_: IRExpr?)
    case eventsRestarted(name: String, inactiveFor: IRExpr, within: IRExpr, where_: IRExpr?)
    
    // Time helpers
    case timeNow
    case timeAgo(duration: IRExpr)
    case timeWindow(value: Int, interval: String)

    // Journey context
    case journeyId
    
    /// Step in a sequence query
    public struct Step: Codable {
        public let name: String
        public let where_: IRExpr?
        
        enum CodingKeys: String, CodingKey {
            case name
            case where_ = "where"
        }
    }
    
    // MARK: - Codable
    
    enum CodingKeys: String, CodingKey {
        case type
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "Bool":
            let valueContainer = try decoder.container(keyedBy: ValueCodingKeys.self)
            let value = try valueContainer.decode(Bool.self, forKey: .value)
            self = .bool(value)
            
        case "Number":
            let valueContainer = try decoder.container(keyedBy: ValueCodingKeys.self)
            let value = try valueContainer.decode(Double.self, forKey: .value)
            self = .number(value)
            
        case "String":
            let valueContainer = try decoder.container(keyedBy: ValueCodingKeys.self)
            let value = try valueContainer.decode(String.self, forKey: .value)
            self = .string(value)
            
        case "Timestamp":
            let valueContainer = try decoder.container(keyedBy: ValueCodingKeys.self)
            let value = try valueContainer.decode(Double.self, forKey: .value)
            self = .timestamp(value)
            
        case "Duration":
            let valueContainer = try decoder.container(keyedBy: ValueCodingKeys.self)
            let value = try valueContainer.decode(Double.self, forKey: .value)
            self = .duration(value)
            
        case "List":
            let valueContainer = try decoder.container(keyedBy: ValueCodingKeys.self)
            let value = try valueContainer.decode([IRExpr].self, forKey: .value)
            self = .list(value)
            
        case "And":
            let argsContainer = try decoder.container(keyedBy: ArgsCodingKeys.self)
            let args = try argsContainer.decode([IRExpr].self, forKey: .args)
            self = .and(args)
            
        case "Or":
            let argsContainer = try decoder.container(keyedBy: ArgsCodingKeys.self)
            let args = try argsContainer.decode([IRExpr].self, forKey: .args)
            self = .or(args)
            
        case "Not":
            let argContainer = try decoder.container(keyedBy: ArgCodingKeys.self)
            let arg = try argContainer.decode(IRExpr.self, forKey: .arg)
            self = .not(arg)
            
        case "Compare":
            let compareContainer = try decoder.container(keyedBy: CompareCodingKeys.self)
            let op = try compareContainer.decode(String.self, forKey: .op)
            let left = try compareContainer.decode(IRExpr.self, forKey: .left)
            let right = try compareContainer.decode(IRExpr.self, forKey: .right)
            self = .compare(op: op, left: left, right: right)
            
        case "User":
            let userContainer = try decoder.container(keyedBy: UserCodingKeys.self)
            let op = try userContainer.decode(String.self, forKey: .op)
            let key = try userContainer.decode(String.self, forKey: .key)
            let value = try userContainer.decodeIfPresent(IRExpr.self, forKey: .value)
            self = .user(op: op, key: key, value: value)
            
        case "Event":
            let eventContainer = try decoder.container(keyedBy: UserCodingKeys.self)
            let op = try eventContainer.decode(String.self, forKey: .op)
            let key = try eventContainer.decode(String.self, forKey: .key)
            let value = try eventContainer.decodeIfPresent(IRExpr.self, forKey: .value)
            self = .event(op: op, key: key, value: value)
            
        case "Segment":
            let segmentContainer = try decoder.container(keyedBy: SegmentCodingKeys.self)
            let op = try segmentContainer.decode(String.self, forKey: .op)
            let id = try segmentContainer.decode(String.self, forKey: .id)
            let within = try segmentContainer.decodeIfPresent(IRExpr.self, forKey: .within)
            self = .segment(op: op, id: id, within: within)

        case "Feature":
            let featureContainer = try decoder.container(keyedBy: FeatureCodingKeys.self)
            let op = try featureContainer.decode(String.self, forKey: .op)
            let id = try featureContainer.decode(String.self, forKey: .id)
            let value = try featureContainer.decodeIfPresent(IRExpr.self, forKey: .value)
            self = .feature(op: op, id: id, value: value)

        case "Pred":
            let predContainer = try decoder.container(keyedBy: PredCodingKeys.self)
            let op = try predContainer.decode(String.self, forKey: .op)
            let key = try predContainer.decode(String.self, forKey: .key)
            let value = try predContainer.decodeIfPresent(IRExpr.self, forKey: .value)
            self = .pred(op: op, key: key, value: value)
            
        case "PredAnd":
            let argsContainer = try decoder.container(keyedBy: ArgsCodingKeys.self)
            let args = try argsContainer.decode([IRExpr].self, forKey: .args)
            self = .predAnd(args)
            
        case "PredOr":
            let argsContainer = try decoder.container(keyedBy: ArgsCodingKeys.self)
            let args = try argsContainer.decode([IRExpr].self, forKey: .args)
            self = .predOr(args)
            
        case "Events.Exists":
            let eventsContainer = try decoder.container(keyedBy: EventsCodingKeys.self)
            let name = try eventsContainer.decode(String.self, forKey: .name)
            let since = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .since)
            let until = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .until)
            let within = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .within)
            let where_ = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .where)
            self = .eventsExists(name: name, since: since, until: until, within: within, where_: where_)
            
        case "Events.Count":
            let eventsContainer = try decoder.container(keyedBy: EventsCodingKeys.self)
            let name = try eventsContainer.decode(String.self, forKey: .name)
            let since = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .since)
            let until = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .until)
            let within = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .within)
            let where_ = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .where)
            self = .eventsCount(name: name, since: since, until: until, within: within, where_: where_)
            
        case "Events.FirstTime":
            let eventsContainer = try decoder.container(keyedBy: EventsCodingKeys.self)
            let name = try eventsContainer.decode(String.self, forKey: .name)
            let where_ = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .where)
            self = .eventsFirstTime(name: name, where_: where_)
            
        case "Events.LastTime":
            let eventsContainer = try decoder.container(keyedBy: EventsCodingKeys.self)
            let name = try eventsContainer.decode(String.self, forKey: .name)
            let where_ = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .where)
            self = .eventsLastTime(name: name, where_: where_)
            
        case "Events.LastAge":
            let eventsContainer = try decoder.container(keyedBy: EventsCodingKeys.self)
            let name = try eventsContainer.decode(String.self, forKey: .name)
            let where_ = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .where)
            self = .eventsLastAge(name: name, where_: where_)
            
        case "Events.Aggregate":
            let aggContainer = try decoder.container(keyedBy: AggregateCodingKeys.self)
            let agg = try aggContainer.decode(String.self, forKey: .agg)
            let name = try aggContainer.decode(String.self, forKey: .name)
            let prop = try aggContainer.decode(String.self, forKey: .prop)
            let since = try aggContainer.decodeIfPresent(IRExpr.self, forKey: .since)
            let until = try aggContainer.decodeIfPresent(IRExpr.self, forKey: .until)
            let within = try aggContainer.decodeIfPresent(IRExpr.self, forKey: .within)
            let where_ = try aggContainer.decodeIfPresent(IRExpr.self, forKey: .where)
            self = .eventsAggregate(agg: agg, name: name, prop: prop, since: since, until: until, within: within, where_: where_)
            
        case "Events.InOrder":
            let orderContainer = try decoder.container(keyedBy: InOrderCodingKeys.self)
            let steps = try orderContainer.decode([Step].self, forKey: .steps)
            let overallWithin = try orderContainer.decodeIfPresent(IRExpr.self, forKey: .overallWithin)
            let perStepWithin = try orderContainer.decodeIfPresent(IRExpr.self, forKey: .perStepWithin)
            let since = try orderContainer.decodeIfPresent(IRExpr.self, forKey: .since)
            let until = try orderContainer.decodeIfPresent(IRExpr.self, forKey: .until)
            self = .eventsInOrder(steps: steps, overallWithin: overallWithin, perStepWithin: perStepWithin, since: since, until: until)
            
        case "Events.ActivePeriods":
            let periodsContainer = try decoder.container(keyedBy: ActivePeriodsCodingKeys.self)
            let name = try periodsContainer.decode(String.self, forKey: .name)
            let period = try periodsContainer.decode(String.self, forKey: .period)
            let totalPeriods = try periodsContainer.decode(Int.self, forKey: .totalPeriods)
            let minPeriods = try periodsContainer.decode(Int.self, forKey: .minPeriods)
            let where_ = try periodsContainer.decodeIfPresent(IRExpr.self, forKey: .where)
            self = .eventsActivePeriods(name: name, period: period, totalPeriods: totalPeriods, minPeriods: minPeriods, where_: where_)
            
        case "Events.Stopped":
            let stoppedContainer = try decoder.container(keyedBy: StoppedCodingKeys.self)
            let name = try stoppedContainer.decode(String.self, forKey: .name)
            let inactiveFor = try stoppedContainer.decode(IRExpr.self, forKey: .inactiveFor)
            let where_ = try stoppedContainer.decodeIfPresent(IRExpr.self, forKey: .where)
            self = .eventsStopped(name: name, inactiveFor: inactiveFor, where_: where_)
            
        case "Events.Restarted":
            let restartedContainer = try decoder.container(keyedBy: RestartedCodingKeys.self)
            let name = try restartedContainer.decode(String.self, forKey: .name)
            let inactiveFor = try restartedContainer.decode(IRExpr.self, forKey: .inactiveFor)
            let within = try restartedContainer.decode(IRExpr.self, forKey: .within)
            let where_ = try restartedContainer.decodeIfPresent(IRExpr.self, forKey: .where)
            self = .eventsRestarted(name: name, inactiveFor: inactiveFor, within: within, where_: where_)
            
        case "Time.Now":
            self = .timeNow
            
        case "Time.Ago":
            let timeContainer = try decoder.container(keyedBy: TimeAgoCodingKeys.self)
            let duration = try timeContainer.decode(IRExpr.self, forKey: .duration)
            self = .timeAgo(duration: duration)
            
        case "Time.Window":
            let windowContainer = try decoder.container(keyedBy: TimeWindowCodingKeys.self)
            let value = try windowContainer.decode(Int.self, forKey: .value)
            let interval = try windowContainer.decode(String.self, forKey: .interval)
            self = .timeWindow(value: value, interval: interval)

        case "Journey.Id":
            self = .journeyId

        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown IR node type: \(type)"
                )
            )
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        // Implementation deferred - not needed for client-side evaluation
        throw IRError.encodingNotImplemented
    }
    
    // MARK: - Private Coding Keys
    
    private enum ValueCodingKeys: String, CodingKey {
        case value
    }
    
    private enum ArgsCodingKeys: String, CodingKey {
        case args
    }
    
    private enum ArgCodingKeys: String, CodingKey {
        case arg
    }
    
    private enum CompareCodingKeys: String, CodingKey {
        case op, left, right
    }
    
    private enum UserCodingKeys: String, CodingKey {
        case op, key, value
    }
    
    private enum SegmentCodingKeys: String, CodingKey {
        case op, id, within
    }

    private enum FeatureCodingKeys: String, CodingKey {
        case op, id, value
    }

    private enum PredCodingKeys: String, CodingKey {
        case op, key, value
    }
    
    private enum EventsCodingKeys: String, CodingKey {
        case name, since, until, within
        case `where`
    }
    
    private enum AggregateCodingKeys: String, CodingKey {
        case agg, name, prop, since, until, within
        case `where`
    }
    
    private enum InOrderCodingKeys: String, CodingKey {
        case steps, overallWithin, perStepWithin, since, until
    }
    
    private enum ActivePeriodsCodingKeys: String, CodingKey {
        case name, period, totalPeriods, minPeriods
        case `where`
    }
    
    private enum StoppedCodingKeys: String, CodingKey {
        case name, inactiveFor
        case `where`
    }
    
    private enum RestartedCodingKeys: String, CodingKey {
        case name, inactiveFor, within
        case `where`
    }
    
    private enum TimeAgoCodingKeys: String, CodingKey {
        case duration
    }
    
    private enum TimeWindowCodingKeys: String, CodingKey {
        case value, interval
    }
    
}

// MARK: - Errors

public enum IRError: Error, LocalizedError {
    case encodingNotImplemented
    case invalidNodeType(String)
    case invalidOperator(String)
    case typeMismatch(expected: String, got: String)
    case evaluationError(String)
    
    public var errorDescription: String? {
        switch self {
        case .encodingNotImplemented:
            return "IR encoding is not implemented"
        case .invalidNodeType(let type):
            return "Invalid IR node type: \(type)"
        case .invalidOperator(let op):
            return "Invalid operator: \(op)"
        case .typeMismatch(let expected, let got):
            return "Type mismatch: expected \(expected), got \(got)"
        case .evaluationError(let message):
            return "Evaluation error: \(message)"
        }
    }
}