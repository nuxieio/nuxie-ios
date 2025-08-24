import Foundation

/// Environment settings
public enum Environment: String {
    case production = "production"
    case staging = "staging"
    case development = "development"
    case custom = "custom"
    
    var defaultEndpoint: URL {
        switch self {
        case .production:
            return URL(string: "https://i.nuxie.io")!
        case .staging:
            return URL(string: "https://staging-i.nuxie.io")!
        case .development:
            return URL(string: "https://dev-i.nuxie.io")!
        case .custom:
            return URL(string: "https://i.nuxie.io")!
        }
    }
}

/// Log levels
public enum LogLevel: String {
    case verbose = "verbose"
    case debug = "debug"
    case info = "info"
    case warning = "warning"
    case error = "error"
    case none = "none"
}

/// Event linking policy for handling anonymous to identified user transitions
public enum EventLinkingPolicy {
    /// Keep anonymous and identified events separate
    case keepSeparate
    
    /// Migrate anonymous events to identified user on identify (default)
    case migrateOnIdentify
}

/// Configuration object for initializing Nuxie SDK
public class NuxieConfiguration {
    /// Required: API key for authentication
    public let apiKey: String
    
    /// API endpoint (defaults to production)
    public var apiEndpoint: URL = URL(string: "https://i.nuxie.io")!
    
    /// Environment setting
    public var environment: Environment = .production {
        didSet {
            // Update endpoint if using default
            if apiEndpoint == oldValue.defaultEndpoint {
                apiEndpoint = environment.defaultEndpoint
            }
        }
    }
    
    /// Logging settings
    public var logLevel: LogLevel = .warning
    public var enableConsoleLogging: Bool = true
    public var enableFileLogging: Bool = false
    public var redactSensitiveData: Bool = true
    
    /// Network settings
    public var requestTimeout: TimeInterval = 30
    public var retryCount: Int = 3
    public var retryDelay: TimeInterval = 2
    public var syncInterval: TimeInterval = 3600 // 1 hour
    public var enableCompression: Bool = true
    
    /// Event batching settings
    public var eventBatchSize: Int = 50 // Maximum events per batch
    public var flushAt: Int = 20 // Number of events to trigger automatic flush
    public var flushInterval: TimeInterval = 30 // Time interval to trigger automatic flush in seconds
    public var maxQueueSize: Int = 1000 // Maximum events to keep in queue
    
    /// Storage settings
    public var maxCacheSize: Int64 = 100 * 1024 * 1024 // 100 MB
    public var cacheExpiration: TimeInterval = 7 * 24 * 3600 // 7 days
    public var enableEncryption: Bool = true
    public var customStoragePath: URL?
    
    /// Behavior settings
    public var defaultPaywallTimeout: TimeInterval = 10
    public var respectDoNotTrack: Bool = true
    public var eventLinkingPolicy: EventLinkingPolicy = .migrateOnIdentify
    
    /// Plugin settings
    public var enablePlugins: Bool = true
    public var plugins: [NuxiePlugin] = []
    
    /// Event system settings
    public var propertiesSanitizer: NuxiePropertiesSanitizer?
    
    /// Optional beforeSend hook for event transformation/filtering
    /// Return nil to drop the event, or return a modified event
    public var beforeSend: ((NuxieEvent) -> NuxieEvent?)?
    
    /// Time window (in seconds) to wait for immediate flow presentation after tracking an event
    /// If a flow is shown within this window, the track completion will return the flow outcome
    /// Otherwise, it returns .noInteraction
    public var immediateOutcomeWindowSeconds: TimeInterval = 1.0
    
    /// Flow caching settings
    public var maxFlowCacheSize: Int64 = 500 * 1024 * 1024 // 500 MB
    public var flowCacheExpiration: TimeInterval = 7 * 24 * 3600 // 7 days
    public var maxConcurrentFlowDownloads: Int = 4
    public var flowDownloadTimeout: TimeInterval = 30
    public var flowCacheDirectory: URL?
    
    /// Custom URLSession for testing (if nil, a default one will be created)
    public var urlSession: URLSession?
    
    /// Purchase delegate for handling StoreKit purchases
    /// If not set, purchase operations will fail with notConfigured error
    public var purchaseDelegate: NuxiePurchaseDelegate?
    
    /// Initialize with API key
    public init(apiKey: String) {
        self.apiKey = apiKey
        
        // Default plugins
        setupDefaultPlugins()
    }
    
    /// Add a plugin to be installed during SDK setup
    /// - Parameter plugin: Plugin instance to install
    public func addPlugin(_ plugin: NuxiePlugin) {
        plugins.append(plugin)
    }
    
    /// Remove a plugin from the installation list
    /// - Parameter pluginId: Plugin identifier to remove
    public func removePlugin(_ pluginId: String) {
        plugins.removeAll { $0.pluginId == pluginId }
    }
    
    /// Set up default plugins that should always be installed
    private func setupDefaultPlugins() {
        // Always include app lifecycle plugin by default
        plugins.append(AppLifecyclePlugin())
    }
}
