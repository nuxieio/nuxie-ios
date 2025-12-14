import Foundation

// MARK: - Feature Access

/// Result of a feature access check
/// Provides a simplified view for SDK consumers
public struct FeatureAccess: Sendable {
    /// Whether the user is allowed to use this feature
    public let allowed: Bool

    /// Whether the feature has unlimited access (no balance tracking)
    public let unlimited: Bool

    /// Current balance (nil if unlimited or boolean feature)
    public let balance: Int?

    /// The feature type
    public let type: FeatureType

    /// Convenience: returns true if allowed
    public var hasAccess: Bool { allowed }

    /// Convenience: returns true if unlimited or balance > 0
    public var hasBalance: Bool {
        unlimited || (balance ?? 0) > 0
    }

    /// Create from a cached Feature (from profile response)
    init(from feature: Feature, requiredBalance: Int = 1) {
        self.type = feature.type
        self.unlimited = feature.unlimited
        self.balance = feature.balance

        switch feature.type {
        case .boolean:
            // Boolean features: just check presence
            self.allowed = true
        case .metered, .creditSystem:
            // Metered/Credit: check balance or unlimited
            if feature.unlimited {
                self.allowed = true
            } else {
                self.allowed = (feature.balance ?? 0) >= requiredBalance
            }
        }
    }

    /// Create from a FeatureCheckResult (from real-time API)
    init(from result: FeatureCheckResult) {
        self.allowed = result.allowed
        self.unlimited = result.unlimited
        self.balance = result.balance
        self.type = result.type
    }

    /// Create a "not found" result
    static var notFound: FeatureAccess {
        FeatureAccess(allowed: false, unlimited: false, balance: nil, type: .boolean)
    }

    private init(allowed: Bool, unlimited: Bool, balance: Int?, type: FeatureType) {
        self.allowed = allowed
        self.unlimited = unlimited
        self.balance = balance
        self.type = type
    }
}

// MARK: - Feature Check Result

/// Response from the real-time /entitled endpoint
public struct FeatureCheckResult: Codable, Sendable {
    public let customerId: String
    public let featureId: String
    public let requiredBalance: Int
    public let code: String
    public let allowed: Bool
    public let unlimited: Bool
    public let balance: Int?
    public let type: FeatureType
    public let preview: AnyCodable?
}

// MARK: - Feature Check Request

/// Request parameters for entitlement check
struct FeatureCheckRequest: Codable {
    let customerId: String
    let featureId: String
    let requiredBalance: Int?
    let entityId: String?
}
