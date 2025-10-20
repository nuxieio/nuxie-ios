//
//  HistoryRow.swift
//  MoodLog
//
//  List row displaying a single mood entry.
//

import SwiftUI

/// A row displaying a mood entry in the history list
struct HistoryRow: View {

    // MARK: - Properties

    let entry: MoodEntry

    // MARK: - Body

    var body: some View {
        HStack(spacing: 16) {
            // Emoji
            Text(entry.emoji)
                .font(.system(size: 44))
                .frame(width: 60, height: 60)
                .background(entry.color.opacity(0.2))
                .cornerRadius(12)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                // Date
                Text(entry.displayDate)
                    .font(.headline)
                    .foregroundColor(.moodTextPrimary)

                // Mood label
                Text(entry.moodLabel)
                    .font(.subheadline)
                    .foregroundColor(entry.color)

                // Note (if exists)
                if entry.hasNote, let note = entry.note {
                    Text(note)
                        .font(.caption)
                        .foregroundColor(.moodTextSecondary)
                        .lineLimit(2)
                        .padding(.top, 4)
                }
            }

            Spacer()

            // Chevron
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.moodTextTertiary)
        }
        .padding()
        .cardStyle()
    }
}

// MARK: - Preview

struct HistoryRow_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            HistoryRow(entry: MoodEntry(
                date: "2025-01-15",
                mood: 5,
                note: "Had an amazing day! Everything went perfectly."
            ))

            HistoryRow(entry: MoodEntry(
                date: "2025-01-14",
                mood: 3,
                note: nil
            ))

            HistoryRow(entry: MoodEntry(
                date: "2025-01-13",
                mood: 1,
                note: "Feeling down today..."
            ))
        }
        .padding()
        .background(Color.moodBackground)
        .previewLayout(.sizeThatFits)
    }
}
