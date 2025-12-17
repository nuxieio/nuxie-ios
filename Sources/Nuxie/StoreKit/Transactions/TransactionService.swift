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
    /// - Throws: StoreKitError if purchase fails
    public func purchase(_ product: any StoreProductProtocol) async throws {
        LogDebug("TransactionService: Starting purchase for product: \(product.id)")

        // If delegate provided, use it (RevenueCat, Superwall, custom)
        if let delegate = purchaseDelegate {
            let result = await delegate.purchase(product)
            try handlePurchaseResult(result, product: product)
            return
        }

        // Otherwise, purchase directly via StoreKit
        try await executePurchase(product)
    }

    // MARK: - Private Purchase Implementation

    private func executePurchase(_ product: any StoreProductProtocol) async throws {
        guard let storeProduct = product.storeKitProduct else {
            LogError("TransactionService: Product has no StoreKit backing")
            throw StoreKitError.productNotFound(product.id)
        }

        let result: Product.PurchaseResult
        do {
            result = try await storeProduct.purchase()
        } catch {
            LogError("TransactionService: Purchase failed for \(product.id): \(error)")
            trackPurchaseFailed(product, error: error)
            throw StoreKitError.purchaseFailed(error)
        }

        switch result {
        case .success(.verified(let transaction)):
            await transaction.finish()
            LogInfo("TransactionService: Purchase verified and finished for \(product.id)")
            trackPurchaseCompleted(product)
            syncEntitlements()

        case .success(.unverified(let transaction, let error)):
            await transaction.finish()
            LogError("TransactionService: Transaction unverified for \(product.id): \(error)")
            trackPurchaseFailed(product, error: error)
            throw StoreKitError.verificationFailed(error.localizedDescription)

        case .userCancelled:
            LogInfo("TransactionService: Purchase cancelled by user for \(product.id)")
            throw StoreKitError.purchaseCancelled

        case .pending:
            LogInfo("TransactionService: Purchase pending for \(product.id)")
            throw StoreKitError.purchasePending

        @unknown default:
            throw StoreKitError.unknown(underlying: nil)
        }
    }

    private func handlePurchaseResult(_ result: PurchaseResult, product: any StoreProductProtocol) throws {
        switch result {
        case .success:
            LogInfo("TransactionService: Purchase completed successfully for product: \(product.id)")
            trackPurchaseCompleted(product)
            syncEntitlements()

        case .cancelled:
            LogInfo("TransactionService: Purchase cancelled by user for product: \(product.id)")
            throw StoreKitError.purchaseCancelled

        case .failed(let error):
            LogError("TransactionService: Purchase failed for product: \(product.id), error: \(error)")
            trackPurchaseFailed(product, error: error)
            throw StoreKitError.purchaseFailed(error)

        case .pending:
            LogInfo("TransactionService: Purchase pending for product: \(product.id)")
            throw StoreKitError.purchasePending
        }
    }

    private func trackPurchaseCompleted(_ product: any StoreProductProtocol) {
        NuxieSDK.shared.track("purchase_completed", properties: [
            "product_id": product.id,
            "price": NSDecimalNumber(decimal: product.price).doubleValue,
            "display_price": product.displayPrice
        ])
    }

    private func trackPurchaseFailed(_ product: any StoreProductProtocol, error: Error) {
        NuxieSDK.shared.track("purchase_failed", properties: [
            "product_id": product.id,
            "error": error.localizedDescription
        ])
    }

    private func syncEntitlements() {
        // Fire-and-forget profile refresh to sync entitlements
        Task {
            do {
                try await Container.shared.profileService().refetchProfile()
                LogDebug("TransactionService: Entitlements synced via profile refresh")
            } catch {
                LogWarning("TransactionService: Failed to sync entitlements: \(error)")
            }
        }
    }
    
    // MARK: - Restore

    /// Restore previous purchases
    /// - Throws: StoreKitError if restore fails
    public func restore() async throws {
        LogDebug("TransactionService: Starting restore purchases")

        // If delegate provided, use it
        if let delegate = purchaseDelegate {
            let result = await delegate.restore()
            try handleRestoreResult(result)
            return
        }

        // Otherwise, restore directly via StoreKit
        try await executeRestore()
    }

    private func executeRestore() async throws {
        var restoredCount = 0
        var lastError: Error?

        for await result in Transaction.all {
            switch result {
            case .verified:
                restoredCount += 1
            case .unverified(_, let error):
                lastError = error
            }
        }

        if restoredCount > 0 {
            LogInfo("TransactionService: Restore completed, found \(restoredCount) purchases")
            NuxieSDK.shared.track("restore_completed", properties: [
                "restored_count": restoredCount
            ])
            syncEntitlements()
        } else if let error = lastError {
            LogError("TransactionService: Restore failed: \(error)")
            NuxieSDK.shared.track("restore_failed", properties: [
                "error": error.localizedDescription
            ])
            throw StoreKitError.restoreFailed(error)
        } else {
            LogInfo("TransactionService: No purchases to restore")
            NuxieSDK.shared.track("restore_no_purchases")
        }
    }

    private func handleRestoreResult(_ result: RestoreResult) throws {
        switch result {
        case .success(let restoredCount):
            LogInfo("TransactionService: Restore completed successfully, restored \(restoredCount) purchases")
            NuxieSDK.shared.track("restore_completed", properties: [
                "restored_count": restoredCount
            ])
            syncEntitlements()

        case .failed(let error):
            LogError("TransactionService: Restore failed, error: \(error)")
            NuxieSDK.shared.track("restore_failed", properties: [
                "error": error.localizedDescription
            ])
            throw StoreKitError.restoreFailed(error)

        case .noPurchases:
            LogInfo("TransactionService: No purchases to restore")
            NuxieSDK.shared.track("restore_no_purchases")
        }
    }
}