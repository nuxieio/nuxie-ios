//
//  OwnedItemsView.swift
//  Coinverse
//
//  Grid view of owned items.
//

import SwiftUI

struct OwnedItemsView: View {
    @EnvironmentObject var inventoryStore: InventoryStore

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        NavigationStack {
            Group {
                if inventoryStore.ownedItems.isEmpty {
                    ContentUnavailableView(
                        "No Items Yet",
                        systemImage: "bag",
                        description: Text("Items you purchase will appear here")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(inventoryStore.ownedItems) { item in
                                OwnedItemCard(item: item)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Collection")
            .toolbar {
                if !inventoryStore.ownedItems.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Text("\(inventoryStore.ownedItems.count) items")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct OwnedItemCard: View {
    let item: ShopItem

    var body: some View {
        VStack(spacing: 8) {
            Text(item.emoji)
                .font(.system(size: 44))

            Text(item.name)
                .font(.caption)
                .fontWeight(.medium)

            Text(item.category.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    OwnedItemsView()
        .environmentObject({
            let store = InventoryStore()
            // Simulate some owned items
            store.purchaseItem(ShopItem.all[0])
            store.purchaseItem(ShopItem.all[1])
            return store
        }())
}
