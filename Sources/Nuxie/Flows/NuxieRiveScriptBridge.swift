#if canImport(RiveRuntime) && canImport(UIKit)
import Foundation
import RiveRuntime

final class NuxieRiveScriptBridge {
    let scriptRuntime: RiveScriptRuntime

    private let lock = NSLock()
    private var pendingEvents: [PendingScriptEvent] = []

    init() {
        scriptRuntime = RiveScriptRuntime(modules: [])
        let triggerFunction: RiveScriptFunction = { [weak self] arguments in
            self?.enqueueTrigger(arguments: arguments)
            return nil
        }
        scriptRuntime.add(
            RiveScriptModule(
                name: "nuxie",
                functions: ["trigger": triggerFunction]
            )
        )
    }

    func drainEvents(currentScreenId: String) -> [FlowRendererEvent] {
        let events: [PendingScriptEvent]
        lock.lock()
        events = pendingEvents
        pendingEvents.removeAll()
        lock.unlock()

        return events.map { event in
            let properties = event.properties
            let eventScreenId = rendererStringProperty(
                ["screenId", "screen_id"],
                from: properties
            ) ?? currentScreenId
            let componentId = rendererStringProperty(
                ["componentId", "component_id", "elementId", "element_id"],
                from: properties
            )
            let instanceId = rendererStringProperty(
                ["instanceId", "instance_id"],
                from: properties
            )

            return FlowRendererEvent(
                name: event.name,
                properties: properties,
                screenId: eventScreenId,
                componentId: componentId,
                instanceId: instanceId
            )
        }
    }

    private func enqueueTrigger(arguments: [Any]) {
        guard let name = arguments.first as? String,
              !name.isEmpty else {
            return
        }

        let properties: [String: Any]
        if arguments.count > 1 {
            properties = scriptPayload(from: arguments[1])
        } else {
            properties = [:]
        }

        lock.lock()
        pendingEvents.append(PendingScriptEvent(name: name, properties: properties))
        lock.unlock()
    }

    private func scriptPayload(from value: Any) -> [String: Any] {
        if value is NSNull {
            return [:]
        }

        if let dictionary = value as? [String: Any] {
            return dictionary
        }

        if let dictionary = value as? NSDictionary {
            var properties: [String: Any] = [:]
            for (key, value) in dictionary {
                guard let key = key as? String,
                      !key.isEmpty else {
                    continue
                }
                properties[key] = value
            }
            return properties
        }

        return ["value": value]
    }

    private func rendererStringProperty(
        _ keys: [String],
        from properties: [String: Any]
    ) -> String? {
        for key in keys {
            if let value = properties[key] as? String,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

private struct PendingScriptEvent {
    let name: String
    let properties: [String: Any]
}
#endif
