//
//  ContentView.swift
//  Starter
//
//  Root view that switches between onboarding trigger and home.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var onboardingManager: OnboardingManager

    var body: some View {
        Group {
            if onboardingManager.hasCompletedOnboarding {
                HomeView()
            } else {
                OnboardingTriggerView()
            }
        }
        .animation(.easeInOut, value: onboardingManager.hasCompletedOnboarding)
    }
}

#Preview {
    ContentView()
        .environmentObject(OnboardingManager())
}
