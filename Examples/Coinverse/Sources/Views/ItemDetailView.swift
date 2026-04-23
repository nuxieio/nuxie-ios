//
//  ItemDetailView.swift
//  Coinverse
//
//  Detail view for purchasing an item.
//

import SwiftUI

struct ItemDetailView: View {
    @EnvironmentObject var inventoryStore: InventoryStore
    @Environment(\.dismiss) private var dismiss

    let item: ShopItem

    private var isOwned: Bool {
        inventoryStore.isOwned(item)
    }

    private var canAfford: Bool {
        inventoryStore.canAfford(item)
    }

    private var isPurchasing: Bool {
        inventoryStore.purchaseInProgress == item.id
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Item preview
                VStack(spacing: 16) {
                    Text(item.emoji)
                        .font(.system(size: 96))

                    Text(item.name)
                        .font(.title.bold())

                    Text(item.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text(item.category.rawValue)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(.accentColor)
                        .clipShape(Capsule())
                }

                Spacer()

                // Purchase section
                VStack(spacing: 16) {
                    if isOwned {
                        Label("Owned", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                    } else {
                        // Price display
                        HStack(spacing: 8) {
                            Text("🪙")
                                .font(.title2)
                            Text("\(item.cost)")
                                .font(.title.bold())
                        }

                        // Balance info
                        if !canAfford {
                            Text("You need \(item.cost - inventoryStore.coinBalance) more coins")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        // Purchase button
                        Button(action: purchaseItem) {
                            HStack {
                                if isPurchasing {
                                    ProgressView()
                                        .tint(.white)
                                }
                                Text(canAfford ? "Buy Now" : "Get More Coins")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isPurchasing)
                    }
                }
                .padding()
            }
            .padding()
            .navigationTitle("Item Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func purchaseItem() {
        withAnimation(.spring()) {
            inventoryStore.purchaseItem(item)
        }

        if inventoryStore.isOwned(item) {
            // Successfully purchased - dismiss after brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                dismiss()
            }
        }
    }
}

#Preview {
    ItemDetailView(item: ShopItem.all[0])
        .environmentObject(InventoryStore())
}
