import Foundation

struct FlowScreenTransitionSpec: Equatable {
    enum Kind: String {
        case instant
        case dissolve
        case moveIn = "move_in"
        case moveOut = "move_out"
        case push
        case slideIn = "slide_in"
        case slideOut = "slide_out"
    }

    enum Direction: String {
        case left
        case right
        case up
        case down

        var reversed: Direction {
            switch self {
            case .left:
                return .right
            case .right:
                return .left
            case .up:
                return .down
            case .down:
                return .up
            }
        }
    }

    enum Easing: String {
        case linear
        case easeIn = "ease_in"
        case easeOut = "ease_out"
        case easeInOut = "ease_in_out"
    }

    let kind: Kind
    let direction: Direction
    let duration: TimeInterval
    let easing: Easing

    var isAnimated: Bool {
        kind != .instant && duration > 0
    }

    static let instant = FlowScreenTransitionSpec(
        kind: .instant,
        direction: .right,
        duration: 0,
        easing: .easeInOut
    )

    init(
        kind: Kind,
        direction: Direction = .right,
        duration: TimeInterval = 0.3,
        easing: Easing = .easeInOut
    ) {
        self.kind = kind
        self.direction = direction
        self.duration = max(0, duration)
        self.easing = easing
    }

    init(raw: Any?) {
        guard let record = FlowScreenTransitionSpec.transitionRecord(from: raw) else {
            self = .instant
            return
        }

        self.init(
            kind: FlowScreenTransitionSpec.kind(from: record["type"]),
            direction: FlowScreenTransitionSpec.direction(from: record["direction"]) ?? .right,
            duration: FlowScreenTransitionSpec.duration(from: record),
            easing: FlowScreenTransitionSpec.easing(from: record["easing"])
        )
    }

    private static func transitionRecord(from raw: Any?) -> [String: Any]? {
        if let anyCodable = raw as? AnyCodable {
            return transitionRecord(from: anyCodable.value)
        }
        return raw as? [String: Any]
    }

    private static func kind(from raw: Any?) -> Kind {
        guard let raw = raw as? String else { return .instant }
        switch normalizeToken(raw) {
        case "none", "instant":
            return .instant
        case "dissolve", "smart_animate":
            return .dissolve
        case "move_in":
            return .moveIn
        case "move_out":
            return .moveOut
        case "push":
            return .push
        case "slide_in":
            return .slideIn
        case "slide_out":
            return .slideOut
        default:
            return .instant
        }
    }

    private static func direction(from raw: Any?) -> Direction? {
        guard let raw = raw as? String else { return nil }
        switch normalizeToken(raw) {
        case "left":
            return .left
        case "right":
            return .right
        case "up", "top":
            return .up
        case "down", "bottom":
            return .down
        default:
            return nil
        }
    }

    private static func duration(from record: [String: Any]) -> TimeInterval {
        let raw = record["durationMs"] ?? record["duration_ms"] ?? record["duration"]
        let milliseconds = double(from: raw) ?? 300
        return max(0, milliseconds) / 1000
    }

    private static func easing(from raw: Any?) -> Easing {
        let rawType: Any?
        if let record = raw as? [String: Any] {
            rawType = record["type"] ?? record["kind"]
        } else if let anyCodable = raw as? AnyCodable {
            return easing(from: anyCodable.value)
        } else {
            rawType = raw
        }

        guard let rawType = rawType as? String else { return .easeInOut }
        switch normalizeToken(rawType) {
        case "linear":
            return .linear
        case "ease_in":
            return .easeIn
        case "ease_out":
            return .easeOut
        default:
            return .easeInOut
        }
    }

    private static func double(from raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Float { return Double(value) }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        if let value = raw as? AnyCodable { return double(from: value.value) }
        return nil
    }

    private static func normalizeToken(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }
}
