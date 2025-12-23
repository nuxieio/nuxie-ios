import Foundation
import StoreKit
import FactoryKit

/// Service responsible for managing StoreKit transactions
public actor TransactionService {
    @Injected(\.productService) private var productService: ProductService
    @Injected(\.nuxieApi) private var api: NuxieApiProtocol
    @Injected(\.identityService) private var identityService: IdentityServiceProtocol
    @Injected(\.featureService) private var featureService: FeatureServiceProtocol

    /// Maximum retry attempts for backend sync
    private let maxRetryAttempts = 3

    /// Purchase delegate from configuration
    private var purchaseDelegate: NuxiePurchaseDelegate? {
        NuxieSDK.shared.configuration?.purchaseDelegate
    }

    public init() {}

    // MARK: - Public Purchase API

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
            // Get the transaction from StoreKit and sync with backend
            try await handleSuccessfulPurchase(productId: product.id)

        case .cancelled:
            LogInfo("TransactionService: Purchase cancelled by user for product: \(product.id)")
            throw StoreKitError.purchaseCancelled

        case .failed(let error):
            LogError("TransactionService: Purchase failed for product: \(product.id), error: \(error)")
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
            NuxieSDK.shared.track("$restore_completed", properties: [
                "restored_count": restoredCount
            ])
            // Sync current entitlements with backend after restore
            await syncCurrentEntitlements()

        case .failed(let error):
            LogError("TransactionService: Restore failed, error: \(error)")
            NuxieSDK.shared.track("$restore_failed", properties: [
                "error": error.localizedDescription
            ])
            throw StoreKitError.restoreFailed(error)

        case .noPurchases:
            LogInfo("TransactionService: No purchases to restore")
            NuxieSDK.shared.track("$restore_no_purchases")
        }
    }

    // MARK: - Private Transaction Handling

    /// Handle a successful purchase by syncing with backend
    private func handleSuccessfulPurchase(productId: String) async throws {
        // Get the latest transaction for this product from StoreKit
        guard let verificationResult = await Transaction.latest(for: productId) else {
            LogError("TransactionService: Transaction not found for product: \(productId)")
            throw StoreKitError.transactionNotFound
        }

        guard case .verified(let transaction) = verificationResult else {
            LogError("TransactionService: Transaction verification failed for product: \(productId)")
            throw StoreKitError.verificationFailed("Transaction not verified by StoreKit")
        }

        // Get JWS from verification result (available iOS 15+), not from unwrapped transaction
        let jws = verificationResult.jwsRepresentation
        LogInfo("TransactionService: Got verified transaction \(transaction.id) for product: \(productId)")

        // Sync with backend (with retry) BEFORE finishing the transaction
        // This ensures if sync fails, StoreKit will re-deliver the transaction on next launch
        do {
            try await syncTransactionWithBackend(jws: jws, productId: productId)
        } catch {
            LogError("TransactionService: Backend sync failed for transaction \(transaction.id): \(error)")
            // Don't finish the transaction - it will be retried via Transaction.unfinished on next launch
            throw error
        }

        // Only finish the transaction AFTER backend confirms
        await transaction.finish()
        LogInfo("TransactionService: Transaction \(transaction.id) finished successfully")

        // Track successful purchase event
        NuxieSDK.shared.track("$purchase_completed", properties: [
            "product_id": productId,
            "transaction_id": String(transaction.id)
        ])
    }

    /// Sync a transaction with the backend, with retry logic
    private func syncTransactionWithBackend(jws: String, productId: String) async throws {
        let distinctId = identityService.getDistinctId()
        var lastError: Error?

        for attempt in 1...maxRetryAttempts {
            do {
                LogDebug("TransactionService: Syncing transaction with backend (attempt \(attempt)/\(maxRetryAttempts))")

                let response = try await api.syncTransaction(
                    transactionJwt: jws,
                    distinctId: distinctId
                )

                guard response.success else {
                    throw StoreKitError.serverError(statusCode: 400)
                }

                LogInfo("TransactionService: Transaction synced successfully")

                // Update feature cache with returned features
                if let features = response.features {
                    await featureService.updateFromPurchase(features)
                    LogDebug("TransactionService: Updated \(features.count) features from purchase response")
                }

                NuxieSDK.shared.track("$purchase_synced", properties: [
                    "product_id": productId,
                    "customer_id": response.customerId ?? ""
                ])

                return // Success!

            } catch {
                lastError = error
                LogWarning("TransactionService: Sync attempt \(attempt) failed: \(error)")

                if attempt < maxRetryAttempts {
                    // Exponential backoff: 1s, 2s, 4s
                    let delay = UInt64(pow(2.0, Double(attempt - 1))) * 1_000_000_000
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }

        // All retries exhausted
        throw lastError ?? StoreKitError.networkUnavailable
    }

    /// Sync all current entitlements with backend (used after restore)
    private func syncCurrentEntitlements() async {
        let distinctId = identityService.getDistinctId()

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }

            // Get JWS from verification result (available iOS 15+)
            let jws = result.jwsRepresentation

            do {
                let response = try await api.syncTransaction(
                    transactionJwt: jws,
                    distinctId: distinctId
                )

                if response.success {
                    LogDebug("TransactionService: Synced entitlement for product: \(transaction.productID)")
                    if let features = response.features {
                        await featureService.updateFromPurchase(features)
                    }
                }
            } catch {
                LogWarning("TransactionService: Failed to sync entitlement for \(transaction.productID): \(error)")
            }
        }
    }
}