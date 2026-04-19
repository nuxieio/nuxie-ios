import Foundation
import Quick
import Nimble
@testable import Nuxie

final class IREncoderTests: QuickSpec {
    override class func spec() {
        func expectRoundTrip(_ expr: IRExpr) throws {
            let data = try JSONEncoder().encode(expr)
            let decoded = try JSONDecoder().decode(IRExpr.self, from: data)
            expect(decoded).to(equal(expr))
        }

        describe("IRExpr encoding") {
            let cases: [(String, IRExpr)] = [
                ("bool", .bool(true)),
                ("number", .number(42.5)),
                ("string", .string("hello world")),
                ("timestamp", .timestamp(1_723_780_000.5)),
                ("duration", .duration(3_600)),
                ("list", .list([.number(1), .string("test"), .bool(false)])),
                ("and", .and([.bool(true), .bool(false)])),
                ("or", .or([.bool(true), .bool(false)])),
                ("not", .not(.bool(true))),
                ("compare", .compare(op: ">=", left: .number(10), right: .number(5))),
                ("user", .user(op: "eq", key: "plan", value: .string("pro"))),
                ("event", .event(op: "eq", key: "source", value: .string("paywall"))),
                ("segment", .segment(op: "entered", id: "seg_pro", within: .duration(600))),
                ("feature", .feature(op: "gte", id: "credits", value: .number(10))),
                ("pred", .pred(op: "eq", key: "button_id", value: .string("cta_primary"))),
                ("predAnd", .predAnd([.pred(op: "eq", key: "step", value: .string("a"))])),
                ("predOr", .predOr([.pred(op: "eq", key: "step", value: .string("b"))])),
                ("eventsExists", .eventsExists(
                    name: "purchase_completed",
                    since: .timeAgo(duration: .duration(86_400)),
                    until: .timeNow,
                    within: .duration(3_600),
                    where_: .pred(op: "eq", key: "sku", value: .string("premium"))
                )),
                ("eventsCount", .eventsCount(
                    name: "screen_viewed",
                    since: .timeAgo(duration: .duration(86_400)),
                    until: nil,
                    within: nil,
                    where_: .pred(op: "eq", key: "screen", value: .string("paywall"))
                )),
                ("eventsFirstTime", .eventsFirstTime(
                    name: "signup_started",
                    where_: .pred(op: "eq", key: "method", value: .string("email"))
                )),
                ("eventsLastTime", .eventsLastTime(
                    name: "signup_finished",
                    where_: .pred(op: "eq", key: "method", value: .string("email"))
                )),
                ("eventsLastAge", .eventsLastAge(
                    name: "session_started",
                    where_: .pred(op: "eq", key: "platform", value: .string("ios"))
                )),
                ("eventsAggregate", .eventsAggregate(
                    agg: "sum",
                    name: "credits_used",
                    prop: "amount",
                    since: .timeAgo(duration: .duration(86_400)),
                    until: .timeNow,
                    within: nil,
                    where_: .pred(op: "eq", key: "source", value: .string("purchase"))
                )),
                ("eventsInOrder", .eventsInOrder(
                    steps: [
                        .init(name: "signup_started", where_: .pred(op: "eq", key: "method", value: .string("email"))),
                        .init(name: "signup_finished", where_: nil),
                    ],
                    overallWithin: .duration(1_800),
                    perStepWithin: .duration(900),
                    since: .timeAgo(duration: .duration(86_400)),
                    until: .timeNow
                )),
                ("eventsActivePeriods", .eventsActivePeriods(
                    name: "session_started",
                    period: "day",
                    totalPeriods: 7,
                    minPeriods: 3,
                    where_: .pred(op: "eq", key: "platform", value: .string("ios"))
                )),
                ("eventsStopped", .eventsStopped(
                    name: "session_started",
                    inactiveFor: .duration(86_400),
                    where_: .pred(op: "eq", key: "platform", value: .string("ios"))
                )),
                ("eventsRestarted", .eventsRestarted(
                    name: "session_started",
                    inactiveFor: .duration(86_400),
                    within: .duration(604_800),
                    where_: .pred(op: "eq", key: "platform", value: .string("ios"))
                )),
                ("timeNow", .timeNow),
                ("timeAgo", .timeAgo(duration: .duration(300))),
                ("timeWindow", .timeWindow(value: 7, interval: "day")),
                ("journeyId", .journeyId),
            ]

            for (name, expr) in cases {
                it("round-trips \(name) nodes") {
                    try expectRoundTrip(expr)
                }
            }
        }

        describe("IREnvelope encoding") {
            it("round-trips a nested envelope") {
                let envelope = IREnvelope(
                    ir_version: 1,
                    engine_min: "1.2.3",
                    compiled_at: 1_723_780_000,
                    expr: .and([
                        .compare(op: ">=", left: .eventsCount(
                            name: "purchase_completed",
                            since: .timeAgo(duration: .duration(86_400)),
                            until: .timeNow,
                            within: nil,
                            where_: .pred(op: "eq", key: "sku", value: .string("premium"))
                        ), right: .number(1)),
                        .feature(op: "gte", id: "credits", value: .number(10)),
                    ])
                )

                let data = try JSONEncoder().encode(envelope)
                let decoded = try JSONDecoder().decode(IREnvelope.self, from: data)

                expect(decoded).to(equal(envelope))
            }
        }
    }
}
