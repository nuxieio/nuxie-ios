//
//  InventoryStore.swift
//  Coinverse
//
//  Manages coin balance and owned items.
//

import Foundation
import Nuxie

@MainActor
class InventoryStore: ObservableObject {
    @Published private(set) var coinBalance: Int = 50
    @Published private(set) var ownedItemIds: Set<String> = []
    @Published private(set) var purchaseInProgress: String?

    private let userDefaults = UserDefaults.standard
    private let balanceKey = "coinverse_balance"
    private let ownedKey = "coinverse_owned"

    init() {
        loadState()
    }

    var ownedItems: [ShopItem] {
        ShopItem.all.filter { ownedItemIds.contains($0.id) }
    }

    func canAfford(_ item: ShopItem) -> Bool {
        coinBalance >= item.cost
    }

    func isOwned(_ item: ShopItem) -> Bool {
        ownedItemIds.contains(item.id)
    }

    func purchaseItem(_ item: ShopItem) {
        guard !isOwned(item) else { return }

        if !canAfford(item) {
            // Not enough coins - trigger top-up flow
            NuxieSDK.shared.trigger("insufficient_coins", properties: [
                "item_id": item.id,
                "item_cost": item.cost,
                "current_balance": coinBalance,
                "deficit": item.cost - coinBalance
            ]) { _ in }
            return
        }

        purchaseInProgress = item.id

        // Deduct coins
        coinBalance -= item.cost

        // Mark as owned
        ownedItemIds.insert(item.id)

        // Track purchase
        NuxieSDK.shared.trigger("item_purchased", properties: [
            "item_id": item.id,
            "item_name": item.name,
            "cost": item.cost,
            "category": item.category.rawValue
        ]) { _ in }

        purchaseInProgress = nil
        saveState()
    }

    func addCoins(_ amount: Int) {
        coinBalance += amount
        saveState()

        NuxieSDK.shared.trigger("coins_added", properties: [
            "amount": amount,
            "new_balance": coinBalance
        ]) { _ in }
    }

    func triggerGetMoreCoins() {
        NuxieSDK.shared.trigger("get_more_coins_tapped", properties: [
            "current_balance": coinBalance
        ]) { _ in }

        // For demo, add coins directly
        addCoins(50)
    }

    // MARK: - Persistence

    private func loadState() {
        coinBalance = userDefaults.integer(forKey: balanceKey)
        if coinBalance == 0 {
            coinBalance = 50 // Starting balance
        }

        if let data = userDefaults.data(forKey: ownedKey),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            ownedItemIds = decoded
        }
    }

    private func saveState() {
        userDefaults.set(coinBalance, forKey: balanceKey)

        if let encoded = try? JSONEncoder().encode(ownedItemIds) {
            userDefaults.set(encoded, forKey: ownedKey)
        }
    }

    func reset() {
        coinBalance = 50
        ownedItemIds.removeAll()
        saveState()
    }
}
