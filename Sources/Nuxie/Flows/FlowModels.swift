import Foundation

// MARK: - Client-Side Flow Model

/// Client-side flow model that enriches RemoteFlow with local state and product data
public struct Flow {
    // IMPORTANT: RemoteFlow is immutable server data - never modify
    public let remoteFlow: RemoteFlow              // Original data from ProfileManager/API
    
    // Client-side enrichments
    public var products: [FlowProduct]         // Products fetched from StoreKit
    
    // Convenience accessors proxy to remoteFlow for common properties
    public var id: String { remoteFlow.id }
    public var name: String { remoteFlow.name }
    public var manifest: BuildManifest { remoteFlow.manifest }
    public var url: String { remoteFlow.url }
    
    // Validation
    public var isValid: Bool {
        !products.isEmpty
    }
    
    public init(
        remoteFlow: RemoteFlow,
        products: [FlowProduct] = []
    ) {
        self.remoteFlow = remoteFlow
        self.products = products
    }
}

// MARK: - Loading State

public enum LoadingState: Equatable {
    case notLoaded
    case loading(progress: Double)
    case loaded
    case failed(Error)
    
    public static func == (lhs: LoadingState, rhs: LoadingState) -> Bool {
        switch (lhs, rhs) {
        case (.notLoaded, .notLoaded), (.loaded, .loaded):
            return true
        case let (.loading(p1), .loading(p2)):
            return p1 == p2
        case let (.failed(e1), .failed(e2)):
            return (e1 as NSError) == (e2 as NSError)
        default:
            return false
        }
    }
}

// MARK: - Presentation State

public enum PresentationState: Equatable {
    case notPresented
    case presenting
    case presented
    case dismissed
}

// MARK: - Close Reason

public enum CloseReason: Equatable {
    case userDismissed
    case purchaseCompleted
    case timeout
    case error(Error)
    
    public static func == (lhs: CloseReason, rhs: CloseReason) -> Bool {
        switch (lhs, rhs) {
        case (.userDismissed, .userDismissed),
             (.purchaseCompleted, .purchaseCompleted),
             (.timeout, .timeout):
            return true
        case let (.error(e1), .error(e2)):
            return (e1 as NSError) == (e2 as NSError)
        default:
            return false
        }
    }
}

// MARK: - Product Period

public enum ProductPeriod: String, Codable, Equatable {
    case week
    case month
    case year
    case lifetime
}

// MARK: - Flow Product

/// Product with StoreKit data and flow metadata
public struct FlowProduct: Equatable, Codable {
    public let id: String
    public let name: String
    public let price: String  // Formatted price string (e.g., "$9.99")
    public let period: ProductPeriod?
}

// MARK: - Flow Subscription Period

public enum FlowSubscriptionPeriod: Equatable, Codable {
    case day(Int)
    case week(Int)
    case month(Int)
    case year(Int)
    
    public var description: String {
        switch self {
        case .day(let count):
            return count == 1 ? "day" : "\(count) days"
        case .week(let count):
            return count == 1 ? "week" : "\(count) weeks"
        case .month(let count):
            return count == 1 ? "month" : "\(count) months"
        case .year(let count):
            return count == 1 ? "year" : "\(count) years"
        }
    }
}

// MARK: - Introductory Offer

public struct IntroductoryOffer: Equatable, Codable {
    public let displayPrice: String
    public let period: FlowSubscriptionPeriod
    public let numberOfPeriods: Int
    
    public init(
        displayPrice: String,
        period: FlowSubscriptionPeriod,
        numberOfPeriods: Int
    ) {
        self.displayPrice = displayPrice
        self.period = period
        self.numberOfPeriods = numberOfPeriods
    }
}

// MARK: - Flow Cache Key

/// Composite key for caching flows with variants
public struct FlowCacheKey: Hashable {
    public let id: String
    public let variant: String?
    public let userSegment: String?
    
    public var hash: String {
        "\(id)_\(variant ?? "default")_\(userSegment ?? "all")"
    }
    
    public init(id: String, variant: String? = nil, userSegment: String? = nil) {
        self.id = id
        self.variant = variant
        self.userSegment = userSegment
    }
}

// MARK: - Flow Changes

/// Result of diffing flows between profile updates
public struct FlowChanges {
    public let added: [RemoteFlow]
    public let updated: [RemoteFlow]
    public let removed: [String]  // Just IDs for removals
    
    public var hasChanges: Bool {
        !added.isEmpty || !updated.isEmpty || !removed.isEmpty
    }
    
    public init(added: [RemoteFlow] = [], updated: [RemoteFlow] = [], removed: [String] = []) {
        self.added = added
        self.updated = updated
        self.removed = removed
    }
}