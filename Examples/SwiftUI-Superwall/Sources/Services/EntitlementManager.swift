//
//  EntitlementManager.swift
//  MoodLog
//
//  Manages Pro subscription status and entitlements using Superwall.
//
//  **SwiftUI Adaptation:**
//  This class is an ObservableObject with @Published isProUser property,
//  allowing SwiftUI views to reactively update when Pro status changes.
//

import Foundation
import SwiftUI
import Combine
import SuperwallKit

/// Manages user entitlements and Pro status using Superwall
/// **ObservableObject** for reactive SwiftUI updates
final class EntitlementManager: ObservableObject {

    // MARK: - Singleton

    static let shared = EntitlementManager()

    // MARK: - Published Properties

    /// Returns true if user has Pro access
    /// Published so SwiftUI views automatically update when Pro status changes
    /// Checks Superwall's subscription status instead of local state
    @Published var isProUser: Bool = false

    // MARK: - Initialization

    private init() {
        // Check initial Pro status from Superwall
        updateProStatus()

        // Set up observer for subscription status changes
        // In a production app, you'd subscribe to Superwall's subscription status changes
        print("[EntitlementManager] Initialized with Superwall")
    }

    // MARK: - Private Methods

    /// Updates the Pro status based on Superwall's subscription status
    func updateProStatus() {
        let isPro: Bool
        if case .active = Superwall.shared.subscriptionStatus {
            isPro = true
        } else {
            isPro = false
        }

        // Update on main thread for SwiftUI
        DispatchQueue.main.async { [weak self] in
            self?.isProUser = isPro
            print("[EntitlementManager] Pro status: \(isPro)")
        }
    }

    // MARK: - Public Methods

    /// Checks if user can access a Pro feature
    /// - Parameter feature: Feature identifier
    /// - Returns: True if user has access
    ///
    /// **Superwall Integration:**
    /// This checks Superwall's subscription status instead of local state.
    /// Superwall automatically validates receipts and subscription status.
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
