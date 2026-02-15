//
//  PersonaStore.swift
//  Persona
//
//  Manages quiz state and results.
//

import Foundation
import Nuxie

@MainActor
class PersonaStore: ObservableObject {
    @Published var userName: String = ""
    @Published var currentResult: PersonaResult?
    @Published var previousResults: [PersonaResult] = []
    @Published var isQuizActive: Bool = false

    private let userDefaults = UserDefaults.standard
    private let resultsKey = "persona_results"
    private let nameKey = "persona_user_name"

    init() {
        loadState()
    }

    func startQuiz() {
        isQuizActive = true

        NuxieSDK.shared.trigger("quiz_started", properties: [
            "user_name": userName.isEmpty ? "Anonymous" : userName
        ]) { _ in }

        // Simulate quiz completion after a delay
        // In a real app, this would be handled by the flow completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.completeQuiz(with: PersonaType.random())
        }
    }

    func completeQuiz(with personaType: PersonaType) {
        let result = PersonaResult(
            personaType: personaType,
            userName: userName.isEmpty ? "Friend" : userName
        )

        // Archive previous result
        if let current = currentResult {
            previousResults.insert(current, at: 0)
        }

        currentResult = result
        isQuizActive = false

        NuxieSDK.shared.trigger("quiz_completed", properties: [
            "persona_type": personaType.rawValue,
            "user_name": result.userName
        ]) { _ in }

        saveState()
    }

    func clearResults() {
        currentResult = nil
        previousResults.removeAll()
        saveState()
    }

    // MARK: - Persistence

    private func loadState() {
        userName = userDefaults.string(forKey: nameKey) ?? ""

        if let data = userDefaults.data(forKey: resultsKey),
           let decoded = try? JSONDecoder().decode([PersonaResult].self, from: data) {
            if !decoded.isEmpty {
                currentResult = decoded.first
                previousResults = Array(decoded.dropFirst())
            }
        }
    }

    private func saveState() {
        userDefaults.set(userName, forKey: nameKey)

        var allResults: [PersonaResult] = []
        if let current = currentResult {
            allResults.append(current)
        }
        allResults.append(contentsOf: previousResults)

        if let encoded = try? JSONEncoder().encode(allResults) {
            userDefaults.set(encoded, forKey: resultsKey)
        }
    }
}
