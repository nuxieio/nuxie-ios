import XCTest
@testable import Nuxie

final class FlowScreenTransitionSpecTests: XCTestCase {
    func testDefaultsToNoneForMissingTransition() {
        XCTAssertEqual(FlowScreenTransitionSpec(raw: nil), .none)
    }

    func testParsesSupportedTransitionPayloads() {
        XCTAssertEqual(
            FlowScreenTransitionSpec(raw: ["type": "none"]),
            FlowScreenTransitionSpec(kind: .none)
        )
        XCTAssertEqual(
            FlowScreenTransitionSpec(raw: ["type": "push"]),
            FlowScreenTransitionSpec(kind: .push)
        )
        XCTAssertEqual(
            FlowScreenTransitionSpec(raw: ["type": "modal"]),
            FlowScreenTransitionSpec(kind: .modal)
        )
        XCTAssertEqual(
            FlowScreenTransitionSpec(raw: ["type": "fade"]),
            FlowScreenTransitionSpec(kind: .fade)
        )
    }

    func testRejectsRemovedTransitionPayloads() {
        XCTAssertEqual(FlowScreenTransitionSpec(raw: ["type": "instant"]), .none)
        XCTAssertEqual(FlowScreenTransitionSpec(raw: ["type": "present"]), .none)
        XCTAssertEqual(FlowScreenTransitionSpec(raw: ["type": "dissolve"]), .none)
        XCTAssertEqual(FlowScreenTransitionSpec(raw: ["type": "move_in"]), .none)
        XCTAssertEqual(FlowScreenTransitionSpec(raw: ["type": "slide_out"]), .none)
    }

    func testAcceptsAnyCodableTransitionValues() {
        let spec = FlowScreenTransitionSpec(raw: AnyCodable([
            "type": "fade"
        ]))

        XCTAssertEqual(spec.kind, .fade)
        XCTAssertTrue(spec.isAnimated)
    }

    func testParsesCustomTransitionIdButDoesNotTreatItAsUIKitAnimation() {
        let custom = FlowScreenTransitionSpec(raw: [
            "type": "custom",
            "transitionId": "transition.checkout_to_success"
        ])

        XCTAssertEqual(custom.kind, .custom)
        XCTAssertEqual(custom.transitionId, "transition.checkout_to_success")
        XCTAssertFalse(custom.isAnimated)
    }
}
