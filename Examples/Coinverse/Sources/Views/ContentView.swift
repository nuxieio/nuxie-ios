//
//  ContentView.swift
//  Coinverse
//
//  Root view with tab navigation.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            ShopView()
                .tabItem {
                    Label("Shop", systemImage: "bag")
                }

            OwnedItemsView()
                .tabItem {
                    Label("Collection", systemImage: "square.grid.2x2")
                }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(InventoryStore())
}
