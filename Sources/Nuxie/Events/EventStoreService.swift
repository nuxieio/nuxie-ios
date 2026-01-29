import Foundation

/// Protocol for event store operations
protocol EventStoreProtocol {
    /// Initialize the event storage system
    /// - Throws: EventStorageError if initialization fails
    func initialize(path: URL?) async throws
        
    /// Reset the event store (close and delete database)
    func reset() async
    
    /// Store an event with automatic session and timestamp handling
    /// - Parameters:
    ///   - name: Event name
    ///   - properties: Event properties
    ///   - distinctId: Distinct ID (optional)
    /// - Throws: EventStorageError if storage fails
    func storeEvent(name: String, properties: [String: Any], distinctId: String) async throws
    
    /// Get recent events for analysis
    /// - Parameter limit: Maximum events to return (default: 100)
    /// - Returns: Array of stored events
    /// - Throws: EventStorageError if query fails
    func getRecentEvents(limit: Int) async throws -> [StoredEvent]
    
    /// Get events for a specific user
    /// - Parameters:
    ///   - distinctId: Distinct ID to filter by
    ///   - limit: Maximum events to return
    /// - Returns: Array of stored events for the user
    /// - Throws: EventStorageError if query fails
    func getEventsForUser(_ distinctId: String, limit: Int) async throws -> [StoredEvent]
    
    /// Get events for a specific session
    /// - Parameter sessionId: Session ID to filter by
    /// - Returns: Array of events from the specified session
    /// - Throws: EventStorageError if query fails
    func getEvents(for sessionId: String) async throws -> [StoredEvent]
    
    /// Get event count statistics
    /// - Returns: Total number of events stored
    /// - Throws: EventStorageError if query fails
    func getEventCount() async throws -> Int
    
    /// Force cleanup of old events
    /// - Returns: Number of events deleted
    /// - Throws: EventStorageError if cleanup fails
    @discardableResult
    func forceCleanup() async throws -> Int
    
    /// Close the event store (called on SDK teardown)
    func close() async
    
    // MARK: - Event Query Methods
    
    /// Check if a specific event exists for a user
    /// - Parameters:
    ///   - name: Event name to search for
    ///   - distinctId: User ID to filter by
    ///   - since: Optional date to filter events after
    /// - Returns: True if event exists, false otherwise
    /// - Throws: EventStorageError if query fails
    func hasEvent(name: String, distinctId: String, since: Date?) async throws -> Bool
    
    /// Count events of a specific type for a user
    /// - Parameters:
    ///   - name: Event name to count
    ///   - distinctId: User ID to filter by
    ///   - since: Optional start date (inclusive)
    ///   - until: Optional end date (inclusive)
    /// - Returns: Number of matching events
    /// - Throws: EventStorageError if query fails
    func countEvents(name: String, distinctId: String, since: Date?, until: Date?) async throws -> Int
    
    /// Get the timestamp of the most recent event of a specific type for a user
    /// - Parameters:
    ///   - name: Event name to search for
    ///   - distinctId: User ID to filter by
    ///   - since: Optional start date (inclusive)
    ///   - until: Optional end date (inclusive)
    /// - Returns: Date of most recent event, or nil if no events found
    /// - Throws: EventStorageError if query fails
    func getLastEventTime(name: String, distinctId: String, since: Date?, until: Date?) async throws -> Date?
    
    /// Reassign events from one user to another (for anonymous → identified transitions)
    /// - Parameters:
    ///   - fromUserId: Old user ID (typically anonymous)
    ///   - toUserId: New user ID (typically identified)
    /// - Returns: Number of events reassigned
    /// - Throws: EventStorageError if update fails
    func reassignEvents(from fromUserId: String, to toUserId: String) async throws -> Int
}

/// Manager for handling event storage operations with business logic
final class EventStore: EventStoreProtocol {
    
    // MARK: - Properties
    
    private let eventStore: SQLiteEventStore
    private let maxEventsStored: Int
    private let cleanupThresholdDays: Int

