import Foundation
import FactoryKit

#if canImport(UIKit)
  import UIKit
#endif

/// Main entry point for the Nuxie SDK
public final class NuxieSDK {

  /// Shared singleton instance
  public static let shared = NuxieSDK()

  /// Private initializer to enforce singleton pattern
  private init() {
  }

  /// Current configuration (nil if not configured)
  private(set) public var configuration: NuxieConfiguration?

  /// Whether the SDK has been configured
  public var isSetup: Bool {
    if configuration == nil {
      LogWarning("SDK not configured. Call setup() first.")
    }
    return configuration != nil
  }

  // MARK: - Private Properties

  private let container = Container.shared

  private var lifecycleCoordinator: NuxieLifecycleCoordinator?

  // MARK: - Setup

  /// Setup the SDK (must be called before any other methods)
  /// - Parameter configuration: Configuration object
  /// - Throws: NuxieError if configuration is invalid
  public func setup(with configuration: NuxieConfiguration) throws {
    // Validate configuration
    guard !configuration.apiKey.isEmpty else {
      throw NuxieError.invalidConfiguration("API key cannot be empty")
    }

    // Prevent reconfiguration
    guard self.configuration == nil else {
      LogWarning("SDK already configured. Skipping setup.")
      return
    }

    // Store configuration and register it FIRST before any service creation
    self.configuration = configuration
    container.sdkConfiguration.register { configuration }

    // Configure logger
    NuxieLogger.shared.configure(
      logLevel: configuration.logLevel,
      enableConsoleLogging: configuration.enableConsoleLogging,
      enableFileLogging: configuration.enableFileLogging,
      redactSensitiveData: configuration.redactSensitiveData
    )

    // Start lifecycle coordinator after configuration is registered
    lifecycleCoordinator = NuxieLifecycleCoordinator()
    lifecycleCoordinator?.start()

    // Initialize event system
    LogDebug("Setting up event system...")
    let identityService = Container.shared.identityService()
    let contextBuilder = NuxieContextBuilder(
      identityService: identityService,
      configuration: configuration
    )

    let networkQueue = NuxieNetworkQueue(
      flushAt: configuration.flushAt,
      flushIntervalSeconds: configuration.flushInterval,
      maxQueueSize: configuration.maxQueueSize,
      maxBatchSize: configuration.eventBatchSize,
      maxRetries: configuration.retryCount,
      baseRetryDelay: configuration.retryDelay,
      apiClient: Container.shared.nuxieApi()
    )

    let eventService = Container.shared.eventService()
    let journeyService = Container.shared.journeyService()

    Task {
      try await eventService.configure(
        networkQueue: networkQueue,
        journeyService: journeyService,
        contextBuilder: contextBuilder,
        configuration: configuration
      )
      LogDebug("Event system setup complete")
    }

    Task {
      await journeyService.initialize()
    }

    // Initialize plugin system
    if configuration.enablePlugins {
      LogDebug("Setting up plugin system...")
      setupPluginSystem()
      LogDebug("Plugin system setup complete")
    }

    // Fetch initial profile data
    Task {
      do { _ = try await Container.shared.profileService().refetchProfile() }
      catch { LogWarning("Profile fetch failed: \(error)") }
    }

    LogInfo("Setup completed with API key: \(NuxieLogger.shared.logAPIKey(configuration.apiKey))")
  }

  /// Manually shut down the SDK and clean up resources
  /// This is typically not needed as the singleton will clean up automatically
  public func shutdown() async {
    guard isSetup else { return }

    // Clean up plugins first
    container.pluginService().cleanup()
    
    await container.journeyService().shutdown()
    await container.eventService().close()
    await container.profileService().cleanupExpired()

    // Drop all cached instances in the SDK scope (they’ll be recreated on next setup)
    Container.shared.manager.reset(scope: .sdk)

    // API is managed by Factory container
    configuration = nil

    lifecycleCoordinator?.stop()
    lifecycleCoordinator = nil

    LogInfo("SDK shutdown completed")
  }

  // MARK: - Core Event Method

