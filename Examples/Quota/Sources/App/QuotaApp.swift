//
//  QuotaApp.swift
//  Quota
//
//  Demonstrates metered feature usage with Nuxie SDK.
//

import SwiftUI
import Nuxie

@main
struct QuotaApp: App {
    @StateObject private var quoteStore = QuoteStore()

    init() {
        setupNuxie()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(quoteStore)
        }
    }

    private func setupNuxie() {
        let config = NuxieConfiguration(apiKey: "demo-api-key")
        config.environment = .development
        config.logLevel = .debug
        try? NuxieSDK.shared.setup(with: config)
    }
}
