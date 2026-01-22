import Foundation

public struct FlowViewModelSnapshot: Codable {
    public let viewModelInstances: [ViewModelInstance]
}

private struct FlowViewModelInstanceState {
    var viewModelId: String
    var instanceId: String
    var name: String?
    var values: [String: AnyCodable]
}

private enum PathSegment {
    case prop(String)
    case index(String)
}

public final class FlowViewModelRuntime {
    private let remoteFlow: RemoteFlow
    private var viewModels: [String: ViewModel] = [:]
    private var instances: [String: FlowViewModelInstanceState] = [:]
    private var instancesByViewModel: [String: [String]] = [:]
    private var screenDefaults: [String: (defaultViewModelId: String?, defaultInstanceId: String?)] = [:]

    public init(remoteFlow: RemoteFlow) {
        self.remoteFlow = remoteFlow

        for model in remoteFlow.viewModels {
            viewModels[model.id] = model
        }

        for screen in remoteFlow.screens {
            screenDefaults[screen.id] = (screen.defaultViewModelId, screen.defaultInstanceId)
        }

        let instances = remoteFlow.viewModelInstances ?? []
        for instance in instances {
            let state = FlowViewModelInstanceState(
                viewModelId: instance.viewModelId,
                instanceId: instance.instanceId,
                name: instance.name,
                values: instance.values
            )
            self.instances[state.instanceId] = state
            var list = instancesByViewModel[state.viewModelId] ?? []
            list.append(state.instanceId)
            instancesByViewModel[state.viewModelId] = list
            applyViewModelDefaults(instanceId: state.instanceId)
        }

        // Ensure each view model has at least one instance
        for viewModel in remoteFlow.viewModels {
            if (instancesByViewModel[viewModel.id] ?? []).isEmpty {
                let blank = createBlankInstance(for: viewModel.id)
                self.instances[blank.instanceId] = blank
                instancesByViewModel[viewModel.id] = [blank.instanceId]
            }
        }
    }

    public func getSnapshot() -> FlowViewModelSnapshot {
        let values = instances.values.map { state -> ViewModelInstance in
            ViewModelInstance(
                viewModelId: state.viewModelId,
                instanceId: state.instanceId,
                name: state.name,
                values: state.values
            )
        }
        return FlowViewModelSnapshot(viewModelInstances: values)
    }

    public func isTriggerPath(path: VmPathRef, screenId: String?) -> Bool {
        guard let instance = resolveInstance(screenId: screenId, viewModelId: nil, instanceId: nil) else {
            return false
        }
        let normalized = resolvePathString(path)
        let segments = parsePathSegments(normalized)
        if segments.isEmpty { return false }

        guard let viewModel = viewModels[instance.viewModelId] else { return false }
        guard let property = resolveProperty(in: viewModel.properties, segments: segments) else {
            return false
        }
        return property.type == .trigger
    }

    public func hydrate(_ snapshot: FlowViewModelSnapshot) {
        instances.removeAll()
        instancesByViewModel.removeAll()

        for instance in snapshot.viewModelInstances {
            let state = FlowViewModelInstanceState(
                viewModelId: instance.viewModelId,
                instanceId: instance.instanceId,
                name: instance.name,
                values: instance.values
            )
            instances[state.instanceId] = state
            var list = instancesByViewModel[state.viewModelId] ?? []
            list.append(state.instanceId)
            instancesByViewModel[state.viewModelId] = list
            applyViewModelDefaults(instanceId: state.instanceId)
        }

        for viewModel in remoteFlow.viewModels {
            if (instancesByViewModel[viewModel.id] ?? []).isEmpty {
                let blank = createBlankInstance(for: viewModel.id)
                instances[blank.instanceId] = blank
                instancesByViewModel[viewModel.id] = [blank.instanceId]
            }
        }
    }

