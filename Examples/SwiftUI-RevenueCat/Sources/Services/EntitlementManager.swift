//
//  EntitlementManager.swift
//  MoodLog
//
//  Manages Pro subscription status and entitlements using RevenueCat.
//  Conforms to PurchasesDelegate to receive entitlement updates.
//
//  **SwiftUI Adaptation:**
//  This class is an ObservableObject with @Published isProUser property,
//  allowing SwiftUI views to reactively update when Pro status changes.
//

import Foundation
import SwiftUI
import Combine
import RevenueCat

/// Manages user entitlements and Pro status using RevenueCat
/// **ObservableObject** for reactive SwiftUI updates
/// Conforms to **PurchasesDelegate** to receive entitlement updates
final class EntitlementManager: NSObject, ObservableObject, PurchasesDelegate {

    // MARK: - Singleton

    static let shared = EntitlementManager()

    // MARK: - Published Properties

    /// Returns true if user has Pro access
    /// Published so SwiftUI views automatically update when Pro status changes
    /// Checks RevenueCat's active entitlements instead of local state
    @Published var isProUser: Bool = false

    // MARK: - Initialization

    private override init() {
        super.init()

        // Check initial Pro status from RevenueCat's cached customer info
        updateProStatus()

        print("[EntitlementManager] Initialized with RevenueCat")
    }

    // MARK: - PurchasesDelegate

    /// Called when RevenueCat receives updated customer info
    func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        print("[EntitlementManager] Customer info updated")
        updateProStatus()
    }

    // MARK: - Private Methods

    /// Updates the Pro status based on RevenueCat's active entitlements
    private func updateProStatus() {
        let isPro = Purchases.shared.cachedCustomerInfo?.entitlements.active.isEmpty == false

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