  /// Track an event with optional user properties (synchronous wrapper)
  /// - Parameters:
  ///   - event: Event name
  ///   - properties: Event properties
  ///   - userProperties: Properties to set on the user profile (mapped to $set)
  ///   - userPropertiesSetOnce: Properties to set once on the user profile (mapped to $set_once)
  ///   - completion: Optional completion handler called when event completes (immediately or after immediate flow)
  public func track(
    _ event: String,
    properties: [String: Any]? = nil,
    userProperties: [String: Any]? = nil,
    userPropertiesSetOnce: [String: Any]? = nil,
    completion: ((EventResult) -> Void)? = nil
  ) {
    container.eventService().track(
      event,
      properties: properties,
      userProperties: userProperties,
      userPropertiesSetOnce: userPropertiesSetOnce,
      completion: completion
    )
  }

  // MARK: - User Management
  
  /// Identify the current user with optional properties
  /// - Parameters:
  ///   - distinctId: Unique user identifier
  ///   - userProperties: Properties to set on the user profile (mapped to $set)
  ///   - userPropertiesSetOnce: Properties to set once on the user profile (mapped to $set_once)
  public func identify(
    _ distinctId: String,
    userProperties: [String: Any]? = nil,
    userPropertiesSetOnce: [String: Any]? = nil
  ) {
    guard isSetup else { return }
    
    let identityService = container.identityService()
    let eventService = container.eventService()
    
    let oldDistinctId = identityService.getDistinctId()
    let wasIdentified = identityService.isIdentified
    let hasDifferentDistinctId = distinctId != oldDistinctId
    
    // Set distinct ID for identified user
    identityService.setDistinctId(distinctId)
    
    let currentDistinctId = identityService.getDistinctId()
    LogInfo("Identifying user: \(NuxieLogger.shared.logDistinctID(currentDistinctId))")
    
    // Handle user change across all services if user changed
    if hasDifferentDistinctId {
      Task {
        // ProfileService handles its own cache transition
        let profileService = container.profileService()
        await profileService.handleUserChange(from: oldDistinctId, to: currentDistinctId)
        
        // SegmentService needs to handle identity transition
        let segmentService = container.segmentService()
        await segmentService.handleUserChange(from: oldDistinctId, to: currentDistinctId)
        
        // JourneyService needs to cancel old journeys and load new ones
        let journeyService = container.journeyService()
        await journeyService.handleUserChange(from: oldDistinctId, to: currentDistinctId)
      }
    }
    
    // Reassign anonymous events to identified user if transitioning from anonymous
    if !wasIdentified && hasDifferentDistinctId,
       let config = configuration,
       config.eventLinkingPolicy == .migrateOnIdentify {
      // Only reassign local DB events (server handles in-flight events via $identify)
      Task {
        do {
          let reassignedCount = try await eventService.reassignEvents(from: oldDistinctId, to: currentDistinctId)
          if reassignedCount > 0 {
            LogInfo("Migrated \(reassignedCount) anonymous events to identified user: \(NuxieLogger.shared.logDistinctID(currentDistinctId))")
          }
        } catch {
          // Non-blocking: log warning but continue with identify process
          LogWarning("Failed to reassign anonymous events: \(error)")
        }
      }
    }
    
    // Start new session when user is identified
    container.sessionService().startSession()
    
    // Use EventService's identifyUser method for proper queue management
    var props: [String: Any] = ["distinct_id": currentDistinctId]
    if !wasIdentified, hasDifferentDistinctId {
      props["$anon_distinct_id"] = oldDistinctId
    }
    eventService.track(
      "$identify",
      properties: props,
      userProperties: userProperties,
      userPropertiesSetOnce: userPropertiesSetOnce,
      completion: nil
    )
  }

  /// Reset user identity (logout)
  /// - Parameter keepAnonymousId: Whether to keep the anonymous ID (default: true)
  public func reset(keepAnonymousId: Bool = true) {
    guard isSetup else { return }
    
    let identityService = container.identityService()
    let previousDistinctId = identityService.getDistinctId()

    // Reset identity
    identityService.reset(keepAnonymousId: keepAnonymousId)

    // Clear data for previous user and handle transition to anonymous
    Task {
      let profileService = container.profileService()
      await profileService.clearCache(distinctId: previousDistinctId)
      
      // Get the new distinct ID (will be anonymous ID after reset)
      let newDistinctId = identityService.getDistinctId()
      
      // Clear segment data for the previous user and handle user change
      let segmentService = container.segmentService()
      await segmentService.clearSegments(for: previousDistinctId)
      await segmentService.handleUserChange(from: previousDistinctId, to: newDistinctId)
      
      // Handle user change in JourneyService (cancel old journeys, load new)
      let journeyService = container.journeyService()
      await journeyService.handleUserChange(from: previousDistinctId, to: newDistinctId)
    }

    // Start new session on reset
    container.sessionService().resetSession()
    
    // Clear flow cache
    Task {
      let flowService = container.flowService()
      await flowService.clearCache()
    }
  }