    public func setValue(
        path: VmPathRef,
        value: Any,
        screenId: String?
    ) -> Bool {
        guard var instance = resolveInstance(screenId: screenId, viewModelId: nil, instanceId: nil) else {
            return false
        }

        let normalized = resolvePathString(path)
        let segments = parsePathSegments(normalized)
        let resolvedValue = resolveLiteralValue(value)

        if segments.isEmpty {
            instance.values[normalized] = AnyCodable(resolvedValue)
            instances[instance.instanceId] = instance
            return true
        }

        let base = instance.values.mapValues { $0.value }
        let updated = setNestedValue(current: base, segments: segments, value: resolvedValue, screenId: screenId)
        if let dict = updated as? [String: Any] {
            instance.values = dict.mapValues { AnyCodable($0) }
        } else if let dict = updated as? [String: AnyCodable] {
            instance.values = dict
        }
        instances[instance.instanceId] = instance
        return true
    }

    public func getValue(path: VmPathRef, screenId: String?) -> Any? {
        guard let instance = resolveInstance(screenId: screenId, viewModelId: nil, instanceId: nil) else {
            return nil
        }

        let normalized = resolvePathString(path)
        let segments = parsePathSegments(normalized)

        if segments.isEmpty {
            return instance.values[normalized]?.value
        }

        var current: Any = instance.values
        for segment in segments {
            switch segment {
            case .prop(let name):
                if let dict = current as? [String: AnyCodable] {
                    current = dict[name]?.value as Any
                } else if let dict = current as? [String: Any] {
                    current = dict[name] as Any
                } else {
                    return nil
                }
            case .index(let expr):
                guard let index = resolveIndex(expr: expr, screenId: screenId) else {
                    return nil
                }
                if let list = current as? [AnyCodable], index < list.count {
                    current = list[index].value
                } else if let list = current as? [Any], index < list.count {
                    current = list[index]
                } else {
                    return nil
                }
            }
        }

        return current
    }

    public func setListValue(
        path: VmPathRef,
        operation: String,
        payload: [String: Any],
        screenId: String?
    ) -> Bool {
        guard var instance = resolveInstance(screenId: screenId, viewModelId: nil, instanceId: nil) else {
            return false
        }

        let normalized = resolvePathString(path)
        let segments = parsePathSegments(normalized)
        guard !segments.isEmpty else { return false }

        var current: Any = instance.values
        for segment in segments.dropLast() {
            switch segment {
            case .prop(let name):
                if let dict = current as? [String: AnyCodable] {
                    current = dict[name]?.value as Any
                } else if let dict = current as? [String: Any] {
                    current = dict[name] as Any
                } else {
                    return false
                }
            case .index(let expr):
                guard let index = resolveIndex(expr: expr, screenId: screenId) else { return false }
                if let list = current as? [AnyCodable], index < list.count {
                    current = list[index].value
                } else if let list = current as? [Any], index < list.count {
                    current = list[index]
                } else {
                    return false
                }
            }
        }

        guard let lastSegment = segments.last else { return false }
        if case .prop(let name) = lastSegment {
            let list = (current as? [String: AnyCodable])?[name]?.value ?? (current as? [String: Any])?[name]
            var array = (list as? [Any]) ?? []

            switch operation {
            case "insert":
                if let index = payload["index"] as? Int {
                    let value = payload["value"] ?? NSNull()
                    let idx = max(0, min(index, array.count))
                    array.insert(value, at: idx)
                } else if let value = payload["value"] {
                    array.append(value)
                }
            case "remove":
                if let index = payload["index"] as? Int, index >= 0, index < array.count {
                    array.remove(at: index)
                }
            case "swap":
                if let from = payload["from"] as? Int, let to = payload["to"] as? Int,
                   from >= 0, to >= 0, from < array.count, to < array.count {
                    array.swapAt(from, to)
                }
            case "move":
                if let from = payload["from"] as? Int, let to = payload["to"] as? Int,
                   from >= 0, to >= 0, from < array.count, to <= array.count {
                    let item = array.remove(at: from)
                    let target = min(max(to, 0), array.count)
                    array.insert(item, at: target)
                }
            case "set":
                if let index = payload["index"] as? Int, index >= 0, index < array.count {
                    array[index] = payload["value"] ?? NSNull()
                }
            case "clear":
                array.removeAll()
            default:
                return false
            }

            instance.values[name] = AnyCodable(array)
            instances[instance.instanceId] = instance
            return true
        }

        return false
    }

    public func allInstances() -> [ViewModelInstance] {
        return instances.values.map { state in
            ViewModelInstance(
                viewModelId: state.viewModelId,
                instanceId: state.instanceId,
                name: state.name,
                values: state.values
            )
        }
    }

