import Foundation
import StoreKit
import FactoryKit

/// Observes StoreKit 2 Transaction.updates stream and syncs verified transactions with the backend
///
/// By observing Transaction.updates directly, we catch all purchases regardless of how they
/// were initiated (via SDK, app's own StoreKit code, or even the App Store directly).
internal actor TransactionObserver {

    // MARK: - Dependencies

    @Injected(\.nuxieApi) private var api: NuxieApiProtocol
    @Injected(\.featureService) private var featureService: FeatureServiceProtocol
    @Injected(\.identityService) private var identityService: IdentityServiceProtocol

    // MARK: - Properties

    /// Task observing Transaction.updates
    private var updateTask: Task<Void, Never>?

    /// Set of transaction IDs we've already synced (to avoid duplicates within session)
    private var syncedTransactionIds: Set<String> = []

    // MARK: - Init

    init() {}

    // MARK: - Lifecycle

    /// Start listening to Transaction.updates
    /// Call this during SDK setup
    func startListening() {
        guard updateTask == nil else {
            LogDebug("TransactionObserver: Already listening")
            return
        }

        LogInfo("TransactionObserver: Starting to listen for transaction updates")

        updateTask = Task { [weak self] in
            // First, process any unfinished transactions from previous sessions
            await self?.processUnfinishedTransactions()

            // Then listen for new transaction updates
            for await result in Transaction.updates {
                guard let self = self else { break }
                await self.handleTransactionResult(result)
            }
        }
    }

    /// Stop listening to Transaction.updates
    func stopListening() {
        updateTask?.cancel()
        updateTask = nil
        LogInfo("TransactionObserver: Stopped listening")
    }

    // MARK: - Transaction Processing

    /// Process any unfinished transactions from previous app sessions
    private func processUnfinishedTransactions() async {
        LogDebug("TransactionObserver: Checking for unfinished transactions")

        for await result in Transaction.unfinished {
            await handleTransactionResult(result)
        }

        LogDebug("TransactionObserver: Finished processing unfinished transactions")
    }

    /// Handle a transaction verification result
    private func handleTransactionResult(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction):
            let transactionJwt = result.jwsRepresentation
            await handleVerifiedTransaction(transaction, jwsRepresentation: transactionJwt)

        case .unverified(let transaction, let error):
            LogError("TransactionObserver: Unverified transaction \(transaction.id): \(error)")
            // Don't sync unverified transactions - they may be fraudulent
        }
    }

    /// Handle a verified transaction by syncing with backend
    private func handleVerifiedTransaction(_ transaction: Transaction, jwsRepresentation transactionJwt: String) async {
        let transactionIdString = String(transaction.id)

        // Skip if already synced in this session
        guard !syncedTransactionIds.contains(transactionIdString) else {
            LogDebug("TransactionObserver: Transaction \(transaction.id) already synced this session")
            return
        }

        LogInfo("TransactionObserver: Processing verified transaction \(transaction.id) for product \(transaction.productID)")

        // Skip revoked transactions (refunded or removed from Family Sharing)
        if transaction.revocationDate != nil {
            LogDebug("TransactionObserver: Skipping revoked transaction \(transaction.id)")
            await transaction.finish()
            return
        }

        // Skip upgraded subscriptions (user has a higher tier now)
        if transaction.isUpgraded {
            LogDebug("TransactionObserver: Skipping upgraded transaction \(transaction.id)")
            await transaction.finish()
            return
        }

        guard !transactionJwt.isEmpty else {
            LogError("TransactionObserver: Empty JWS for transaction \(transaction.id)")
            // Don't finish - let StoreKit retry
            return
        }

        // Get the current user's distinct ID
        let distinctId = identityService.getDistinctId()

        do {
            // Sync with backend
            let response = try await api.syncTransaction(
                transactionJwt: transactionJwt,
                distinctId: distinctId
            )

            if response.success {
                LogInfo("TransactionObserver: Transaction \(transaction.id) synced successfully")

                // Update feature cache with returned features
                if let features = response.features {
                    await featureService.updateFromPurchase(features)
                }

                // Mark as synced
                syncedTransactionIds.insert(transactionIdString)

                // Track purchase event
                NuxieSDK.shared.track("$purchase_synced", properties: [
                    "transaction_id": transactionIdString,
                    "product_id": transaction.productID,
                    "customer_id": response.customerId ?? ""
                ])

                // Only finish the transaction AFTER backend confirms success
                await transaction.finish()
                LogDebug("TransactionObserver: Transaction \(transaction.id) finished")
            } else {
                LogError("TransactionObserver: Backend sync failed for transaction \(transaction.id): \(response.error ?? "Unknown error")")
                // Don't finish - will retry on next app launch via Transaction.unfinished
            }
        } catch {
            LogError("TransactionObserver: Failed to sync transaction \(transaction.id): \(error)")
            // Don't finish - will retry on next app launch via Transaction.unfinished
        }
    }

    // MARK: - Manual Sync

    /// Manually sync current entitlements (e.g., after restore purchases)
    func syncCurrentEntitlements() async {
        LogInfo("TransactionObserver: Syncing current entitlements")

        for await result in Transaction.currentEntitlements {
            await handleTransactionResult(result)
        }

        LogInfo("TransactionObserver: Finished syncing current entitlements")
    }
}
