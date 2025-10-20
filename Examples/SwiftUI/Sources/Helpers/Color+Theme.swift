//
//  Color+Theme.swift
//  MoodLog
//
//  Custom color palette with automatic dark mode support for SwiftUI.
//

import SwiftUI

extension Color {

    // MARK: - Primary Colors

    /// Primary brand color (adjusts for dark mode)
    static var moodPrimary: Color {
        Color("MoodPrimary", bundle: nil)
    }

    /// Accent color for highlights and selections
    static var moodAccent: Color {
        Color("MoodAccent", bundle: nil)
    }

    // MARK: - Background Colors

    /// Primary background color
    static var moodBackground: Color {
        Color("MoodBackground", bundle: nil)
    }

    /// Secondary background (for cards and elevated views)
    static var moodCardBackground: Color {
        Color("MoodCardBackground", bundle: nil)
    }

    /// Tertiary background (subtle sections)
    static var moodTertiaryBackground: Color {
        Color("MoodTertiaryBackground", bundle: nil)
    }

    // MARK: - Text Colors

    /// Primary text color
    static var moodTextPrimary: Color {
        Color("MoodTextPrimary", bundle: nil)
    }

    /// Secondary text color (subtitles, captions)
    static var moodTextSecondary: Color {
        Color("MoodTextSecondary", bundle: nil)
    }

    /// Tertiary text color (hints, placeholders)
    static var moodTextTertiary: Color {
        Color("MoodTextTertiary", bundle: nil)
    }

    // MARK: - Mood-Specific Colors

    /// Color for very sad mood (😞)
    static var moodVerySad: Color {
        Color(red: 0.3, green: 0.4, blue: 0.7)  // Subdued blue
    }

    /// Color for neutral mood (😐)
    static var moodNeutral: Color {
        Color(red: 0.6, green: 0.6, blue: 0.6)  // Gray
    }

    /// Color for happy mood (🙂)
    static var moodHappy: Color {
        Color(red: 0.4, green: 0.7, blue: 0.4)  // Green
    }

    /// Color for very happy mood (😄)
    static var moodVeryHappy: Color {
        Color(red: 1.0, green: 0.7, blue: 0.2)  // Warm yellow
    }

    /// Color for amazing mood (🤩)
    static var moodAmazing: Color {
        Color(red: 1.0, green: 0.5, blue: 0.8)  // Pink/magenta
    }

    /// Gets the color for a specific mood value (1-5)
    /// - Parameter mood: The mood value (1-5)
    /// - Returns: Color for the mood
    static func color(for mood: Int) -> Color {
        switch mood {
        case 1: return moodVerySad
        case 2: return moodNeutral
        case 3: return moodHappy
        case 4: return moodVeryHappy
        case 5: return moodAmazing
        default: return moodNeutral
        }
    }

    // MARK: - Separator Colors

    /// Separator/divider color
    static var moodSeparator: Color {
        Color("MoodSeparator", bundle: nil)
    }

    // MARK: - Status Colors

    /// Success color (e.g., purchase successful)
    static var moodSuccess: Color {
        Color(red: 0.2, green: 0.8, blue: 0.4)
    }

    /// Error color
    static var moodError: Color {
        Color(red: 1.0, green: 0.3, blue: 0.3)
    }

    /// Warning color
    static var moodWarning: Color {
        Color(red: 1.0, green: 0.7, blue: 0.2)
    }

    // MARK: - Pro Badge Colors

    /// Pro badge gradient start
    static var moodProGradientStart: Color {
        Color(red: 0.6, green: 0.4, blue: 1.0)  // Purple
    }

    /// Pro badge gradient end
    static var moodProGradientEnd: Color {
        Color(red: 0.9, green: 0.4, blue: 0.6)  // Pink
    }
}
