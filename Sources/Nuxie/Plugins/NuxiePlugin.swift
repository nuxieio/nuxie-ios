import Foundation

/// Simple protocol that all Nuxie plugins must conform to
public protocol NuxiePlugin: AnyObject {
    
    /// Unique identifier for the plugin
    var pluginId: String { get }
    
    /// Called when the plugin is installed - receives SDK reference
    /// - Parameter sdk: Reference to the Nuxie SDK singleton
    func install(sdk: NuxieSDK)
    
    /// Called when the plugin should be uninstalled
    func uninstall()
    
    /// Called to start the plugin functionality
    func start()
    
    /// Called to stop the plugin functionality
    func stop()
}

/// Plugin error types
public enum PluginError: Error, LocalizedError {
    case pluginNotFound(String)
    case pluginAlreadyInstalled(String)
    case pluginInstallationFailed(String, Error)
    case pluginUninstallationFailed(String, Error)
    
    public var errorDescription: String? {
        switch self {
        case .pluginNotFound(let id):
            return "Plugin not found: \(id)"
        case .pluginAlreadyInstalled(let id):
            return "Plugin already installed: \(id)"
        case .pluginInstallationFailed(let id, let error):
            return "Plugin installation failed for \(id): \(error.localizedDescription)"
        case .pluginUninstallationFailed(let id, let error):
            return "Plugin uninstallation failed for \(id): \(error.localizedDescription)"
        }
    }
}