  // MARK: - Utility

  /// Get current SDK version
  public var version: String {
    SDKVersion.current
  }


  // MARK: - Event History (Internal use for workflow evaluation)

  /// Get recent events for workflow evaluation
  /// - Parameter limit: Maximum events to return (default: 100)
  /// - Returns: Array of recent events or empty array if storage unavailable
  internal func getRecentEvents(limit: Int = 100) async -> [StoredEvent] {
    let eventService = container.eventService()
    return await eventService.getRecentEvents(limit: limit)
  }

  /// Get events for the current user
  /// - Parameter limit: Maximum events to return (default: 100)
  /// - Returns: Array of user events or empty array if storage unavailable
  internal func getCurrentUserEvents(limit: Int = 100) async -> [StoredEvent] {
    let identityService = container.identityService()
    let eventService = container.eventService()

    let distinctId = identityService.getDistinctId()
    return await eventService.getEventsForUser(distinctId, limit: limit)
  }

  /// Get events from the current session
  /// - Returns: Array of session events or empty array if storage unavailable
  internal func getCurrentSessionEvents() async -> [StoredEvent] {
    // Get current session ID
    guard let sessionId = container.sessionService().getSessionId(at: Date(), readOnly: true) else {
      return []
    }
    
    let eventService = container.eventService()
    return await eventService.getEvents(for: sessionId)
  }

  // MARK: - Session Management
  
  /// Start a new session
  public func startNewSession() {
    guard isSetup else { return }
    container.sessionService().startSession()
  }
  
  /// Get the current session ID
  /// - Returns: Current session ID or nil if no session exists
  public func getCurrentSessionId() -> String? {
    guard isSetup else { return nil }
    return container.sessionService().getSessionId(at: Date(), readOnly: true)
  }
  
  /// Set a custom session ID
  /// - Parameter sessionId: Custom session ID to use
  public func setSessionId(_ sessionId: String) {
    guard isSetup else { return }
    container.sessionService().setSessionId(sessionId)
  }
  
  /// End the current session
  public func endSession() {
    guard isSetup else { return }
    container.sessionService().endSession()
  }
  
  /// Reset the session (clear and start new)
  public func resetSession() {
    guard isSetup else { return }
    container.sessionService().resetSession()
  }

  // MARK: - Plugin Management

  /// Install a plugin
  /// - Parameter plugin: Plugin instance to install
  /// - Throws: PluginError if installation fails
  public func installPlugin(_ plugin: NuxiePlugin) throws {
    guard isSetup else {
      throw NuxieError.notConfigured
    }

    let pluginService = container.pluginService()

    try pluginService.installPlugin(plugin)
  }

  /// Uninstall a plugin
  /// - Parameter pluginId: Plugin identifier to uninstall
  /// - Throws: PluginError if uninstallation fails
  public func uninstallPlugin(_ pluginId: String) throws {
    guard isSetup else {
      throw NuxieError.notConfigured
    }

    let pluginService = container.pluginService()

    try pluginService.uninstallPlugin(pluginId)
  }

  /// Start a plugin
  /// - Parameter pluginId: Plugin identifier to start
  public func startPlugin(_ pluginId: String) {
    guard isSetup else { return }
    let pluginService = container.pluginService()
    pluginService.startPlugin(pluginId)
  }

  /// Stop a plugin
  /// - Parameter pluginId: Plugin identifier to stop
  public func stopPlugin(_ pluginId: String) {
    guard isSetup else { return }
    let pluginService = container.pluginService()
    pluginService.stopPlugin(pluginId)
  }

