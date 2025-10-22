//
//  Theme.swift
//  MoodLog
//
//  Theme model for Pro users (demonstrates feature gating with Nuxie).
//

import Foundation

/// Available app themes (Pro feature)
enum Theme: String, Codable, CaseIterable {
    case system = "system"
    case sunrise = "sunrise"
    case midnight = "midnight"

    /// Display name for the theme
    var displayName: String {
        switch self {
        case .system:
            return "System"
        case .sunrise:
            return "Sunrise"
        case .midnight:
            return "Midnight"
        }
    }

    /// Description of the theme
    var description: String {
        switch self {
        case .system:
            return "Follows system settings"
        case .sunrise:
            return "Warm orange and yellow tones"
        case .midnight:
            return "Deep blue and purple tones"
        }
    }

    /// Whether this theme requires Pro
    var requiresPro: Bool {
        switch self {
        case .system:
            return false
        case .sunrise, .midnight:
            return true
        }
    }
}

/// Manages the app's selected theme
final class ThemeManager {

    // MARK: - Singleton

    static let shared = ThemeManager()

    // MARK: - Private Properties

    private let userDefaults = UserDefaults.standard

    // MARK: - Current Theme

    /// The currently selected theme
    var currentTheme: Theme {
        get {
            guard let rawValue = userDefaults.string(forKey: Constants.selectedThemeKey),
                  let theme = Theme(rawValue: rawValue) else {
                return .system
            }
            return theme
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: Constants.selectedThemeKey)
        }
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Sets a new theme (checks Pro status if required)
    /// - Parameters:
    ///   - theme: The theme to apply
    ///   - isPro: Whether user has Pro access
    /// - Returns: True if theme was applied, false if Pro required
    ///
    /// **Nuxie Integration Point:**
    /// Track "theme_changed" event when user changes theme
    func setTheme(_ theme: Theme, isPro: Bool) -> Bool {
        // Check if Pro is required
        if theme.requiresPro && !isPro {
            return false
        }

        currentTheme = theme
        return true
    }

    /// Applies the current theme to the app
    /// Note: In a real implementation, this would update UI colors/styles
    func applyCurrentTheme() {
        // This is a placeholder for actual theme application
        // In a production app, you would:
        // 1. Update color scheme
        // 2. Apply custom colors based on theme
        // 3. Notify views to update

        switch currentTheme {
        case .system:
            // Use default colors
            break
        case .sunrise:
            // Apply sunrise theme colors
            break
        case .midnight:
            // Apply midnight theme colors
            break
        }
    }
}
