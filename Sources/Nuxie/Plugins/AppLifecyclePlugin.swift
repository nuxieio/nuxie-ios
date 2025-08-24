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
    private var notificationObservers: [Any] = []
    
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
        
        // Register for app lifecycle notifications
        registerForNotifications()
        
        // Track app launch events (install/update/open)
        trackAppLaunchEvents()
        
        isStarted = true
        LogInfo("AppLifecyclePlugin started")
    }
    
    public func stop() {
        guard isStarted else { return }
        
        // Unregister from notifications
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
        
        isStarted = false
        LogInfo("AppLifecyclePlugin stopped")
    }
    
    // MARK: - Private Methods
    
    private func registerForNotifications() {
        #if canImport(UIKit)
        let notificationCenter = NotificationCenter.default
        
        let backgroundObserver = notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.appDidEnterBackground()
        }
        notificationObservers.append(backgroundObserver)
        
        let foregroundObserver = notificationCenter.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.appWillEnterForeground()
        }
        notificationObservers.append(foregroundObserver)
        #endif
    }
    
    // MARK: - Event Tracking Methods
    
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
    
    // MARK: - Notification Handlers
    
    private func appDidEnterBackground() {
        #if canImport(UIKit)
        let properties: [String: Any] = [
            "source": "app_lifecycle_plugin",
            "background_date": Date().timeIntervalSince1970
        ]
        
        sdk?.track("$app_backgrounded", properties: properties)
        #endif
    }
    
    private func appWillEnterForeground() {
        #if canImport(UIKit)
        let properties: [String: Any] = [
            "source": "app_lifecycle_plugin",
            "foreground_date": Date().timeIntervalSince1970,
            "app_version": getCurrentAppVersion()
        ]
        
        sdk?.track("$app_opened", properties: properties)
        #endif
    }
}