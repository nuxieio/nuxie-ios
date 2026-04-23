//
//  LockboxApp.swift
//  Lockbox
//
//  Demonstrates feature gating with Nuxie SDK.
//

import SwiftUI
import Nuxie

@main
struct LockboxApp: App {
    @StateObject private var noteStore = NoteStore()

    init() {
        setupNuxie()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(noteStore)
        }
    }

    private func setupNuxie() {
        let config = NuxieConfiguration(apiKey: "demo-api-key")
        config.environment = .development
        config.logLevel = .debug
        try? NuxieSDK.shared.setup(with: config)
    }
}
