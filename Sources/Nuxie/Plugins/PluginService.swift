import Foundation

/// Simple plugin manager that handles install/uninstall/start/stop
public class PluginService {
    
    public init() {}
    
    // MARK: - Properties
    
    /// Currently installed plugins
    private var installedPlugins: [String: NuxiePlugin] = [:]
    
    /// Simple lock for thread safety
    private let pluginLock = NSLock()
    
    /// Weak reference to SDK instance
    private weak var sdk: NuxieSDK?
    
    // MARK: - Initialization
    
    /// Initialize plugin manager with SDK instance
    /// - Parameter sdk: NuxieSDK instance
    internal func initialize(sdk: NuxieSDK) {
        self.sdk = sdk
        LogInfo("PluginManager initialized")
    }
    
    // MARK: - Plugin Management
    
    /// Install a plugin
    /// - Parameter plugin: Plugin instance to install
    /// - Throws: PluginError if installation fails
    public func installPlugin(_ plugin: NuxiePlugin) throws {
        guard let sdk = sdk else {
            throw PluginError.pluginInstallationFailed(plugin.pluginId, NSError(domain: "PluginManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "SDK not available"]))
        }
        
        pluginLock.lock()
        defer { pluginLock.unlock() }
        
        // Check if plugin already installed
        if installedPlugins[plugin.pluginId] != nil {
            throw PluginError.pluginAlreadyInstalled(plugin.pluginId)
        }
        
        // Install the plugin
        plugin.install(sdk: sdk)
        
        // Store plugin
        installedPlugins[plugin.pluginId] = plugin
        
        LogInfo("Plugin installed: \(plugin.pluginId)")
    }
    
    /// Uninstall a plugin
    /// - Parameter pluginId: Plugin identifier to uninstall
    /// - Throws: PluginError if uninstallation fails
    public func uninstallPlugin(_ pluginId: String) throws {
        pluginLock.lock()
        defer { pluginLock.unlock() }
        
        guard let plugin = installedPlugins[pluginId] else {
            throw PluginError.pluginNotFound(pluginId)
        }
        
        // Stop and uninstall the plugin
        plugin.stop()
        plugin.uninstall()
        
        // Remove from collection
        installedPlugins.removeValue(forKey: pluginId)
        
        LogInfo("Plugin uninstalled: \(pluginId)")
    }
    
    /// Start a plugin
    /// - Parameter pluginId: Plugin identifier to start
    public func startPlugin(_ pluginId: String) {
        pluginLock.lock()
        defer { pluginLock.unlock() }
        
        if let plugin = installedPlugins[pluginId] {
            plugin.start()
            LogDebug("Plugin started: \(pluginId)")
        }
    }
    
    /// Stop a plugin
    /// - Parameter pluginId: Plugin identifier to stop
    public func stopPlugin(_ pluginId: String) {
        pluginLock.lock()
        defer { pluginLock.unlock() }
        
        if let plugin = installedPlugins[pluginId] {
            plugin.stop()
            LogDebug("Plugin stopped: \(pluginId)")
        }
    }
    
    /// Start all installed plugins
    public func startAllPlugins() {
        pluginLock.lock()
        defer { pluginLock.unlock() }
        
        for plugin in installedPlugins.values {
            plugin.start()
        }
        LogDebug("All plugins started")
    }
    
    /// Stop all installed plugins
    public func stopAllPlugins() {
        pluginLock.lock()
        defer { pluginLock.unlock() }
        
        for plugin in installedPlugins.values {
            plugin.stop()
        }
        LogDebug("All plugins stopped")
    }
    
    // MARK: - Plugin Query
    
    /// Get all installed plugins
    /// - Returns: Dictionary of plugin ID to plugin instance
    public func getInstalledPlugins() -> [String: NuxiePlugin] {
        pluginLock.lock()
        defer { pluginLock.unlock() }
        return installedPlugins
    }
    
    /// Get a specific plugin by ID
    /// - Parameter pluginId: Plugin identifier
    /// - Returns: Plugin instance if found, nil otherwise
    public func getPlugin<T: NuxiePlugin>(_ pluginId: String, as type: T.Type) -> T? {
        pluginLock.lock()
        defer { pluginLock.unlock() }
        return installedPlugins[pluginId] as? T
    }
    
    /// Check if a plugin is installed
    /// - Parameter pluginId: Plugin identifier
    /// - Returns: True if plugin is installed
    public func isPluginInstalled(_ pluginId: String) -> Bool {
        pluginLock.lock()
        defer { pluginLock.unlock() }
        return installedPlugins[pluginId] != nil
    }
    
    // MARK: - Lifecycle Event Delegation
    
    /// Notify all started plugins that the app became active
    public func onAppBecameActive() {
        pluginLock.lock()
        defer { pluginLock.unlock() }
        
        for plugin in installedPlugins.values {
            plugin.onAppBecameActive()
        }
        LogDebug("Notified plugins of app becoming active")
    }
    
    /// Notify all started plugins that the app entered background
    public func onAppDidEnterBackground() {
        pluginLock.lock()
        defer { pluginLock.unlock() }
        
        for plugin in installedPlugins.values {
            plugin.onAppDidEnterBackground()
        }
        LogDebug("Notified plugins of app entering background")
    }
    
    /// Notify all started plugins that the app will enter foreground
    public func onAppWillEnterForeground() {
        pluginLock.lock()
        defer { pluginLock.unlock() }
        
        for plugin in installedPlugins.values {
            plugin.onAppWillEnterForeground()
        }
        LogDebug("Notified plugins of app will enter foreground")
    }
    
    // MARK: - Cleanup
    
    /// Uninstall all plugins and clean up
    internal func cleanup() {
        pluginLock.lock()
        defer { pluginLock.unlock() }
        
        // Stop and uninstall all plugins
        for plugin in installedPlugins.values {
            plugin.stop()
            plugin.uninstall()
        }
        
        // Clear references
        installedPlugins.removeAll()
        sdk = nil
        
        LogInfo("PluginManager cleanup completed")
    }
}