  /// Check if a plugin is installed
  /// - Parameter pluginId: Plugin identifier
  /// - Returns: True if plugin is installed
  public func isPluginInstalled(_ pluginId: String) -> Bool {
    guard isSetup else { return false }
    let pluginService = container.pluginService()
    return pluginService.isPluginInstalled(pluginId)
  }

  // MARK: - Private Methods

  /// Check if SDK is enabled and log warning if not
  /// - Returns: True if SDK is setup, false otherwise
  private func checkIsSetup() -> Bool {
    guard isSetup else { return false }
    return true
  }

  private func setupPluginSystem() {
    let pluginService = container.pluginService()
    pluginService.initialize(sdk: self)

    // Install all plugins defined in configuration
    guard let configuration = configuration else { return }

    for plugin in configuration.plugins {
      do {
        try pluginService.installPlugin(plugin)
        pluginService.startPlugin(plugin.pluginId)
        LogInfo("Plugin installed and started: \(plugin.pluginId)")
      } catch {
        LogError("Failed to install plugin \(plugin.pluginId): \(error)")
      }
    }
  }

  /// Get current distinct ID (always returns a value - anonymous ID if not identified)
  /// - Returns: Distinct ID if identified, anonymous ID otherwise
  public func getDistinctId() -> String {
    guard isSetup else { return "" }
    // IdentityService's getDistinctId() already returns anonymous ID as fallback
    let identityService = container.identityService()
    return identityService.getDistinctId()
  }

  /// Get anonymous ID
  /// - Returns: Anonymous ID (always available)
  public func getAnonymousId() -> String {
    guard isSetup else { return "" }
    let identityService = container.identityService()
    return identityService.getAnonymousId()
  }

  /// Check if user is currently identified
  /// - Returns: True if user has a distinct ID, false if anonymous
  public var isIdentified: Bool {
    guard isSetup else { return false }
    let identityService = container.identityService()
    return identityService.isIdentified
  }

  // MARK: - Flow Management
  
  /// Get a view controller for presenting a paywall/flow
  /// - Parameter flowId: The ID of the flow to present
  /// - Returns: A FlowViewController configured for the flow
  /// - Throws: NuxieError if SDK not configured or flow not found
  @MainActor
  public func getFlowViewController(with flowId: String) async throws -> FlowViewController {
    guard isSetup else {
      throw NuxieError.notConfigured
    }
    
    let flowService = container.flowService()
    return try await flowService.viewController(for: flowId)
  }
  
  /// Present a flow by ID in a dedicated window
  /// - Parameter flowId: The ID of the flow to present
  /// - Throws: NuxieError if SDK not configured or flow presentation fails
  @MainActor
  public func showFlow(with flowId: String) async throws {
    guard isSetup else {
      throw NuxieError.notConfigured
    }
    
    let flowPresentationService = container.flowPresentationService()
    try await flowPresentationService.presentFlow(flowId, from: nil)
  }

  // MARK: - Profile Management

  /// Refresh the user profile from the server
  /// Call this after changing `configuration.localeIdentifier` to fetch locale-specific content
  /// - Returns: The refreshed profile response
  /// - Throws: NuxieError if SDK not configured or network request fails
  @discardableResult
  public func refreshProfile() async throws -> ProfileResponse {
    guard isSetup else {
      throw NuxieError.notConfigured
    }

    let profileService = container.profileService()
    return try await profileService.refetchProfile()
  }

  // MARK: - Event System Public API

  /// Manually flush the network queue
  /// - Returns: True if flush was initiated
  @discardableResult
  public func flushEvents() async -> Bool {
    guard isSetup else { return false }
    let eventService = container.eventService()
    return await eventService.flushEvents()
  }

  /// Get current network queue size
  /// - Returns: Number of events queued for network delivery
  public func getQueuedEventCount() async -> Int {
    guard isSetup else { return 0 }
    let eventService = container.eventService()
    return await eventService.getQueuedEventCount()
  }

  /// Pause event queue (stops network delivery)
  public func pauseEventQueue() async {
    guard isSetup else { return }
    let eventService = container.eventService()
    await eventService.pauseEventQueue()
  }

  /// Resume event queue (enables network delivery)
  public func resumeEventQueue() async {
    guard isSetup else { return }
    let eventService = container.eventService()
    await eventService.resumeEventQueue()
  }

}
