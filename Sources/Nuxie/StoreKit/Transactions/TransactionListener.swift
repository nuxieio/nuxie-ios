import FactoryKit
import Foundation
import StoreKit

/// Listens for StoreKit transaction updates (renewals, cancellations, expirations)
/// and keeps entitlements in sync
public actor TransactionListener {

    // MARK: - Properties

    private var taskHandle: Task<Void, Never>?

    // MARK: - Init

    public init() {}

    deinit {
        taskHandle?.cancel()
    }

    // MARK: - Public Methods

    /// Start listening for transaction updates
    public func startListening() {
        taskHandle?.cancel()

        taskHandle = Task(priority: .utility) { [weak self] in
            LogInfo("TransactionListener: Started listening for transaction updates")

            for await result in Transaction.updates {
                guard !Task.isCancelled else { break }
                await self?.handleTransaction(result)
            }
        }
    }

    /// Stop listening for transaction updates
    public func stopListening() {
        taskHandle?.cancel()
        taskHandle = nil
        LogInfo("TransactionListener: Stopped listening")
    }

    // MARK: - Private Methods

    private func handleTransaction(_ result: VerificationResult<Transaction>) async {
        let transaction: Transaction

        switch result {
        case let .verified(tx):
            transaction = tx
            LogInfo("TransactionListener: Received verified transaction update: \(tx.productID)")
        case let .unverified(tx, error):
            transaction = tx
            LogWarning("TransactionListener: Received unverified transaction: \(error)")
        }

        // Finish the transaction
        await transaction.finish()

        // Track the event
        trackTransactionEvent(transaction)

        // Sync entitlements
        await syncEntitlements()
    }

    private func trackTransactionEvent(_ transaction: Transaction) {
        let eventName: String
        if transaction.revocationDate != nil {
            eventName = "$transaction_revoked"
        } else if let expirationDate = transaction.expirationDate, expirationDate < Date() {
            eventName = "$transaction_expired"
        } else {
            eventName = "$transaction_updated"
        }

        NuxieSDK.shared.track(eventName, properties: [
            "product_id": transaction.productID,
            "transaction_id": String(transaction.id),
            "original_id": String(transaction.originalID)
        ])
    }

    private func syncEntitlements() async {
        do {
            try await Container.shared.profileService().refetchProfile()
            LogDebug("TransactionListener: Entitlements synced")
        } catch {
            LogWarning("TransactionListener: Failed to sync entitlements: \(error)")
        }
    }
}
