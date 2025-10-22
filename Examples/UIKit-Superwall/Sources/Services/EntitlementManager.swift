//
//  EntitlementManager.swift
//  MoodLog
//
//  Manages Pro subscription status using Superwall.
//

import Foundation
import SuperwallKit

/// Manages user entitlements and Pro status using Superwall
final class EntitlementManager {

    // MARK: - Singleton

    static let shared = EntitlementManager()

    // MARK: - Pro Status

    /// Returns true if user has Pro access
    /// Checks Superwall's subscription status
    var isProUser: Bool {
        if case .active = Superwall.shared.subscriptionStatus {
            return true
        }
        return false
    }

    // MARK: - Initialization

    private init() {
        print("[EntitlementManager] Initialized with Superwall")
    }

    // MARK: - Public Methods

    /// Checks if user can access a Pro feature
    /// - Parameter feature: Feature identifier
    /// - Returns: True if user has access
    func canAccess(_ feature: ProFeature) -> Bool {
        switch feature {
        case .unlimitedHistory:
            return isProUser
        case .csvExport:
            return isProUser
        case .customThemes:
            return isProUser
        }
    }
}

// MARK: - Pro Features

/// Enum representing Pro features for easy gating
enum ProFeature {
    case unlimitedHistory
    case csvExport
    case customThemes

    /// Display name for the feature
    var displayName: String {
        switch self {
        case .unlimitedHistory:
            return "Unlimited History"
        case .csvExport:
            return "CSV Export"
        case .customThemes:
            return "Custom Themes"
        }
    }

    /// Description of the feature
    var description: String {
        switch self {
        case .unlimitedHistory:
            return "Access your complete mood history, not just the last 7 days"
        case .csvExport:
            return "Export your mood data to CSV for analysis in other apps"
        case .customThemes:
            return "Choose from beautiful custom color themes"
        }
    }
}
