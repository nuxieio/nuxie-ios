//
//  DateHelper.swift
//  MoodLog
//
//  Utilities for date formatting and calculations.
//

import Foundation

enum DateHelper {

    // MARK: - Formatters

    /// Shared date formatter for "YYYY-MM-DD" format (local timezone)
    /// Used as the key for mood entries in UserDefaults
    private static let dateKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = .current
        formatter.timeZone = .current
        return formatter
    }()

    /// Shared date formatter for display (e.g., "Jan 15, 2025")
    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.calendar = .current
        formatter.timeZone = .current
        return formatter
    }()

    /// Shared date formatter for short display (e.g., "Jan 15")
    private static let shortFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        formatter.calendar = .current
        formatter.timeZone = .current
        return formatter
    }()

    // MARK: - Public Methods

    /// Returns today's date as a string key (YYYY-MM-DD)
    /// - Returns: String key for today's date
    static func todayKey() -> String {
        return dateKeyFormatter.string(from: Date())
    }

    /// Converts a date to a string key (YYYY-MM-DD)
    /// - Parameter date: The date to convert
    /// - Returns: String key for the date
    static func key(from date: Date) -> String {
        return dateKeyFormatter.string(from: date)
    }

    /// Converts a string key (YYYY-MM-DD) to a Date
    /// - Parameter key: The date string
    /// - Returns: Date object or nil if parsing fails
    static func date(from key: String) -> Date? {
        return dateKeyFormatter.date(from: key)
    }

    /// Formats a date string key for display (e.g., "Jan 15, 2025")
    /// - Parameter key: The date string (YYYY-MM-DD)
    /// - Returns: Formatted display string
    static func displayString(from key: String) -> String {
        guard let date = date(from: key) else {
            return key
        }
        return displayFormatter.string(from: date)
    }

    /// Formats a date string key for short display (e.g., "Jan 15")
    /// - Parameter key: The date string (YYYY-MM-DD)
    /// - Returns: Short formatted string
    static func shortDisplayString(from key: String) -> String {
        guard let date = date(from: key) else {
            return key
        }
        return shortFormatter.string(from: date)
    }

    /// Returns the date key for yesterday
    /// - Returns: String key for yesterday's date
    static func yesterdayKey() -> String {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        return key(from: yesterday)
    }

    /// Returns the date key for N days ago
    /// - Parameter days: Number of days in the past
    /// - Returns: String key for the date
    static func key(daysAgo days: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return key(from: date)
    }

    /// Gets the previous day's key from a given key
    /// - Parameter key: Current date key
    /// - Returns: Previous day's key or nil if invalid
    static func previousDay(from key: String) -> String? {
        guard let date = date(from: key),
              let previousDate = Calendar.current.date(byAdding: .day, value: -1, to: date) else {
            return nil
        }
        return self.key(from: previousDate)
    }

    /// Checks if a date key is today
    /// - Parameter key: Date key to check
    /// - Returns: True if the key represents today
    static func isToday(_ key: String) -> Bool {
        return key == todayKey()
    }

    /// Checks if a date key is within the last N days (including today)
    /// - Parameters:
    ///   - key: Date key to check
    ///   - days: Number of days to check
    /// - Returns: True if within range
    static func isWithinLast(days: Int, key: String) -> Bool {
        guard let date = date(from: key) else {
            return false
        }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfDate = calendar.startOfDay(for: date)

        guard let daysAgo = calendar.dateComponents([.day], from: startOfDate, to: startOfToday).day else {
            return false
        }

        return daysAgo >= 0 && daysAgo < days
    }

    /// Sorts date keys in descending order (most recent first)
    /// - Parameter keys: Array of date keys
    /// - Returns: Sorted array of date keys
    static func sortKeysDescending(_ keys: [String]) -> [String] {
        return keys.sorted { key1, key2 in
            guard let date1 = date(from: key1),
                  let date2 = date(from: key2) else {
                return key1 > key2
            }
            return date1 > date2
        }
    }
}
