import Foundation
@testable import Nuxie

/// Serializes web->native runtime messages onto a single execution context,
/// mirroring production (JourneyService is an actor).
actor FlowJourneyRunnerRuntimeBridge {
    private let runner: FlowJourneyRunner
    private var didHandleReady = false
    private var currentScreenId: String?

    init(runner: FlowJourneyRunner) {
        self.runner = runner
    }

    private func parseInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func parseDouble(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func parsePathRef(_ payload: [String: Any]) -> VmPathRef? {
        let isRelative = payload["isRelative"] as? Bool
        let nameBased = payload["nameBased"] as? Bool
        if let pathIds = payload["pathIds"] as? [Int] {
            return .ids(VmPathIds(pathIds: pathIds, isRelative: isRelative, nameBased: nameBased))
        }
        if let pathIds = payload["pathIds"] as? [NSNumber] {
            return .ids(VmPathIds(pathIds: pathIds.map { $0.intValue }, isRelative: isRelative, nameBased: nameBased))
        }
        return nil
    }

	    func handle(type: String, payload: [String: Any], id: String?) async {
	        switch type {
	        case "runtime/ready":
	            guard !didHandleReady else { return }
	            didHandleReady = true
	            _ = await runner.handleRuntimeReady()

	        case "runtime/screen_changed":
	            guard let screenId = payload["screenId"] as? String else { return }
	            currentScreenId = screenId
	            _ = await runner.handleScreenChanged(screenId)

	        case "action/long_press", "action/longpress":
	            let minMs = parseInt(payload["minMs"] ?? payload["min_ms"])
	            let screenId = payload["screenId"] as? String ?? currentScreenId
	            let componentId = payload["componentId"] as? String ?? payload["elementId"] as? String
	            let instanceId = payload["instanceId"] as? String
            _ = await runner.dispatchTrigger(
                trigger: .longPress(minMs: minMs),
                screenId: screenId,
                componentId: componentId,
                instanceId: instanceId,
                event: nil
            )

        case "action/hover":
            let screenId = payload["screenId"] as? String ?? currentScreenId
            let componentId = payload["componentId"] as? String ?? payload["elementId"] as? String
            let instanceId = payload["instanceId"] as? String
            _ = await runner.dispatchTrigger(
                trigger: .hover,
                screenId: screenId,
                componentId: componentId,
                instanceId: instanceId,
                event: nil
            )

        case "action/press":
            let screenId = payload["screenId"] as? String ?? currentScreenId
            let componentId = payload["componentId"] as? String ?? payload["elementId"] as? String
            let instanceId = payload["instanceId"] as? String
            _ = await runner.dispatchTrigger(
                trigger: .press,
                screenId: screenId,
                componentId: componentId,
                instanceId: instanceId,
                event: nil
            )

        case "action/drag":
            let direction = (payload["direction"] as? String)
                .flatMap { InteractionTrigger.DragDirection(rawValue: $0) }
            let threshold = parseDouble(payload["threshold"])
            let screenId = payload["screenId"] as? String ?? currentScreenId
            let componentId = payload["componentId"] as? String ?? payload["elementId"] as? String
            let instanceId = payload["instanceId"] as? String
            _ = await runner.dispatchTrigger(
                trigger: .drag(direction: direction, threshold: threshold),
                screenId: screenId,
                componentId: componentId,
                instanceId: instanceId,
                event: nil
            )

        case "action/did_set":
            guard let path = parsePathRef(payload) else { return }
            let value = payload["value"] ?? NSNull()
            let source = payload["source"] as? String
            let screenId = payload["screenId"] as? String ?? currentScreenId
            let instanceId = payload["instanceId"] as? String
            _ = await runner.handleDidSet(
                path: path,
                value: value,
                source: source,
                screenId: screenId,
                instanceId: instanceId
            )

        default:
            break
        }
    }
}

final class FlowJourneyRunnerRuntimeDelegate: FlowRuntimeDelegate {
    typealias OnMessage = (_ type: String, _ payload: [String: Any], _ id: String?) -> Void

    private let bridge: FlowJourneyRunnerRuntimeBridge
    private let onMessage: OnMessage?
    private let traceRecorder: FlowRuntimeTraceRecorder?

    init(
        bridge: FlowJourneyRunnerRuntimeBridge,
        onMessage: OnMessage? = nil,
        traceRecorder: FlowRuntimeTraceRecorder? = nil
    ) {
        self.bridge = bridge
        self.onMessage = onMessage
        self.traceRecorder = traceRecorder
    }

    func flowViewController(_ controller: FlowViewController, didReceiveRuntimeMessage type: String, payload: [String: Any], id: String?) {
        traceRecorder?.recordRuntimeMessage(type: type, payload: payload)
        onMessage?(type, payload, id)
        Task { [bridge] in
            await bridge.handle(type: type, payload: payload, id: id)
        }
    }

    func flowViewController(
        _ controller: FlowViewController,
        didSendRuntimeMessage type: String,
        payload: [String : Any],
        replyTo: String?
    ) {
        traceRecorder?.recordRuntimeMessage(type: type, payload: payload)
    }

    func flowViewControllerDidRequestDismiss(_ controller: FlowViewController, reason: CloseReason) {
        // Not used in these E2E tests.
    }
}
