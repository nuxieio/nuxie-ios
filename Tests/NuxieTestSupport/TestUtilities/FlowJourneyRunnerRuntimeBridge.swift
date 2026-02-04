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

        case "action/tap":
            let screenId = payload["screenId"] as? String ?? currentScreenId
            let componentId = payload["componentId"] as? String ?? payload["elementId"] as? String
            let instanceId = payload["instanceId"] as? String
            _ = await runner.dispatchTrigger(
                trigger: .tap,
                screenId: screenId,
                componentId: componentId,
                instanceId: instanceId,
                event: nil
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

    init(bridge: FlowJourneyRunnerRuntimeBridge, onMessage: OnMessage? = nil) {
        self.bridge = bridge
        self.onMessage = onMessage
    }

    func flowViewController(_ controller: FlowViewController, didReceiveRuntimeMessage type: String, payload: [String: Any], id: String?) {
        onMessage?(type, payload, id)
        Task { [bridge] in
            await bridge.handle(type: type, payload: payload, id: id)
        }
    }

    func flowViewControllerDidRequestDismiss(_ controller: FlowViewController, reason: CloseReason) {
        // Not used in these E2E tests.
    }
}

