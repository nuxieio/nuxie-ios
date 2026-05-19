import Foundation
@testable import Nuxie

/// Serializes native renderer callbacks onto a single execution context,
/// mirroring production (JourneyService is an actor).
actor FlowJourneyRunnerRuntimeBridge {
    private let runner: FlowJourneyRunner
    private let distinctId: String
    private var didHandleReady = false
    private var currentScreenId: String?

    init(runner: FlowJourneyRunner, distinctId: String = "test-user") {
        self.runner = runner
        self.distinctId = distinctId
    }

    func handleReady() async {
        guard !didHandleReady else { return }
        didHandleReady = true
        _ = await runner.handleRuntimeReady()
    }

    func handleScreenChanged(_ screenId: String) async {
        currentScreenId = screenId
        _ = await runner.handleScreenChanged(screenId)
    }

    func handleInteraction(_ interaction: FlowRendererInteraction) async {
        let screenId = interaction.screenId ?? currentScreenId
        _ = await runner.dispatchTrigger(
            trigger: interaction.trigger,
            screenId: screenId,
            componentId: interaction.componentId,
            instanceId: interaction.instanceId,
            event: nil
        )
    }

    func handleEvent(_ event: FlowRendererEvent) async {
        let runtimeEvent = NuxieEvent(
            name: event.name,
            distinctId: distinctId,
            properties: event.properties
        )
        _ = await runner.dispatchTrigger(
            trigger: .event(eventName: event.name, filter: nil),
            screenId: event.screenId ?? currentScreenId,
            componentId: event.componentId,
            instanceId: event.instanceId,
            event: runtimeEvent
        )
    }

    func handleViewModelChange(_ change: FlowRendererViewModelChange) async {
        _ = await runner.handleDidSet(
            path: change.path,
            value: change.value,
            source: change.source,
            screenId: change.screenId ?? currentScreenId,
            instanceId: change.instanceId
        )
    }
}

final class FlowJourneyRunnerRuntimeDelegate: FlowRuntimeDelegate {
    typealias OnEvent = (_ type: String, _ payload: [String: Any]) -> Void

    private let bridge: FlowJourneyRunnerRuntimeBridge
    private let onEvent: OnEvent?
    private let traceRecorder: FlowRuntimeTraceRecorder?

    init(
        bridge: FlowJourneyRunnerRuntimeBridge,
        onEvent: OnEvent? = nil,
        traceRecorder: FlowRuntimeTraceRecorder? = nil
    ) {
        self.bridge = bridge
        self.onEvent = onEvent
        self.traceRecorder = traceRecorder
    }

    func flowViewControllerDidBecomeReady(_ controller: FlowViewController) {
        onEvent?("renderer/ready", [:])
        Task { [bridge] in
            await bridge.handleReady()
        }
    }

    func flowViewController(
        _ controller: FlowViewController,
        didChangeScreen screenId: String
    ) {
        traceRecorder?.recordRendererScreenChanged(screenId: screenId)
        onEvent?("renderer/screen_changed", ["screenId": screenId])
        Task { [bridge] in
            await bridge.handleScreenChanged(screenId)
        }
    }

    func flowViewController(
        _ controller: FlowViewController,
        didEmitInteraction interaction: FlowRendererInteraction
    ) {
        var payload = interaction.properties
        if let screenId = interaction.screenId {
            payload["screenId"] = screenId
        }
        if let componentId = interaction.componentId {
            payload["componentId"] = componentId
        }
        if let instanceId = interaction.instanceId {
            payload["instanceId"] = instanceId
        }
        onEvent?("renderer/interaction", payload)
        Task { [bridge] in
            await bridge.handleInteraction(interaction)
        }
    }

    func flowViewController(
        _ controller: FlowViewController,
        didEmitEvent event: FlowRendererEvent
    ) {
        var payload = event.properties
        payload["name"] = event.name
        if let screenId = event.screenId {
            payload["screenId"] = screenId
        }
        if let componentId = event.componentId {
            payload["componentId"] = componentId
        }
        if let instanceId = event.instanceId {
            payload["instanceId"] = instanceId
        }
        traceRecorder?.recordEvent(name: event.name, properties: event.properties)
        onEvent?("renderer/event", payload)
        Task { [bridge] in
            await bridge.handleEvent(event)
        }
    }

    func flowViewController(
        _ controller: FlowViewController,
        didEmitViewModelChange change: FlowRendererViewModelChange
    ) {
        traceRecorder?.recordRendererBindingChange(
            screenId: change.screenId,
            pathIds: tracePathIds(from: change.path),
            value: change.value,
            source: change.source,
            instanceId: change.instanceId
        )
        onEvent?(
            "renderer/view_model_change",
            [
                "value": change.value,
                "source": change.source as Any,
                "screenId": change.screenId as Any,
                "instanceId": change.instanceId as Any
            ]
        )
        Task { [bridge] in
            await bridge.handleViewModelChange(change)
        }
    }

    func flowViewControllerDidRequestDismiss(_ controller: FlowViewController, reason: CloseReason) {
        // Not used in these E2E tests.
    }

    private func tracePathIds(from path: VmPathRef) -> [Int]? {
        switch path {
        case .ids(let ref):
            return ref.pathIds
        }
    }
}
