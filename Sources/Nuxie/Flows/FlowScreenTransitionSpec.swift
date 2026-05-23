import Foundation

struct FlowScreenTransitionSpec: Equatable {
    enum Kind: String {
        case none
        case push
        case modal
        case fade
        case custom
    }

    let kind: Kind
    let transitionId: String?

    var isAnimated: Bool {
        kind == .push || kind == .modal || kind == .fade
    }

    static let none = FlowScreenTransitionSpec(kind: .none, transitionId: nil)

    init(kind: Kind, transitionId: String? = nil) {
        self.kind = kind
        self.transitionId = transitionId
    }

    init(raw: Any?) {
        guard let record = FlowScreenTransitionSpec.transitionRecord(from: raw) else {
            self = .none
            return
        }

        let kind = FlowScreenTransitionSpec.kind(from: record["type"])
        self.init(
            kind: kind,
            transitionId: kind == .custom
                ? FlowScreenTransitionSpec.string(from: record["transitionId"])
                : nil
        )
    }

    private static func transitionRecord(from raw: Any?) -> [String: Any]? {
        if let anyCodable = raw as? AnyCodable {
            return transitionRecord(from: anyCodable.value)
        }
        return raw as? [String: Any]
    }

    private static func kind(from raw: Any?) -> Kind {
        guard let raw = raw as? String else { return .none }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none":
            return .none
        case "push":
            return .push
        case "modal":
            return .modal
        case "fade":
            return .fade
        case "custom":
            return .custom
        default:
            return .none
        }
    }

    private static func string(from raw: Any?) -> String? {
        if let value = raw as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = raw as? AnyCodable {
            return string(from: value.value)
        }
        return nil
    }
}
