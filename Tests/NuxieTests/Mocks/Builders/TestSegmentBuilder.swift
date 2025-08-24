import Foundation
@testable import Nuxie

/// Builder for creating test segments with fluent API
class TestSegmentBuilder {
    private var id: String
    private var name: String
    private var condition: IREnvelope
    
    init(id: String = "test-segment") {
        self.id = id
        self.name = "Test Segment"
        self.condition = IREnvelope(
            ir_version: 1,
            engine_min: "1.0.0",
            compiled_at: Date().timeIntervalSince1970,
            expr: IRExpr.bool(true)
        )
    }
    
    func withId(_ id: String) -> TestSegmentBuilder {
        self.id = id
        return self
    }
    
    func withName(_ name: String) -> TestSegmentBuilder {
        self.name = name
        return self
    }
    
    func withCondition(_ condition: IREnvelope) -> TestSegmentBuilder {
        self.condition = condition
        return self
    }
    
    func withConditionExpr(_ expr: IRExpr) -> TestSegmentBuilder {
        self.condition = IREnvelope(
            ir_version: condition.ir_version,
            engine_min: condition.engine_min,
            compiled_at: condition.compiled_at,
            expr: expr
        )
        return self
    }
    
    func build() -> Segment {
        return Segment(
            id: id,
            name: name,
            condition: condition
        )
    }
}