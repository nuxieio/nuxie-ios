//
//  MoodEntry.swift
//  MoodLog
//
//  Data model for a single mood entry.
//

import Foundation
import UIKit

/// Represents a single mood entry for a specific date
struct MoodEntry: Codable, Equatable {

    // MARK: - Properties

    /// Date key in YYYY-MM-DD format (local timezone)
    let date: String

    /// Mood value (1-5)
    /// 1 = 😞 (Very Sad)
    /// 2 = 😐 (Neutral)
    /// 3 = 🙂 (Happy)
    /// 4 = 😄 (Very Happy)
    /// 5 = 🤩 (Amazing)
    let mood: Int

    /// Optional note (max 140 characters)
    let note: String?

    /// Timestamp when the entry was created
    let createdAt: Date

    // MARK: - Computed Properties

    /// Returns the emoji for this mood
    var emoji: String {
        Constants.moodEmojis[mood] ?? "🙂"
    }

    /// Returns the accessibility label for this mood
    var moodLabel: String {
        Constants.moodLabels[mood] ?? "Unknown"
    }

    /// Returns the color for this mood
    var color: UIColor {
        UIColor.color(for: mood)
    }

    /// Returns true if this entry has a note
    var hasNote: Bool {
        note != nil && !(note?.isEmpty ?? true)
    }

    /// Returns the display string for the date (e.g., "Jan 15, 2025")
    var displayDate: String {
        DateHelper.displayString(from: date)
    }

    /// Returns the short display string for the date (e.g., "Jan 15")
    var shortDisplayDate: String {
        DateHelper.shortDisplayString(from: date)
    }

    // MARK: - Initialization

    /// Creates a new mood entry
    /// - Parameters:
    ///   - date: Date key (YYYY-MM-DD)
    ///   - mood: Mood value (1-5)
    ///   - note: Optional note (will be truncated to 140 chars)
    ///   - createdAt: Creation timestamp (defaults to now)
    init(date: String, mood: Int, note: String? = nil, createdAt: Date = Date()) {
        self.date = date
        self.mood = mood

        // Truncate note to max length
        if let note = note, !note.isEmpty {
            self.note = String(note.prefix(Constants.maxNoteLength))
        } else {
            self.note = nil
        }

        self.createdAt = createdAt
    }

    // MARK: - Validation

    /// Checks if the mood value is valid (1-5)
    var isValid: Bool {
        Constants.moodRange.contains(mood)
    }

    // MARK: - CSV Export

    /// Returns a CSV row for this entry
    /// Format: date,mood,note
    var csvRow: String {
        let noteValue = note?.replacingOccurrences(of: "\"", with: "\"\"") ?? ""
        return "\(date),\(mood),\"\(noteValue)\""
    }

    /// CSV header row
    static var csvHeader: String {
        return "date,mood,note"
    }
}

// MARK: - Comparable

extension MoodEntry: Comparable {
    static func < (lhs: MoodEntry, rhs: MoodEntry) -> Bool {
        // Sort by date (most recent first)
        lhs.date > rhs.date
    }
}

// MARK: - Hashable

extension MoodEntry: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(date)
    }
}
