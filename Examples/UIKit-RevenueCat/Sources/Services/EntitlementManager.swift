//
//  EntitlementManager.swift
//  MoodLog
//
//  Manages Pro subscription status and entitlements using RevenueCat.
//  Conforms to PurchasesDelegate to receive entitlement updates.
//

import Foundation
import RevenueCat

/// Manages user entitlements and Pro status using RevenueCat
final class EntitlementManager: NSObject, PurchasesDelegate {

    // MARK: - Singleton

    static let shared = EntitlementManager()

    // MARK: - Pro Status

    /// Returns true if user has Pro access
    /// Checks RevenueCat's active entitlements instead of UserDefaults
    var isProUser: Bool {
        // Check if user has any active entitlements in RevenueCat
        // In a real app, you'd check for a specific entitlement identifier
        return Purchases.shared.cachedCustomerInfo?.entitlements.active.isEmpty == false
    }

    // MARK: - Initialization

    private override init() {
        super.init()
        print("[EntitlementManager] Initialized with RevenueCat")
    }

    // MARK: - PurchasesDelegate

    /// Called when RevenueCat receives updated customer info
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        let isPro = !customerInfo.entitlements.active.isEmpty
        print("[EntitlementManager] Customer info updated - isPro: \(isPro)")

        // Post notification for UI updates
        NotificationCenter.default.post(
            name: Constants.proStatusDidChangeNotification,
            object: nil,
            userInfo: ["isPro": isPro]
        )
    }

    // MARK: - Public Methods

    /// Checks if user can access a Pro feature
    /// - Parameter feature: Feature identifier
    /// - Returns: True if user has access
    ///
    /// **RevenueCat Integration:**
    /// This checks RevenueCat's active entitlements instead of local state.
    /// RevenueCat automatically validates receipts and subscription status.
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
