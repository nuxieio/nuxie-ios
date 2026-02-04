import Foundation
@testable import Nuxie

/// Helper for creating event conditions in tests
struct TestWaitCondition {
  static func event(_ name: String) -> IREnvelope {
    return IREnvelope(
      ir_version: 1,
      engine_min: nil,
      compiled_at: nil,
      expr: .event(op: "eq", key: "$name", value: .string(name))
    )
  }

  static func eventWithProperties(_ name: String, _ properties: [String: Any]) -> IREnvelope {
    var preds: [IRExpr] = [.pred(op: "eq", key: "$name", value: .string(name))]
    for (k, v) in properties {
      let val: IRExpr =
        (v as? String).map(IRExpr.string)
        ?? (v as? Int).map { .number(Double($0)) }
        ?? (v as? Double).map(IRExpr.number)
        ?? (v as? Bool).map(IRExpr.bool)
        ?? .string("\(v)")
      preds.append(.pred(op: "eq", key: "properties.\(k)", value: val))
    }
    return IREnvelope(
      ir_version: 1, engine_min: nil, compiled_at: nil,
      expr: preds.count == 1 ? preds[0] : .predAnd(preds))
  }

  static func eventCount(_ name: String, minCount: Int) -> IREnvelope {
    return IREnvelope(
      ir_version: 1,
      engine_min: nil,
      compiled_at: nil,
      expr: .compare(
        op: "gte",
        left: .eventsCount(name: name, since: nil, until: nil, within: nil, where_: nil),
        right: .number(Double(minCount))
      )
    )
  }

  static func user(_ key: String, value: Any) -> IREnvelope {
    let irValue: IRExpr
    if let str = value as? String {
      irValue = .string(str)
    } else if let num = value as? Double {
      irValue = .number(num)
    } else if let num = value as? Int {
      irValue = .number(Double(num))
    } else if let bool = value as? Bool {
      irValue = .bool(bool)
    } else {
      irValue = .string("\(value)")
    }

    return IREnvelope(
      ir_version: 1,
      engine_min: nil,
      compiled_at: nil,
      expr: .user(op: "eq", key: key, value: irValue)
    )
  }

  static func attribute(_ key: String, _ value: Any) -> IREnvelope {
    return user(key, value: value)
  }

  static func segment(_ segmentId: String) -> IREnvelope {
    return IREnvelope(
      ir_version: 1,
      engine_min: nil,
      compiled_at: nil,
      expr: .segment(op: "in", id: segmentId, within: nil)
    )
  }

  static func expression(_ expr: String) -> IREnvelope {
    // For legacy compatibility - convert common patterns to IR
    // Otherwise return false for timeout paths
    if expr == "false" || expr.isEmpty {
      return IREnvelope(
        ir_version: 1,
        engine_min: nil,
        compiled_at: nil,
        expr: .bool(false)
      )
    }
    // Default to true for other cases
    return IREnvelope(
      ir_version: 1,
      engine_min: nil,
      compiled_at: nil,
      expr: .bool(true)
    )
  }
}
