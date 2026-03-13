//
//  ShopItemCard.swift
//  Coinverse
//
//  Card view for a shop item.
//

import SwiftUI

struct ShopItemCard: View {
    @EnvironmentObject var inventoryStore: InventoryStore

    let item: ShopItem
    let onTap: () -> Void

    private var isOwned: Bool {
        inventoryStore.isOwned(item)
    }

    private var canAfford: Bool {
        inventoryStore.canAfford(item)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                ZStack {
                    Text(item.emoji)
                        .font(.system(size: 36))

                    if isOwned {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .background(Color.white.clipShape(Circle()))
                            .offset(x: 20, y: -20)
                    }
                }
                .frame(height: 48)

                Text(item.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if isOwned {
                    Text("Owned")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    HStack(spacing: 2) {
                        Text("🪙")
                            .font(.caption2)
                        Text("\(item.cost)")
                            .font(.caption.bold())
                            .foregroundStyle(canAfford ? .primary : .red)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                if isOwned {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.green.opacity(0.3), lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    HStack {
        ShopItemCard(item: ShopItem.all[0]) { }
        ShopItemCard(item: ShopItem.all[1]) { }
        ShopItemCard(item: ShopItem.all[2]) { }
    }
    .padding()
    .environmentObject(InventoryStore())
}
