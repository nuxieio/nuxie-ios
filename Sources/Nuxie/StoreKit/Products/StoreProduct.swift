import Foundation
import StoreKit

// MARK: - Product Type

public enum StoreProductType: String, Equatable {
    case consumable
    case nonConsumable
    case autoRenewable
    case nonRenewable
}

// MARK: - Subscription Period

public struct SubscriptionPeriod: Equatable {
    public enum Unit: String, Equatable {
        case day
        case week
        case month
        case year
    }
    
    public let value: Int
    public let unit: Unit
    
    public init(value: Int, unit: Unit) {
        self.value = value
        self.unit = unit
    }
}

// MARK: - Store Product Protocol

/// Protocol for StoreKit products that allows for testing and abstraction
public protocol StoreProductProtocol {
    var id: String { get }
    var displayName: String { get }
    var description: String { get }
    var price: Decimal { get }
    var displayPrice: String { get }
    var isFamilyShareable: Bool { get }
    var productType: StoreProductType { get }
    var subscriptionPeriod: SubscriptionPeriod? { get }
}

// MARK: - StoreKit.Product Extension

extension Product: StoreProductProtocol {
    public var productType: StoreProductType {
        switch self.type {
        case .consumable:
            return .consumable
        case .nonConsumable:
            return .nonConsumable
        case .autoRenewable:
            return .autoRenewable
        case .nonRenewable:
            return .nonRenewable
        default:
            return .nonConsumable
        }
    }
    
    public var subscriptionPeriod: Nuxie.SubscriptionPeriod? {
        guard let subscription = self.subscription else { return nil }
        
        let period = subscription.subscriptionPeriod
        let unit: Nuxie.SubscriptionPeriod.Unit
        
        switch period.unit {
        case .day:
            unit = .day
        case .week:
            unit = .week  
        case .month:
            unit = .month
        case .year:
            unit = .year
        @unknown default:
            return nil
        }
        
        return Nuxie.SubscriptionPeriod(value: period.value, unit: unit)
    }
}

// MARK: - Mock Implementation for Testing

/// Mock product for testing
public struct MockStoreProduct: StoreProductProtocol {
    public let id: String
    public let displayName: String
    public let description: String
    public let price: Decimal
    public let displayPrice: String
    public let isFamilyShareable: Bool
    public let productType: StoreProductType
    public let subscriptionPeriod: SubscriptionPeriod?
    
    public init(
        id: String,
        displayName: String,
        description: String = "",
        price: Decimal,
        displayPrice: String,
        isFamilyShareable: Bool = false,
        productType: StoreProductType = .nonConsumable,
        subscriptionPeriod: SubscriptionPeriod? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.price = price
        self.displayPrice = displayPrice
        self.isFamilyShareable = isFamilyShareable
        self.productType = productType
        self.subscriptionPeriod = subscriptionPeriod
    }
}
