//
//  StarterApp.swift
//  Starter
//
//  Demonstrates first-launch onboarding with Nuxie SDK.
//

import SwiftUI
import Nuxie

@main
struct StarterApp: App {
    @StateObject private var onboardingManager = OnboardingManager()

    init() {
        setupNuxie()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(onboardingManager)
        }
    }

    private func setupNuxie() {
        let config = NuxieConfiguration(apiKey: "demo-api-key")
        config.environment = .development
        config.logLevel = .debug
        try? NuxieSDK.shared.setup(with: config)
    }
}
