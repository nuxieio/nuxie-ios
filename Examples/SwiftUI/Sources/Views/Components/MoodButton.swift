//
//  MoodButton.swift
//  MoodLog
//
//  Custom mood button with emoji and selection state.
//

import SwiftUI

/// A button representing a mood emoji with selection state
struct MoodButton: View {

    // MARK: - Properties

    let mood: Int
    let isSelected: Bool
    let action: () -> Void

    // MARK: - State

    @State private var isPressed = false

    // MARK: - Computed Properties

    private var emoji: String {
        Constants.moodEmojis[mood] ?? "🙂"
    }

    private var label: String {
        Constants.moodLabels[mood] ?? "Unknown"
    }

    private var color: Color {
        Color.color(for: mood)
    }

    // MARK: - Body

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                // Emoji
                Text(emoji)
                    .font(.system(size: isSelected ? 44 : 40))
                    .scaleEffect(isPressed ? 1.2 : 1.0)

                // Label (only show for selected)
                if isSelected {
                    Text(label)
                        .font(.caption.bold())
                        .foregroundColor(color)
                        .transition(.opacity.combined(with: .scale))
                }
            }
            .frame(width: Constants.moodButtonSize, height: Constants.moodButtonSize)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? color.opacity(0.2) : Color.moodTertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? color : Color.clear, lineWidth: 2)
                    )
            )
            .shadow(
                color: isSelected ? color.opacity(0.3) : .clear,
                radius: isSelected ? 8 : 0,
                x: 0,
                y: 4
            )
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel(label)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
    }
}

// MARK: - Preview

struct MoodButton_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            // Unselected
            HStack(spacing: 12) {
                ForEach(1...5, id: \.self) { mood in
                    MoodButton(mood: mood, isSelected: false) { }
                }
            }

            // Selected
            HStack(spacing: 12) {
                ForEach(1...5, id: \.self) { mood in
                    MoodButton(mood: mood, isSelected: mood == 3) { }
                }
            }
        }
        .padding()
        .background(Color.moodBackground)
        .previewLayout(.sizeThatFits)
    }
}
