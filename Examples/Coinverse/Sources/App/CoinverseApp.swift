//
//  CoinverseApp.swift
//  Coinverse
//
//  Demonstrates credit systems with Nuxie SDK.
//

import SwiftUI
import Nuxie

@main
struct CoinverseApp: App {
    @StateObject private var inventoryStore = InventoryStore()

    init() {
        setupNuxie()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(inventoryStore)
        }
    }

    private func setupNuxie() {
        let config = NuxieConfiguration(apiKey: "demo-api-key")
        config.environment = .development
        config.logLevel = .debug
        try? NuxieSDK.shared.setup(with: config)
    }
}
