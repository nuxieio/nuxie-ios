import XCTest
@testable import Nuxie

final class FlowScreenTransitionSpecTests: XCTestCase {
    func testDefaultsToInstantForMissingTransition() {
        XCTAssertEqual(FlowScreenTransitionSpec(raw: nil), .instant)
    }

    func testParsesCommonTransitionPayloads() {
        let spec = FlowScreenTransitionSpec(raw: [
            "type": "push",
            "direction": "left",
            "durationMs": 450,
            "easing": ["type": "ease_out"]
        ])

        XCTAssertEqual(spec.kind, .push)
        XCTAssertEqual(spec.direction, .left)
        XCTAssertEqual(spec.duration, 0.45, accuracy: 0.0001)
        XCTAssertEqual(spec.easing, .easeOut)
    }

    func testNormalizesPublishedTransitionTokens() {
        let smartAnimate = FlowScreenTransitionSpec(raw: [
            "type": "smart-animate",
            "direction": "top",
            "duration": "250",
            "easing": "linear"
        ])

        XCTAssertEqual(smartAnimate.kind, .dissolve)
        XCTAssertEqual(smartAnimate.direction, .up)
        XCTAssertEqual(smartAnimate.duration, 0.25, accuracy: 0.0001)
        XCTAssertEqual(smartAnimate.easing, .linear)

        let slideOut = FlowScreenTransitionSpec(raw: [
            "type": "slide out",
            "direction": "bottom",
            "duration_ms": 120
        ])

        XCTAssertEqual(slideOut.kind, .slideOut)
        XCTAssertEqual(slideOut.direction, .down)
        XCTAssertEqual(slideOut.duration, 0.12, accuracy: 0.0001)
    }

    func testAcceptsAnyCodableTransitionValues() {
        let spec = FlowScreenTransitionSpec(raw: AnyCodable([
            "type": "move-in",
            "durationMs": AnyCodable(200),
            "easing": AnyCodable(["kind": "ease_in"])
        ]))

        XCTAssertEqual(spec.kind, .moveIn)
        XCTAssertEqual(spec.duration, 0.2, accuracy: 0.0001)
        XCTAssertEqual(spec.easing, .easeIn)
    }

    func testParsesSystemPresentAliasAndFadeCompatibility() {
        let present = FlowScreenTransitionSpec(raw: [
            "type": "modal",
            "durationMs": 500
        ])

        XCTAssertEqual(present.kind, .present)
        XCTAssertEqual(present.duration, 0.5, accuracy: 0.0001)

        let fade = FlowScreenTransitionSpec(raw: [
            "type": "fade"
        ])

        XCTAssertEqual(fade.kind, .dissolve)
    }

    func testParsesCustomTransitionIdButDoesNotTreatItAsUIKitAnimation() {
        let custom = FlowScreenTransitionSpec(raw: [
            "type": "custom",
            "transitionId": "transition.checkout_to_success",
            "durationMs": 450
        ])

        XCTAssertEqual(custom.kind, .custom)
        XCTAssertEqual(custom.transitionId, "transition.checkout_to_success")
        XCTAssertFalse(custom.isAnimated)
    }
}
