//
//  OnboardingTriggerView.swift
//  Starter
//
//  Triggers the onboarding flow on $app_installed and handles completion.
//

import SwiftUI
import Nuxie

struct OnboardingTriggerView: View {
    @EnvironmentObject var onboardingManager: OnboardingManager
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(1.5)

                    Text("Preparing your experience...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    // Fallback if flow doesn't trigger
                    VStack(spacing: 16) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)

                        Text("Welcome to Starter")
                            .font(.title2.bold())

                        Button("Get Started") {
                            // Manual completion for demo purposes
                            onboardingManager.completeOnboarding(with: OnboardingData.sample)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .task {
            await triggerOnboarding()
        }
    }

    private func triggerOnboarding() async {
        // Simulate brief loading state
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Trigger the onboarding flow
        // In a real app, this would present a Nuxie flow
        NuxieSDK.shared.trigger("$app_installed", properties: [
            "source": "first_launch"
        ]) { result in
            // Handle the trigger result
            // For demo, we'll show the fallback UI
            isLoading = false
        }

        // Show fallback after a timeout
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if !onboardingManager.hasCompletedOnboarding {
            isLoading = false
        }
    }
}

#Preview {
    OnboardingTriggerView()
        .environmentObject(OnboardingManager())
}
