//
//  UIColor+Theme.swift
//  MoodLog
//
//  Custom color palette with automatic dark mode support.
//

import UIKit

extension UIColor {

    // MARK: - Primary Colors

    /// Primary brand color (adjusts for dark mode)
    static var moodPrimary: UIColor {
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark
                ? UIColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)  // Lighter blue
                : UIColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1.0)  // Darker blue
        }
    }

    /// Accent color for highlights and selections
    static var moodAccent: UIColor {
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark
                ? UIColor(red: 1.0, green: 0.7, blue: 0.3, alpha: 1.0)  // Warm orange
                : UIColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 1.0)  // Brighter orange
        }
    }

    // MARK: - Background Colors

    /// Primary background color
    static var moodBackground: UIColor {
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark
                ? UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)  // Dark gray
                : UIColor(red: 0.98, green: 0.98, blue: 1.0, alpha: 1.0)  // Off-white
        }
    }

    /// Secondary background (for cards and elevated views)
    static var moodCardBackground: UIColor {
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark
                ? UIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)  // Lighter dark
                : UIColor.white
        }
    }

    /// Tertiary background (subtle sections)
    static var moodTertiaryBackground: UIColor {
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark
                ? UIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0)
                : UIColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1.0)
        }
    }

    // MARK: - Text Colors

    /// Primary text color
    static var moodTextPrimary: UIColor {
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 1.0)
                : UIColor(white: 0.1, alpha: 1.0)
        }
    }

    /// Secondary text color (subtitles, captions)
    static var moodTextSecondary: UIColor {
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark
                ? UIColor(white: 0.7, alpha: 1.0)
                : UIColor(white: 0.4, alpha: 1.0)
        }
    }

    /// Tertiary text color (hints, placeholders)
    static var moodTextTertiary: UIColor {
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark
                ? UIColor(white: 0.5, alpha: 1.0)
                : UIColor(white: 0.6, alpha: 1.0)
        }
    }

    // MARK: - Mood-Specific Colors

    /// Color for very sad mood (😞)
    static var moodVerySad: UIColor {
        UIColor(red: 0.3, green: 0.4, blue: 0.7, alpha: 1.0)  // Subdued blue
    }

    /// Color for neutral mood (😐)
    static var moodNeutral: UIColor {
        UIColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1.0)  // Gray
    }

    /// Color for happy mood (🙂)
    static var moodHappy: UIColor {
        UIColor(red: 0.4, green: 0.7, blue: 0.4, alpha: 1.0)  // Green
    }

    /// Color for very happy mood (😄)
    static var moodVeryHappy: UIColor {
        UIColor(red: 1.0, green: 0.7, blue: 0.2, alpha: 1.0)  // Warm yellow
    }

    /// Color for amazing mood (🤩)
    static var moodAmazing: UIColor {
        UIColor(red: 1.0, green: 0.5, blue: 0.8, alpha: 1.0)  // Pink/magenta
    }

    /// Gets the color for a specific mood value (1-5)
    /// - Parameter mood: The mood value (1-5)
    /// - Returns: UIColor for the mood
    static func color(for mood: Int) -> UIColor {
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
    static var moodSeparator: UIColor {
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark
                ? UIColor(white: 0.3, alpha: 1.0)
                : UIColor(white: 0.85, alpha: 1.0)
        }
    }

    // MARK: - Status Colors

    /// Success color (e.g., purchase successful)
    static var moodSuccess: UIColor {
        UIColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1.0)
    }

    /// Error color
    static var moodError: UIColor {
        UIColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0)
    }

    /// Warning color
    static var moodWarning: UIColor {
        UIColor(red: 1.0, green: 0.7, blue: 0.2, alpha: 1.0)
    }

    // MARK: - Pro Badge Colors

    /// Pro badge gradient start
    static var moodProGradientStart: UIColor {
        UIColor(red: 0.6, green: 0.4, blue: 1.0, alpha: 1.0)  // Purple
    }

    /// Pro badge gradient end
    static var moodProGradientEnd: UIColor {
        UIColor(red: 0.9, green: 0.4, blue: 0.6, alpha: 1.0)  // Pink
    }
}
