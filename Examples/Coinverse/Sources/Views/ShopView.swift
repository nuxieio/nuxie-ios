//
//  ShopView.swift
//  Coinverse
//
//  Main shop grid with items for purchase.
//

import SwiftUI

struct ShopView: View {
    @EnvironmentObject var inventoryStore: InventoryStore
    @State private var selectedItem: ShopItem?

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Balance card
                    CoinBalanceCard()

                    // Shop grid by category
                    ForEach(ShopItem.Category.allCases, id: \.self) { category in
                        let items = ShopItem.all.filter { $0.category == category }

                        VStack(alignment: .leading, spacing: 12) {
                            Text(category.rawValue)
                                .font(.headline)
                                .padding(.horizontal)

                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(items) { item in
                                    ShopItemCard(item: item) {
                                        selectedItem = item
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Shop")
            .sheet(item: $selectedItem) { item in
                ItemDetailView(item: item)
            }
        }
    }
}

#Preview {
    ShopView()
        .environmentObject(InventoryStore())
}
