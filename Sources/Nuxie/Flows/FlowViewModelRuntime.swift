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

private let fnvOffsetBasis: UInt32 = 0x811c9dc5
private let fnvPrime: UInt32 = 0x01000193

private func hashNameId(_ value: String) -> Int {
    if value.isEmpty { return Int(fnvOffsetBasis) }
    var hash = fnvOffsetBasis
    for byte in value.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* fnvPrime
    }
    return Int(hash)
}

private struct ResolvedPathInfo {
    let instance: FlowViewModelInstanceState?
    let segments: [PathSegment]
    let rawPath: String
    let viewModel: ViewModel?
}

public final class FlowViewModelRuntime {
    private let remoteFlow: RemoteFlow
    private var viewModels: [String: ViewModel] = [:]
    private var viewModelList: [ViewModel] = []
    private var instances: [String: FlowViewModelInstanceState] = [:]
    private var instancesByViewModel: [String: [String]] = [:]
    private var screenDefaults: [String: (defaultViewModelId: String?, defaultInstanceId: String?)] = [:]

    public init(remoteFlow: RemoteFlow) {
        self.remoteFlow = remoteFlow
        self.viewModelList = remoteFlow.viewModels

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
        let resolved = resolvePathInfo(path, screenId: screenId, instanceId: nil)
        guard let instance = resolved.instance else { return false }
        if resolved.segments.isEmpty { return false }

        let viewModel = resolved.viewModel ?? viewModels[instance.viewModelId]
        guard let viewModel else { return false }
        guard let property = resolveProperty(in: viewModel.properties, segments: resolved.segments) else {
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
        screenId: String?,
        instanceId: String? = nil
    ) -> Bool {
        let resolved = resolvePathInfo(path, screenId: screenId, instanceId: instanceId)
        guard var instance = resolved.instance else { return false }

        let segments = resolved.segments
        let resolvedValue = resolveLiteralValue(value)

        if segments.isEmpty {
            instance.values[resolved.rawPath] = AnyCodable(resolvedValue)
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

    public func getValue(path: VmPathRef, screenId: String?, instanceId: String? = nil) -> Any? {
        let resolved = resolvePathInfo(path, screenId: screenId, instanceId: instanceId)
        guard let instance = resolved.instance else { return nil }

        let segments = resolved.segments

        if segments.isEmpty {
            return instance.values[resolved.rawPath]?.value
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
                guard let index = resolveIndex(expr: expr) else {
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
        screenId: String?,
        instanceId: String? = nil
    ) -> Bool {
        let resolved = resolvePathInfo(path, screenId: screenId, instanceId: instanceId)
        guard var instance = resolved.instance else { return false }

        let segments = resolved.segments
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
                guard let index = resolveIndex(expr: expr) else { return false }
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

    private func resolvePathInfo(
        _ path: VmPathRef,
        screenId: String?,
        instanceId: String?
    ) -> ResolvedPathInfo {
        switch path {
        case .ids(let ref):
            let resolved: (viewModelId: String, segments: [PathSegment])?
            if ref.isRelative == true || ref.nameBased == true {
                resolved = resolveNamePathIds(ref, screenId: screenId)
            } else {
                resolved = resolvePathIds(ref.pathIds)
            }
            if let resolved {
                let resolvedInstanceId = ref.isRelative == true ? instanceId : nil
                let instance = resolveInstance(
                    screenId: screenId,
                    viewModelId: resolved.viewModelId,
                    instanceId: resolvedInstanceId
                )
                return ResolvedPathInfo(
                    instance: instance,
                    segments: resolved.segments,
                    rawPath: path.normalizedPath,
                    viewModel: viewModels[resolved.viewModelId]
                )
            }
            return ResolvedPathInfo(
                instance: nil,
                segments: [],
                rawPath: path.normalizedPath,
                viewModel: nil
            )
        }
    }

    private func resolvePathIds(
        _ pathIds: [Int]
    ) -> (viewModelId: String, segments: [PathSegment])? {
        guard let viewModelIndex = pathIds.first else { return nil }
        guard viewModelIndex >= 0, viewModelIndex < viewModelList.count else { return nil }
        let viewModel = viewModelList[viewModelIndex]
        let propertyIds = Array(pathIds.dropFirst())
        guard !propertyIds.isEmpty else { return nil }

        var schema = viewModel.properties
        var segments: [PathSegment] = []

        for (idx, propertyId) in propertyIds.enumerated() {
            guard let found = findPropertyById(in: schema, propertyId: propertyId) else {
                return nil
            }
            segments.append(.prop(found.name))

            if idx == propertyIds.count - 1 { continue }
            switch found.property.type {
            case .object:
                guard let nested = found.property.schema else { return nil }
                schema = nested
            case .viewModel:
                guard let nestedId = found.property.viewModelId,
                      let nested = viewModels[nestedId] else { return nil }
                schema = nested.properties
            case .list:
                return nil
            default:
                return nil
            }
        }

        return (viewModel.id, segments)
    }

    private func resolveNamePathIds(
        _ ref: VmPathIds,
        screenId: String?
    ) -> (viewModelId: String, segments: [PathSegment])? {
        let pathIds = ref.pathIds
        guard !pathIds.isEmpty else { return nil }

        let viewModel: ViewModel?
        let propertyIds: [Int]

        if ref.isRelative == true {
            guard let instance = resolveInstance(screenId: screenId, viewModelId: nil, instanceId: nil) else {
                return nil
            }
            viewModel = viewModels[instance.viewModelId]
            propertyIds = pathIds
        } else {
            let viewModelNameId = pathIds[0]
            viewModel = viewModelList.first { hashNameId($0.name) == viewModelNameId }
            propertyIds = Array(pathIds.dropFirst())
        }

        guard let viewModel, !propertyIds.isEmpty else { return nil }

        var schema = viewModel.properties
        var segments: [PathSegment] = []

        for (idx, nameId) in propertyIds.enumerated() {
            guard let found = findPropertyByNameId(in: schema, nameId: nameId) else {
                return nil
            }
            segments.append(.prop(found.name))

            if idx == propertyIds.count - 1 { continue }
            switch found.property.type {
            case .object:
                guard let nested = found.property.schema else { return nil }
                schema = nested
            case .viewModel:
                guard let nestedId = found.property.viewModelId,
                      let nested = viewModels[nestedId] else { return nil }
                schema = nested.properties
            case .list:
                return nil
            default:
                return nil
            }
        }

        return (viewModel.id, segments)
    }

    private func findPropertyById(
        in schema: [String: ViewModelProperty],
        propertyId: Int
    ) -> (name: String, property: ViewModelProperty)? {
        for (name, property) in schema {
            if property.propertyId == propertyId {
                return (name, property)
            }
        }
        return nil
    }

    private func findPropertyByNameId(
        in schema: [String: ViewModelProperty],
        nameId: Int
    ) -> (name: String, property: ViewModelProperty)? {
        for (name, property) in schema {
            if hashNameId(name) == nameId {
                return (name, property)
            }
        }
        return nil
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

    private func resolveIndex(expr: String) -> Int? {
        if let value = Int(expr.trimmingCharacters(in: .whitespaces)) {
            return value
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
            guard let index = resolveIndex(expr: expr) else { return current }
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
