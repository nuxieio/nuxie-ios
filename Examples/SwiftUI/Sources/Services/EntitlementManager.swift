//
//  EntitlementManager.swift
//  MoodLog
//
//  Manages Pro subscription status and entitlements.
//  In a production app, this would sync with your backend and/or StoreKit receipts.
//
//  **SwiftUI Adaptation:**
//  This class is an ObservableObject with @Published isProUser property,
//  allowing SwiftUI views to reactively update when Pro status changes.
//

import Foundation
import SwiftUI
import Combine

/// Manages user entitlements and Pro status
/// **ObservableObject** for reactive SwiftUI updates
final class EntitlementManager: ObservableObject {

    // MARK: - Singleton

    static let shared = EntitlementManager()

    // MARK: - Published Properties

    /// Returns true if user has Pro access
    /// Published so SwiftUI views automatically update when Pro status changes
    @Published var isProUser: Bool {
        didSet {
            // Persist to UserDefaults when changed
            userDefaults.set(isProUser, forKey: Constants.isProUserKey)
        }
    }

    // MARK: - Private Properties

    private let userDefaults = UserDefaults.standard

    // MARK: - Initialization

    private init() {
        // Load initial Pro status from UserDefaults
        self.isProUser = userDefaults.bool(forKey: Constants.isProUserKey)

        // Check for existing entitlements on init
        validateEntitlements()
    }

    // MARK: - Public Methods

    /// Unlocks Pro features (called after successful purchase)
    ///
    /// **Nuxie Integration Point:**
    /// This is typically called after Nuxie's TransactionService completes a purchase.
    /// The purchase event is automatically tracked by Nuxie SDK.
    func unlockPro() {
        isProUser = true
        print("[EntitlementManager] Pro unlocked")
    }

    /// Locks Pro features (for testing or subscription expiration)
    func lockPro() {
        isProUser = false
        print("[EntitlementManager] Pro locked")
    }

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

    /// Validates current entitlements
    /// In a production app, this would:
    /// 1. Verify StoreKit receipts
    /// 2. Check with your backend
    /// 3. Validate subscription expiration
    private func validateEntitlements() {
        // For this demo, we trust UserDefaults
        // In production, you'd validate against App Store receipts
        // or your own backend service

        #if DEBUG
        // Optionally start with Pro unlocked in debug builds
        // Uncomment the line below for easier testing:
        // isProUser = true
        #endif
    }

    /// Resets all entitlements (for testing)
    func reset() {
        isProUser = false
        userDefaults.removeObject(forKey: Constants.isProUserKey)
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
