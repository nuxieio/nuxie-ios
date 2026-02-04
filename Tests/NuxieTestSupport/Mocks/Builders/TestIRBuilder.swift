import Foundation
@testable import Nuxie

/// Helper for creating IR conditions in tests
struct TestIRBuilder {
    static func alwaysTrue() -> IREnvelope {
        return IREnvelope(
            ir_version: 1,
            engine_min: "1.0.0",
            compiled_at: Date().timeIntervalSince1970,
            expr: IRExpr.bool(true)
        )
    }
    
    static func alwaysFalse() -> IREnvelope {
        return IREnvelope(
            ir_version: 1,
            engine_min: "1.0.0",
            compiled_at: Date().timeIntervalSince1970,
            expr: IRExpr.bool(false)
        )
    }
    
    static func userProperty(_ key: String, equals value: Any) -> IREnvelope {
        let valueExpr: IRExpr
        if let str = value as? String {
            valueExpr = .string(str)
        } else if let num = value as? Double {
            valueExpr = .number(num)
        } else if let num = value as? Int {
            valueExpr = .number(Double(num))
        } else if let bool = value as? Bool {
            valueExpr = .bool(bool)
        } else {
            valueExpr = .string("\(value)")
        }
        
        return IREnvelope(
            ir_version: 1,
            engine_min: "1.0.0",
            compiled_at: Date().timeIntervalSince1970,
            expr: IRExpr.user(
                op: "eq",
                key: key,
                value: valueExpr
            )
        )
    }
}