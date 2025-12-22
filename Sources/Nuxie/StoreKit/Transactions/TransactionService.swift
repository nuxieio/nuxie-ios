import Foundation
import StoreKit
import FactoryKit

/// Service responsible for managing StoreKit transactions
public actor TransactionService {
    @Injected(\.productService) private var productService: ProductService
    
    /// Purchase delegate from configuration
    private var purchaseDelegate: NuxiePurchaseDelegate? {
        NuxieSDK.shared.configuration?.purchaseDelegate
    }
    
    public init() {}
    
    /// Purchase a product
    /// - Parameter product: The product to purchase
    /// - Throws: StoreKitError if purchase fails or delegate not configured
    public func purchase(_ product: any StoreProductProtocol) async throws {
        guard let delegate = purchaseDelegate else {
            LogError("TransactionService: No purchase delegate configured")
            throw StoreKitError.notConfigured
        }
        
        LogDebug("TransactionService: Starting purchase for product: \(product.id)")
        
        let result = await delegate.purchase(product)
        
        switch result {
        case .success:
            LogInfo("TransactionService: Purchase completed successfully for product: \(product.id)")
            // Track successful purchase event
            NuxieSDK.shared.track("$purchase_completed", properties: [
                "product_id": product.id,
                "price": NSDecimalNumber(decimal: product.price).doubleValue,
                "display_price": product.displayPrice
            ])
            
        case .cancelled:
            LogInfo("TransactionService: Purchase cancelled by user for product: \(product.id)")
            throw StoreKitError.purchaseCancelled
            
        case .failed(let error):
            LogError("TransactionService: Purchase failed for product: \(product.id), error: \(error)")
            // Track failed purchase event
            NuxieSDK.shared.track("$purchase_failed", properties: [
                "product_id": product.id,
                "error": error.localizedDescription
            ])
            throw StoreKitError.purchaseFailed(error)
            
        case .pending:
            LogInfo("TransactionService: Purchase pending for product: \(product.id)")
            throw StoreKitError.purchasePending
        }
    }
    
    /// Restore previous purchases
    /// - Throws: StoreKitError if restore fails or delegate not configured
    public func restore() async throws {
        guard let delegate = purchaseDelegate else {
            LogError("TransactionService: No purchase delegate configured for restore")
            throw StoreKitError.notConfigured
        }
        
        LogDebug("TransactionService: Starting restore purchases")
        
        let result = await delegate.restore()
        
        switch result {
        case .success(let restoredCount):
            LogInfo("TransactionService: Restore completed successfully, restored \(restoredCount) purchases")
            // Track successful restore event
            NuxieSDK.shared.track("$restore_completed", properties: [
                "restored_count": restoredCount
            ])
            
        case .failed(let error):
            LogError("TransactionService: Restore failed, error: \(error)")
            // Track failed restore event
            NuxieSDK.shared.track("$restore_failed", properties: [
                "error": error.localizedDescription
            ])
            throw StoreKitError.restoreFailed(error)
            
        case .noPurchases:
            LogInfo("TransactionService: No purchases to restore")
            // Track no purchases event
            NuxieSDK.shared.track("$restore_no_purchases")
        }
    }
}