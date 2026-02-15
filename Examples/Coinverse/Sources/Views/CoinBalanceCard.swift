//
//  CoinBalanceCard.swift
//  Coinverse
//
//  Displays current coin balance with get more button.
//

import SwiftUI

struct CoinBalanceCard: View {
    @EnvironmentObject var inventoryStore: InventoryStore

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Balance")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text("🪙")
                        .font(.title2)

                    Text("\(inventoryStore.coinBalance)")
                        .font(.title.bold())
                        .contentTransition(.numericText())
                }
            }

            Spacer()

            Button(action: getMoreCoins) {
                Label("Get More", systemImage: "plus.circle.fill")
                    .font(.subheadline.bold())
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    private func getMoreCoins() {
        withAnimation(.spring()) {
            inventoryStore.triggerGetMoreCoins()
        }
    }
}

#Preview {
    CoinBalanceCard()
        .environmentObject(InventoryStore())
}
