import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Plugin that automatically tracks app lifecycle events
public class AppLifecyclePlugin: NuxiePlugin {
    
    // MARK: - NuxiePlugin Properties
    
    public let pluginId = "app-lifecycle"
    
    // MARK: - Private Properties
    
    private weak var sdk: NuxieSDK?
    private var isStarted = false
    
    // UserDefaults keys for tracking app state
    private let hasLaunchedBeforeKey = "nuxie_has_launched_before"
    private let lastVersionKey = "nuxie_last_version"
    
    // MARK: - Initialization
    
    public init() {
    }
    
    // MARK: - NuxiePlugin
    
    public func install(sdk: NuxieSDK) {
        self.sdk = sdk
        LogInfo("AppLifecyclePlugin installed")
    }
    
    public func uninstall() {
        stop()
        sdk = nil
        LogInfo("AppLifecyclePlugin uninstalled")
    }
    
    public func start() {
        guard !isStarted else { return }
        
        // Track app launch events immediately on start
        // The event system has internal queuing to handle events before it's ready
        trackAppLaunchEvents()
        
        isStarted = true
        LogInfo("AppLifecyclePlugin started")
    }
    
    public func stop() {
        guard isStarted else { return }
        
        isStarted = false
        LogInfo("AppLifecyclePlugin stopped")
    }
    
    // MARK: - Lifecycle Events
    
    public func onAppDidEnterBackground() {
        guard isStarted else { return }
        
        let properties: [String: Any] = [
            "source": "app_lifecycle_plugin",
            "background_date": Date().timeIntervalSince1970
        ]
        
        sdk?.track("$app_backgrounded", properties: properties)
    }
    
    public func onAppWillEnterForeground() {
        guard isStarted else { return }
        
        let properties: [String: Any] = [
            "source": "app_lifecycle_plugin",
            "foreground_date": Date().timeIntervalSince1970,
            "app_version": getCurrentAppVersion()
        ]
        
        sdk?.track("$app_opened", properties: properties)
    }
    
    // MARK: - Private Methods
    
    private func trackAppLaunchEvents() {
        let userDefaults = UserDefaults.standard
        let currentVersion = getCurrentAppVersion()
        
        let hasLaunchedBefore = userDefaults.bool(forKey: hasLaunchedBeforeKey)
        let lastVersion = userDefaults.string(forKey: lastVersionKey)
        
        var properties: [String: Any] = [
            "source": "app_lifecycle_plugin",
            "app_version": currentVersion
        ]
        
        if !hasLaunchedBefore {
            // First launch - App Installed
            properties["install_date"] = Date().timeIntervalSince1970
            sdk?.track("$app_installed", properties: properties)
            
            // Mark as launched and save version
            userDefaults.set(true, forKey: hasLaunchedBeforeKey)
            userDefaults.set(currentVersion, forKey: lastVersionKey)
            
        } else if let lastVersion = lastVersion, lastVersion != currentVersion {
            // App Updated
            properties["previous_version"] = lastVersion
            properties["update_date"] = Date().timeIntervalSince1970
            sdk?.track("$app_updated", properties: properties)
            
            // Update stored version
            userDefaults.set(currentVersion, forKey: lastVersionKey)
        }
        
        // Always track App Opened (including first launch and updates)
        properties["open_date"] = Date().timeIntervalSince1970
        sdk?.track("$app_opened", properties: properties)
    }
    
    private func getCurrentAppVersion() -> String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                return "\(version) (\(build))"
            }
            return version
        }
        return "unknown"
    }
}