import Foundation

/// Canonical runtime trace envelope for fixture parity checks.
/// This stays renderer-neutral so React and future Rive runs can share assertions.
struct FlowRuntimeTrace: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let fixtureId: String
    let rendererBackend: String
    let entries: [FlowRuntimeTraceEntry]

    init(
        fixtureId: String,
        rendererBackend: String,
        entries: [FlowRuntimeTraceEntry]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.fixtureId = fixtureId
        self.rendererBackend = rendererBackend
        self.entries = entries
    }
}

struct FlowRuntimeTraceEntry: Codable, Equatable {
    enum Kind: String, Codable {
        case event
        case navigation
        case binding
    }

    let step: Int
    let kind: Kind
    let name: String
    let screenId: String?
    let output: String?
    let metadata: [String: String]?
}

final class FlowRuntimeTraceRecorder {
    private let lock = NSLock()
    private var nextStep: Int = 1
    private var entries: [FlowRuntimeTraceEntry] = []

    func recordRuntimeMessage(type: String, payload: [String: Any]) {
        switch type {
        case "runtime/navigate":
            let screenId = payload["screenId"] as? String
            append(
                kind: .navigation,
                name: "navigate",
                screenId: screenId,
                output: screenId,
                metadata: nil
            )

        case "runtime/screen_changed":
            let screenId = payload["screenId"] as? String
            append(
                kind: .navigation,
                name: "screen_changed",
                screenId: screenId,
                output: screenId,
                metadata: nil
            )

        case "action/did_set":
            let pathIds = Self.pathIds(from: payload["pathIds"])
            let value = payload["value"] ?? NSNull()

            var bindingOutput: [String: Any] = ["value": value]
            if let pathIds {
                bindingOutput["path_ids"] = pathIds
            }

            var metadata: [String: String] = [:]
            if let source = payload["source"] as? String {
                metadata["source"] = source
            }
            if let instanceId = payload["instanceId"] as? String {
                metadata["instance_id"] = instanceId
            }

            append(
                kind: .binding,
                name: "did_set",
                screenId: payload["screenId"] as? String,
                output: Self.canonicalJSONString(from: bindingOutput),
                metadata: metadata.isEmpty ? nil : metadata
            )

        default:
            break
        }
    }

    func recordEvent(name: String, properties: [String: Any]?) {
        append(
            kind: .event,
            name: name,
            screenId: properties?["screen_id"] as? String,
            output: properties.map(Self.canonicalJSONString(from:)),
            metadata: nil
        )
    }

    func ingestTrackedEvents(_ trackedEvents: [(name: String, properties: [String: Any]?)]) {
        for trackedEvent in trackedEvents {
            recordEvent(name: trackedEvent.name, properties: trackedEvent.properties)
        }
    }

    func trace(
        fixtureId: String,
        rendererBackend: String
    ) -> FlowRuntimeTrace {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return FlowRuntimeTrace(
            fixtureId: fixtureId,
            rendererBackend: rendererBackend,
            entries: snapshot
        )
    }

    private func append(
        kind: FlowRuntimeTraceEntry.Kind,
        name: String,
        screenId: String?,
        output: String?,
        metadata: [String: String]?
    ) {
        lock.lock()
        entries.append(
            FlowRuntimeTraceEntry(
                step: nextStep,
                kind: kind,
                name: name,
                screenId: screenId,
                output: output,
                metadata: metadata
            )
        )
        nextStep += 1
        lock.unlock()
    }

    private static func canonicalJSONString(from value: Any) -> String {
        let normalized = normalizeJSONValue(value)
        if let object = normalized as? [String: Any], JSONSerialization.isValidJSONObject(object) {
            if
                let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                let string = String(data: data, encoding: .utf8)
            {
                return string
            }
        }

        if let array = normalized as? [Any], JSONSerialization.isValidJSONObject(array) {
            if
                let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
                let string = String(data: data, encoding: .utf8)
            {
                return string
            }
        }

        return String(describing: normalized)
    }

    private static func normalizeJSONValue(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            var normalized: [String: Any] = [:]
            for key in dictionary.keys.sorted() {
                normalized[key] = normalizeJSONValue(dictionary[key] as Any)
            }
            return normalized

        case let array as [Any]:
            return array.map(normalizeJSONValue)

        case let number as NSNumber:
            return number

        case let string as String:
            return string

        case let bool as Bool:
            return bool

        case _ as NSNull:
            return NSNull()

        case let date as Date:
            return ISO8601DateFormatter().string(from: date)

        default:
            return String(describing: value)
        }
    }

    private static func pathIds(from value: Any?) -> [Int]? {
        if let ints = value as? [Int] {
            return ints
        }
        if let numbers = value as? [NSNumber] {
            return numbers.map { $0.intValue }
        }
        return nil
    }
}