    public func screenDefaultsPayload() -> [String: [String: String]] {
        var payload: [String: [String: String]] = [:]
        for (screenId, defaults) in screenDefaults {
            var entry: [String: String] = [:]
            if let viewModelId = defaults.defaultViewModelId {
                entry["defaultViewModelId"] = viewModelId
            }
            if let instanceId = defaults.defaultInstanceId {
                entry["defaultInstanceId"] = instanceId
            }
            if !entry.isEmpty {
                payload[screenId] = entry
            }
        }
        return payload
    }

    private func resolveInstance(
        screenId: String?,
        viewModelId: String?,
        instanceId: String?
    ) -> FlowViewModelInstanceState? {
        if let instanceId, let instance = instances[instanceId] {
            return instance
        }

        if let viewModelId,
           let defaultInstanceId = instancesByViewModel[viewModelId]?.first,
           let defaultInstance = instances[defaultInstanceId] {
            return defaultInstance
        }

        if let screenId, let defaults = screenDefaults[screenId] {
            if let instanceId = defaults.defaultInstanceId, let instance = instances[instanceId] {
                return instance
            }
            if let viewModelId = defaults.defaultViewModelId,
               let instanceId = instancesByViewModel[viewModelId]?.first,
               let instance = instances[instanceId] {
                return instance
            }
        }

        if let first = instances.values.first {
            return first
        }

        return nil
    }

    private func resolvePathString(_ path: VmPathRef) -> String {
        switch path {
        case .path(let raw):
            return raw
        case .ids(let ids):
            let key = "ids:\(ids.map(String.init).joined(separator: "."))"
            return pathIndexByIds()[key] ?? key
        case .raw(let raw):
            return raw
        }
    }

    private func pathIndexByIds() -> [String: String] {
        guard let index = remoteFlow.pathIndex else { return [:] }
        var lookup: [String: String] = [:]
        for (path, entry) in index {
            let key = "ids:\(entry.pathIds.map(String.init).joined(separator: "."))"
            lookup[key] = path
        }
        return lookup
    }

    private func resolveProperty(
        in schema: [String: ViewModelProperty],
        segments: [PathSegment]
    ) -> ViewModelProperty? {
        guard let first = segments.first else { return nil }
        guard case .prop(let name) = first else { return nil }
        guard let property = schema[name] else { return nil }
        let remaining = Array(segments.dropFirst())
        return resolveProperty(property: property, remaining: remaining)
    }

    private func resolveProperty(
        property: ViewModelProperty,
        remaining: [PathSegment]
    ) -> ViewModelProperty? {
        if remaining.isEmpty { return property }

        switch property.type {
        case .object:
            guard let schema = property.schema else { return nil }
            return resolveProperty(in: schema, segments: remaining)
        case .viewModel:
            guard let viewModelId = property.viewModelId,
                  let viewModel = viewModels[viewModelId] else { return nil }
            return resolveProperty(in: viewModel.properties, segments: remaining)
        case .list:
            guard let next = remaining.first, case .index = next else { return nil }
            guard let itemType = property.itemType else { return nil }
            return resolveProperty(property: itemType, remaining: Array(remaining.dropFirst()))
        default:
            return nil
        }
    }

    private func parsePathSegments(_ path: String) -> [PathSegment] {
        let trimmed = stripVmPrefix(path)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.hasPrefix("ids:") {
            return [.prop(trimmed)]
        }

        var segments: [PathSegment] = []
        var index = trimmed.startIndex

        func readIdentifier() -> String? {
            let start = index
            while index < trimmed.endIndex {
                let char = trimmed[index]
                if char == "." || char == "[" { break }
                index = trimmed.index(after: index)
            }
            return start == index ? nil : String(trimmed[start..<index])
        }

        guard let first = readIdentifier() else { return [] }
        segments.append(.prop(first))

        while index < trimmed.endIndex {
            let char = trimmed[index]
            if char == "." {
                index = trimmed.index(after: index)
                if let name = readIdentifier() {
                    segments.append(.prop(name))
                }
                continue
            }
            if char == "[" {
                index = trimmed.index(after: index)
                let start = index
                var depth = 1
                while index < trimmed.endIndex && depth > 0 {
                    let next = trimmed[index]
                    if next == "[" { depth += 1 }
                    if next == "]" { depth -= 1 }
                    if depth == 0 { break }
                    index = trimmed.index(after: index)
                }
                if depth != 0 { break }
                let expr = String(trimmed[start..<index]).trimmingCharacters(in: .whitespaces)
                index = trimmed.index(after: index)
                segments.append(.index(expr))
                continue
            }
            break
        }

        return segments
    }