    // MARK: - Initialization
    
    /// Initialize the event store manager with custom settings (for testing or specific configurations)
    /// - Parameters:
    ///   - maxEventsStored: Maximum events to keep in storage (default: 10,000)
    ///   - cleanupThresholdDays: Delete events older than this many days (default: 30)
    init(
        maxEventsStored: Int = 10_000,
        cleanupThresholdDays: Int = 30
    ) {
        self.eventStore = SQLiteEventStore()
        self.maxEventsStored = maxEventsStored
        self.cleanupThresholdDays = cleanupThresholdDays
    }
    
    // MARK: - Public Methods
    
    /// Initialize the event storage system
    /// - Parameter path: Custom database path (optional)
    /// - Throws: EventStorageError if initialization fails
    func initialize(path: URL?) async throws {
        try await eventStore.initialize(path: path)
        
        // Perform cleanup on initialization
        try await performCleanupIfNeeded()
        
        LogInfo("EventStoreManager initialized")
    }
    
    /// Reset the event store (close and delete database)
    func reset() async {
        // Close the store
        await eventStore.reset()
                
        LogInfo("EventStore reset completed")
    }
    
    /// Store an event with automatic session and timestamp handling
    /// - Parameters:
    ///   - name: Event name
    ///   - properties: Event properties
    ///   - distinctId: Distinct ID (optional)
    /// - Throws: EventStorageError if storage fails
    func storeEvent(
        name: String,
        properties: [String: Any] = [:],
        distinctId: String
    ) async throws {
        LogDebug("EventStore.storeEvent called - name: \(name), distinctId: \(distinctId ?? "nil")")
        
        // Create enriched properties with metadata
        var enrichedProperties = properties
        enrichedProperties["sdk_version"] = SDKVersion.current
        enrichedProperties["platform"] = "ios"
        
        // Add device info if not already present
        if enrichedProperties["device_model"] == nil {
            enrichedProperties["device_model"] = getDeviceModel()
        }
        if enrichedProperties["os_version"] == nil {
            enrichedProperties["os_version"] = getOSVersion()
        }
        
        // Create stored event
        // Note: Session ID should be provided by the caller (e.g., NuxieSDK)
        // EventStore should not fetch it directly to avoid coupling
        let event = try StoredEvent(
            name: name,
            properties: enrichedProperties,
            distinctId: distinctId
        )
        
        LogDebug("Created StoredEvent with id: \(event.id)")
        
        // Store the event
        try await eventStore.insertEvent(event)
        
        LogDebug("Stored event: \(name) (user: \(NuxieLogger.shared.logDistinctID(distinctId)))")
        
        // Trigger cleanup if we're over the limit
        try await performCleanupIfNeeded()
    }
    
    /// Get recent events for analysis
    /// - Parameter limit: Maximum events to return (default: 100)
    /// - Returns: Array of stored events
    /// - Throws: EventStorageError if query fails
    func getRecentEvents(limit: Int = 100) async throws -> [StoredEvent] {
        return try await eventStore.queryRecentEvents(limit: limit)
    }
    
    /// Get events for a specific user
    /// - Parameters:
    ///   - distinctId: Distinct ID to filter by
    ///   - limit: Maximum events to return
    /// - Returns: Array of stored events for the user
    /// - Throws: EventStorageError if query fails
    func getEventsForUser(_ distinctId: String, limit: Int = 100) async throws -> [StoredEvent] {
        // Use efficient database query with indexed user_id column
        return try await eventStore.queryEventsForUser(distinctId, limit: limit)
    }
    
    /// Get events for a specific session
    /// - Parameter sessionId: Session ID to filter by
    /// - Returns: Array of events from the specified session
    /// - Throws: EventStorageError if query fails
    func getEvents(for sessionId: String) async throws -> [StoredEvent] {
        // Use efficient database query with indexed session_id column
        return try await eventStore.querySessionEvents(sessionId)
    }
    
    
    /// Get event count statistics
    /// - Returns: Total number of events stored
    /// - Throws: EventStorageError if query fails
    func getEventCount() async throws -> Int {
        return try await eventStore.getEventCount()
    }
    
