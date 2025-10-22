//
//  MoodStore.swift
//  MoodLog
//
//  UserDefaults-backed storage for mood entries with streak calculation.
//  This demonstrates offline-first data architecture - perfect complement to Nuxie's event tracking.
//

import Foundation
import UIKit

/// Manages mood entry storage and retrieval
final class MoodStore {

    // MARK: - Singleton

    static let shared = MoodStore()

    // MARK: - Private Properties

    /// In-memory cache of mood entries (keyed by date string)
    private var cache: [String: MoodEntry] = [:]

    /// UserDefaults instance
    private let userDefaults = UserDefaults.standard

    /// JSON encoder
    private let encoder = JSONEncoder()

    /// JSON decoder
    private let decoder = JSONDecoder()

    // MARK: - Initialization

    private init() {
        load()
    }

    // MARK: - Public Methods

    /// Saves a mood entry (creates or updates)
    /// - Parameter entry: The mood entry to save
    /// - Throws: Error if encoding fails
    ///
    /// **Nuxie Integration Point:**
    /// After saving, the calling code should track a "mood_saved" event
    func save(_ entry: MoodEntry) throws {
        guard entry.isValid else {
            throw MoodStoreError.invalidMood
        }

        // Update cache
        cache[entry.date] = entry

        // Persist to UserDefaults
        try persist()

        // Post notification for UI updates
        NotificationCenter.default.post(
            name: Constants.moodStoreDidChangeNotification,
            object: nil,
            userInfo: ["entry": entry]
        )
    }

    /// Gets the mood entry for a specific date
    /// - Parameter date: Date string (YYYY-MM-DD)
    /// - Returns: MoodEntry if exists, nil otherwise
    func entry(for date: String) -> MoodEntry? {
        return cache[date]
    }

    /// Gets the mood entry for today
    /// - Returns: MoodEntry if exists for today, nil otherwise
    func todayEntry() -> MoodEntry? {
        return entry(for: DateHelper.todayKey())
    }

    /// Returns all mood entries sorted by date (most recent first)
    /// - Returns: Array of mood entries
    func allEntries() -> [MoodEntry] {
        return cache.values.sorted()
    }

    /// Returns entries for the last N days (including today)
    /// - Parameter days: Number of days to retrieve
    /// - Returns: Array of mood entries
    func entries(lastDays days: Int) -> [MoodEntry] {
        return allEntries().filter { entry in
            DateHelper.isWithinLast(days: days, key: entry.date)
        }
    }

    /// Deletes an entry for a specific date
    /// - Parameter date: Date string (YYYY-MM-DD)
    /// - Throws: Error if persistence fails
    func deleteEntry(for date: String) throws {
        cache.removeValue(forKey: date)
        try persist()

        NotificationCenter.default.post(
            name: Constants.moodStoreDidChangeNotification,
            object: nil
        )
    }

    /// Deletes all mood entries
    /// - Throws: Error if persistence fails
    func deleteAll() throws {
        cache.removeAll()
        try persist()

        NotificationCenter.default.post(
            name: Constants.moodStoreDidChangeNotification,
            object: nil
        )
    }

    /// Calculates the current streak (consecutive days with entries)
    /// - Returns: Number of consecutive days including today
    ///
    /// A streak is the number of consecutive days (counting backwards from today)
    /// where the user has logged a mood entry.
    func calculateStreak() -> Int {
        var currentDate = DateHelper.todayKey()
        var streak = 0

        while cache[currentDate] != nil {
            streak += 1
            guard let previousDate = DateHelper.previousDay(from: currentDate) else {
                break
            }
            currentDate = previousDate
        }

        return streak
    }

    /// Returns the total number of entries
    var count: Int {
        return cache.count
    }

    /// Returns true if there are no entries
    var isEmpty: Bool {
        return cache.isEmpty
    }

    // MARK: - CSV Export

    /// Exports all mood entries as CSV data
    /// - Returns: CSV data
    ///
    /// **Nuxie Integration Point:**
    /// This is a Pro feature - track "export_csv_tapped" before calling this
    func exportCSV() -> Data? {
        var csv = MoodEntry.csvHeader + "\n"

        // Sort entries by date (oldest first for CSV)
        let sortedEntries = allEntries().reversed()

        for entry in sortedEntries {
            csv += entry.csvRow + "\n"
        }

        return csv.data(using: .utf8)
    }

    // MARK: - Private Methods

    /// Loads entries from UserDefaults into cache
    private func load() {
        guard let data = userDefaults.data(forKey: Constants.moodEntriesKey) else {
            return
        }

        do {
            cache = try decoder.decode([String: MoodEntry].self, from: data)
        } catch {
            print("[MoodStore] Failed to decode mood entries: \(error)")
            cache = [:]
        }
    }

    /// Persists cache to UserDefaults
    /// - Throws: Error if encoding fails
    private func persist() throws {
        let data = try encoder.encode(cache)
        userDefaults.set(data, forKey: Constants.moodEntriesKey)
    }
}

// MARK: - Errors

enum MoodStoreError: LocalizedError {
    case invalidMood
    case encodingFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidMood:
            return "Mood value must be between 1 and 5"
        case .encodingFailed:
            return "Failed to encode mood entries"
        case .decodingFailed:
            return "Failed to decode mood entries"
        }
    }
}