    private func stripVmPrefix(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("vm.") {
            trimmed = String(trimmed.dropFirst(3))
        } else if trimmed.hasPrefix("vm/") {
            trimmed = String(trimmed.dropFirst(3))
        }
        return trimmed
    }

    private func resolveLiteralValue(_ value: Any) -> Any {
        if let dict = value as? [String: Any],
           let literal = dict["literal"] {
            return literal
        }
        if let dict = value as? [String: AnyCodable],
           let literal = dict["literal"]?.value {
            return literal
        }
        return value
    }

    private func resolveIndex(expr: String, screenId: String?) -> Int? {
        if let value = Int(expr.trimmingCharacters(in: .whitespaces)) {
            return value
        }
        let ref = VmPathRef.path(expr)
        if let value = getValue(path: ref, screenId: screenId) {
            if let number = value as? Int { return number }
            if let number = value as? Double { return Int(number) }
            if let string = value as? String, let number = Int(string) { return number }
        }
        return nil
    }

    private func setNestedValue(
        current: Any,
        segments: [PathSegment],
        value: Any,
        screenId: String?
    ) -> Any {
        guard let segment = segments.first else { return value }

        switch segment {
        case .prop(let name):
            var base: [String: Any] = [:]
            if let dict = current as? [String: Any] {
                base = dict
            } else if let dict = current as? [String: AnyCodable] {
                base = dict.mapValues { $0.value }
            }
            let existing = base[name] ?? NSNull()
            base[name] = setNestedValue(
                current: existing,
                segments: Array(segments.dropFirst()),
                value: value,
                screenId: screenId
            )
            return base
        case .index(let expr):
            guard let index = resolveIndex(expr: expr, screenId: screenId) else { return current }
            var list: [Any] = []
            if let array = current as? [Any] {
                list = array
            } else if let array = current as? [AnyCodable] {
                list = array.map { $0.value }
            }
            if index < list.count {
                list[index] = setNestedValue(
                    current: list[index],
                    segments: Array(segments.dropFirst()),
                    value: value,
                    screenId: screenId
                )
            } else {
                while list.count < index { list.append(NSNull()) }
                list.append(
                    setNestedValue(
                        current: NSNull(),
                        segments: Array(segments.dropFirst()),
                        value: value,
                        screenId: screenId
                    )
                )
            }
            return list
        }
    }

    private func applyViewModelDefaults(instanceId: String) {
        guard var instance = instances[instanceId] else { return }
        guard let viewModel = viewModels[instance.viewModelId] else { return }

        var values = instance.values
        applyDefaults(schema: viewModel.properties, target: &values)
        instance.values = values
        instances[instanceId] = instance
    }

    private func applyDefaults(
        schema: [String: ViewModelProperty],
        target: inout [String: AnyCodable]
    ) {
        for (key, property) in schema {
            if property.type == .object, let schema = property.schema {
                let existing = target[key]?.value as? [String: Any]
                var nested = existing?.mapValues { AnyCodable($0) } ?? [:]
                applyDefaults(schema: schema, target: &nested)
                if !nested.isEmpty {
                    target[key] = AnyCodable(nested.mapValues { $0.value })
                }
                continue
            }

            if target[key] == nil, let defaultValue = property.defaultValue {
                target[key] = defaultValue
            }
        }
    }

    private func createBlankInstance(for viewModelId: String) -> FlowViewModelInstanceState {
        let instanceId = "\(viewModelId)_default"
        var values: [String: AnyCodable] = [:]
        if let viewModel = viewModels[viewModelId] {
            applyDefaults(schema: viewModel.properties, target: &values)
        }
        let state = FlowViewModelInstanceState(
            viewModelId: viewModelId,
            instanceId: instanceId,
            name: "default",
            values: values
        )
        return state
    }
}
