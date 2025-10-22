//
//  StreakView.swift
//  MoodLog
//
//  Animated streak display showing consecutive days logged.
//

import SwiftUI

/// Displays the user's current streak with fire emoji
struct StreakView: View {

    // MARK: - Properties

    let streak: Int

    // MARK: - State

    @State private var isAnimating = false

    // MARK: - Body

    var body: some View {
        HStack(spacing: 12) {
            // Fire emoji with animation
            Text("🔥")
                .font(.system(size: 32))
                .scaleEffect(isAnimating ? 1.1 : 1.0)
                .rotationEffect(.degrees(isAnimating ? -5 : 5))
                .animation(
                    Animation.easeInOut(duration: 0.6)
                        .repeatForever(autoreverses: true),
                    value: isAnimating
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("\(streak) \(streak == 1 ? "Day" : "Days")")
                    .font(.title2.bold())
                    .foregroundColor(.moodTextPrimary)

                Text("Current Streak")
                    .font(.subheadline)
                    .foregroundColor(.moodTextSecondary)
            }

            Spacer()
        }
        .padding()
        .cardStyle(backgroundColor: Color.moodPrimary.opacity(0.1))
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Preview

struct StreakView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            StreakView(streak: 1)
            StreakView(streak: 7)
            StreakView(streak: 30)
        }
        .padding()
        .background(Color.moodBackground)
        .previewLayout(.sizeThatFits)
    }
}
