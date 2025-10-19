import SwiftUI
import Nuxie
import NuxieRevenueCat
import RevenueCat

@main
struct RevenueCatExampleApp: App {
    @StateObject private var model = RevenueCatExampleModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}

final class RevenueCatExampleModel: ObservableObject {
    @Published var statusText: String = "Ready"
    let purchaseDelegate: NuxieRevenueCatPurchaseDelegate

    init() {
        // Configure RevenueCat with a placeholder API key so the example compiles.
        Purchases.logLevel = .debug
        Purchases.configure(withAPIKey: "REVENUECAT_API_KEY", appUserID: nil)

        purchaseDelegate = NuxieRevenueCatPurchaseDelegate()

        let configuration = NuxieConfiguration(apiKey: "NUXIE_API_KEY")
        configuration.purchaseDelegate = purchaseDelegate
        configuration.enablePlugins = false
        try? NuxieSDK.shared.setup(with: configuration)
    }

    func simulatePurchase() {
        Task {
            await MainActor.run { statusText = "Attempting purchase..." }
            let mock = MockStoreProduct(
                id: "com.example.product",
                displayName: "Example",
                price: Decimal(4.99),
                displayPrice: "$4.99"
            )
            let result = await purchaseDelegate.purchase(mock)
            await MainActor.run { statusText = describe(result) }
        }
    }

    func simulateRestore() {
        Task {
            await MainActor.run { statusText = "Attempting restore..." }
            let result = await purchaseDelegate.restore()
            await MainActor.run { statusText = describe(result) }
        }
    }

    private func describe(_ result: PurchaseResult) -> String {
        switch result {
        case .success:
            return "Purchase succeeded"
        case .cancelled:
            return "Purchase cancelled"
        case .pending:
            return "Purchase pending"
        case .failed(let error):
            return "Purchase failed: \(error.localizedDescription)"
        }
    }

    private func describe(_ result: RestoreResult) -> String {
        switch result {
        case .success(let count):
            return "Restore succeeded (\(count) entitlements)"
        case .noPurchases:
            return "Restore completed: no purchases"
        case .failed(let error):
            return "Restore failed: \(error.localizedDescription)"
        }
    }
}
