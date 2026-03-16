//
//  PersonaApp.swift
//  Persona
//
//  Demonstrates view model binding and data flow with Nuxie SDK.
//

import SwiftUI
import Nuxie

@main
struct PersonaApp: App {
    @StateObject private var personaStore = PersonaStore()

    init() {
        setupNuxie()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(personaStore)
        }
    }

    private func setupNuxie() {
        let config = NuxieConfiguration(apiKey: "demo-api-key")
        config.environment = .development
        config.logLevel = .debug
        try? NuxieSDK.shared.setup(with: config)
    }
}
