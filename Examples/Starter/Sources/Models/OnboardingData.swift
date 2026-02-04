//
//  OnboardingData.swift
//  Starter
//
//  Model for data collected during onboarding.
//

import Foundation

struct OnboardingData: Codable, Equatable {
    let name: String
    let theme: String
    let notificationsEnabled: Bool
    let goal: String

    static let sample = OnboardingData(
        name: "Sarah",
        theme: "Dark",
        notificationsEnabled: true,
        goal: "Productivity"
    )

    /// Creates OnboardingData from a journey context dictionary
    init(from context: [String: Any]) {
        self.name = context["name"] as? String ?? "Friend"
        self.theme = context["theme"] as? String ?? "System"
        self.notificationsEnabled = context["notifications_enabled"] as? Bool ?? false
        self.goal = context["goal"] as? String ?? "General"
    }

    init(name: String, theme: String, notificationsEnabled: Bool, goal: String) {
        self.name = name
        self.theme = theme
        self.notificationsEnabled = notificationsEnabled
        self.goal = goal
    }
}
