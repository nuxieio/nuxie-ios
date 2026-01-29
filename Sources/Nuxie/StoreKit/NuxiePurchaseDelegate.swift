import Foundation
import StoreKit

/// Result type for purchase operations
public enum PurchaseResult: Equatable {
    /// Purchase completed successfully
    case success
    /// User cancelled the purchase
    case cancelled
    /// Purchase failed with error
    case failed(Error)
    /// Purchase is pending (e.g., waiting for parental approval)
    case pending
    
    public static func == (lhs: PurchaseResult, rhs: PurchaseResult) -> Bool {
        switch (lhs, rhs) {
        case (.success, .success):
            return true
        case (.cancelled, .cancelled):
            return true
        case (.pending, .pending):
            return true
        case (.failed(let lhsError), .failed(let rhsError)):
            return (lhsError as NSError) == (rhsError as NSError)
        default:
            return false
        }
    }
}

/// Result type for restore operations
public enum RestoreResult: Equatable {
    /// Restore completed successfully with count of restored items
    case success(restoredCount: Int)
    /// Restore failed with error
    case failed(Error)
    /// No purchases to restore
    case noPurchases
    
    public static func == (lhs: RestoreResult, rhs: RestoreResult) -> Bool {
        switch (lhs, rhs) {
        case (.success(let lhsCount), .success(let rhsCount)):
            return lhsCount == rhsCount
        case (.noPurchases, .noPurchases):
            return true
        case (.failed(let lhsError), .failed(let rhsError)):
            return (lhsError as NSError) == (rhsError as NSError)
        default:
            return false
        }
    }
}

/// Protocol for handling purchases in the host application
/// The host app implements this to provide custom purchase logic
public protocol NuxiePurchaseDelegate: AnyObject {
    
    /// Purchase a product
    /// - Parameter product: The StoreKit product to purchase
    /// - Returns: Result of the purchase operation
    func purchase(_ product: any StoreProductProtocol) async -> PurchaseResult
    
    /// Restore previous purchases
    /// - Returns: Result of the restore operation
    func restore() async -> RestoreResult
}