    /// Force cleanup of old events
    /// - Returns: Number of events deleted
    /// - Throws: EventStorageError if cleanup fails
    @discardableResult
    func forceCleanup() async throws -> Int {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -cleanupThresholdDays, to: Date()) ?? Date()
        let deletedCount = try await eventStore.deleteEventsOlderThan(cutoffDate)
        
        if deletedCount > 0 {
            LogInfo("Cleaned up \(deletedCount) old events")
        }
        
        return deletedCount
    }
    
    /// Close the event store (called on SDK teardown)
    func close() async {
        await eventStore.close()
        LogInfo("EventStoreManager closed")
    }
    
    
    // MARK: - Event Query Methods
    
    /// Check if a specific event exists for a user
    /// - Parameters:
    ///   - name: Event name to search for
    ///   - distinctId: User ID to filter by
    ///   - since: Optional date to filter events after
    /// - Returns: True if event exists, false otherwise
    /// - Throws: EventStorageError if query fails
    func hasEvent(name: String, distinctId: String, since: Date? = nil) async throws -> Bool {
        return try await eventStore.hasEvent(name: name, distinctId: distinctId, since: since)
    }
    
    /// Count events of a specific type for a user
    /// - Parameters:
    ///   - name: Event name to count
    ///   - distinctId: User ID to filter by
    ///   - since: Optional date to filter events after
    /// - Returns: Number of matching events
    /// - Throws: EventStorageError if query fails
    func countEvents(name: String, distinctId: String, since: Date? = nil, until: Date? = nil) async throws -> Int {
        return try await eventStore.countEvents(name: name, distinctId: distinctId, since: since, until: until)
    }
    
    /// Get the timestamp of the most recent event of a specific type for a user
    /// - Parameters:
    ///   - name: Event name to search for
    ///   - distinctId: User ID to filter by
    ///   - since: Optional start date (inclusive)
    ///   - until: Optional end date (inclusive)
    /// - Returns: Date of most recent event, or nil if no events found
    /// - Throws: EventStorageError if query fails
    func getLastEventTime(name: String, distinctId: String, since: Date? = nil, until: Date? = nil) async throws -> Date? {
        return try await eventStore.getLastEventTime(name: name, distinctId: distinctId, since: since, until: until)
    }
    
    /// Reassign events from one user to another (for anonymous → identified transitions)
    /// - Parameters:
    ///   - fromUserId: Old user ID (typically anonymous)
    ///   - toUserId: New user ID (typically identified)
    /// - Returns: Number of events reassigned
    /// - Throws: EventStorageError if update fails
    func reassignEvents(from fromUserId: String, to toUserId: String) async throws -> Int {
        let reassignedCount = try await eventStore.reassignEvents(from: fromUserId, to: toUserId)
        if reassignedCount > 0 {
            LogInfo("Reassigned \(reassignedCount) events from \(NuxieLogger.shared.logDistinctID(fromUserId)) to \(NuxieLogger.shared.logDistinctID(toUserId))")
        }
        return reassignedCount
    }
    
    // MARK: - Private Methods
    
    private func performCleanupIfNeeded() async throws {
        let eventCount = try await eventStore.getEventCount()
        
        // Clean up if we have too many events
        if eventCount > maxEventsStored {
            // Delete oldest events to get back under limit
            let cutoffDate = Calendar.current.date(byAdding: .day, value: -cleanupThresholdDays, to: Date()) ?? Date()
            let deletedCount = try await eventStore.deleteEventsOlderThan(cutoffDate)
            
            LogInfo("Cleaned up \(deletedCount) events due to storage limit (had \(eventCount) events)")
        }
    }
    
    private func getDeviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }
    
    private func getOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
