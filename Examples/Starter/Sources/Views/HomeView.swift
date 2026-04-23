//
//  HomeView.swift
//  Starter
//
//  Home screen shown after onboarding completion.
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var onboardingManager: OnboardingManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    // Welcome header
                    VStack(spacing: 8) {
                        Text("Welcome back,")
                            .font(.title2)
                            .foregroundStyle(.secondary)

                        Text(onboardingManager.onboardingData?.name ?? "Friend")
                            .font(.largeTitle.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)

                    // Preferences card
                    if let data = onboardingManager.onboardingData {
                        PreferencesCard(data: data)
                    }

                    Spacer(minLength: 40)

                    // Reset button
                    Button(action: resetOnboarding) {
                        Label("Reset & Try Again", systemImage: "arrow.counterclockwise")
                    }
                    .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Starter")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func resetOnboarding() {
        withAnimation(.spring()) {
            onboardingManager.reset()
        }
    }
}

struct PreferencesCard: View {
    let data: OnboardingData

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your Preferences")
                .font(.headline)

            VStack(spacing: 12) {
                PreferenceRow(label: "Theme", value: data.theme)
                PreferenceRow(label: "Notifications", value: data.notificationsEnabled ? "On" : "Off")
                PreferenceRow(label: "Goal", value: data.goal)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct PreferenceRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

#Preview {
    HomeView()
        .environmentObject({
            let manager = OnboardingManager()
            manager.completeOnboarding(with: OnboardingData.sample)
            return manager
        }())
}
