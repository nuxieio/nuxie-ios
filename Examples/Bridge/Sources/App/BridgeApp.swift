//
//  BridgeApp.swift
//  Bridge
//
//  Demonstrates call_delegate and native action integration with Nuxie SDK.
//

import SwiftUI
import Nuxie

@main
struct BridgeApp: App {
    @StateObject private var actionHandler = ActionHandler()

    init() {
        setupNuxie()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(actionHandler)
        }
    }

    private func setupNuxie() {
        let config = NuxieConfiguration(apiKey: "demo-api-key")
        config.environment = .development
        config.logLevel = .debug
        try? NuxieSDK.shared.setup(with: config)
    }
}
