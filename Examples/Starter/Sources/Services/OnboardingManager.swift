//
//  OnboardingManager.swift
//  Starter
//
//  Manages onboarding state and persistence.
//

import Foundation

@MainActor
class OnboardingManager: ObservableObject {
    @Published private(set) var hasCompletedOnboarding: Bool = false
    @Published private(set) var onboardingData: OnboardingData?

    private let userDefaults = UserDefaults.standard
    private let completedKey = "starter_onboarding_completed"
    private let dataKey = "starter_onboarding_data"

    init() {
        loadState()
    }

    func completeOnboarding(with data: OnboardingData) {
        onboardingData = data
        hasCompletedOnboarding = true
        saveState()
    }

    func reset() {
        hasCompletedOnboarding = false
        onboardingData = nil
        userDefaults.removeObject(forKey: completedKey)
        userDefaults.removeObject(forKey: dataKey)
    }

    private func loadState() {
        hasCompletedOnboarding = userDefaults.bool(forKey: completedKey)

        if let data = userDefaults.data(forKey: dataKey),
           let decoded = try? JSONDecoder().decode(OnboardingData.self, from: data) {
            onboardingData = decoded
        }
    }

    private func saveState() {
        userDefaults.set(hasCompletedOnboarding, forKey: completedKey)

        if let data = onboardingData,
           let encoded = try? JSONEncoder().encode(data) {
            userDefaults.set(encoded, forKey: dataKey)
        }
    }
}
