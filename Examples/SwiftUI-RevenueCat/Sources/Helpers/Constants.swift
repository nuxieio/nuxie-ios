//
//  Constants.swift
//  MoodLog
//
//  App-wide constants including UserDefaults keys, product IDs, and configuration values.
//

import Foundation

enum Constants {

    // MARK: - UserDefaults Keys

    /// Key for storing mood entries dictionary as JSON
    static let moodEntriesKey = "mood_entries"

    /// Key for storing user's UUID
    static let userIdKey = "user_id"

    /// Key for storing Pro entitlement status
    static let isProUserKey = "is_pro_user"

    /// Key for storing last app version (for update detection)
    static let lastAppVersionKey = "last_app_version"

    /// Key for storing selected theme
    static let selectedThemeKey = "selected_theme"

    // MARK: - Mood Values

    /// Valid mood range (1-5)
    static let moodRange = 1...5

    /// Maximum note length (140 characters, Twitter-style)
    static let maxNoteLength = 140

    /// Mood emoji mapping
    static let moodEmojis: [Int: String] = [
        1: "😞",
        2: "😐",
        3: "🙂",
        4: "😄",
        5: "🤩"
    ]

    /// Mood labels for accessibility
    static let moodLabels: [Int: String] = [
        1: "Very Sad",
        2: "Neutral",
        3: "Happy",
        4: "Very Happy",
        5: "Amazing"
    ]

    // MARK: - StoreKit Product IDs

    /// Product ID for Pro monthly subscription
    /// TODO: Replace with your actual App Store Connect product ID
    static let proMonthlyProductId = "io.nuxie.moodlog.pro.monthly"

    /// Product ID for Pro yearly subscription
    /// TODO: Replace with your actual App Store Connect product ID
    static let proYearlyProductId = "io.nuxie.moodlog.pro.yearly"

    /// All available product IDs for fetching
    static let allProductIds: Set<String> = [
        proMonthlyProductId,
        proYearlyProductId
    ]

    // MARK: - Feature Limits

    /// Maximum number of history entries for free users
    static let freeHistoryLimit = 7

    // MARK: - UI Constants

    /// Mood button size
    static let moodButtonSize: CGFloat = 64

    /// Standard padding
    static let standardPadding: CGFloat = 16

    /// Large padding
    static let largePadding: CGFloat = 24

    /// Corner radius for cards/buttons
    static let cornerRadius: CGFloat = 12

    // MARK: - Animation Durations

    /// Standard animation duration
    static let animationDuration: TimeInterval = 0.3

    /// Spring damping for bouncy animations
    static let springDamping: CGFloat = 0.7

    /// Initial spring velocity
    static let springVelocity: CGFloat = 0.5

    // MARK: - Nuxie Event Names

    /// Event fired when app is opened
    static let eventAppOpened = "app_opened"

    /// Event fired when a mood emoji is selected
    static let eventMoodSelected = "mood_selected"

    /// Event fired when a mood is successfully saved
    static let eventMoodSaved = "mood_saved"

    /// Event fired when history is viewed
    static let eventHistoryViewed = "history_viewed"

    /// Event fired when user taps to upgrade (triggers flow)
    static let eventUpgradeTapped = "upgrade_tapped"

    /// Event fired when user wants to unlock full history (triggers flow)
    static let eventUnlockHistoryTapped = "unlock_history_tapped"

    /// Event fired when CSV export is attempted without Pro (triggers flow)
    static let eventCSVExportGated = "csv_export_gated"

    /// Event fired when CSV export actually happens
    static let eventExportCSV = "csv_export_completed"

    /// Event fired when theme is changed (Pro feature)
    static let eventThemeChanged = "theme_changed"

    // MARK: - App Info

    /// Current app version string
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Current build number
    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
