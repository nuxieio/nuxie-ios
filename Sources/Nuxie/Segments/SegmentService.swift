import Foundation
import FactoryKit

/// Protocol for segment service operations
public protocol SegmentServiceProtocol {
    /// Get current segment memberships for the user
    /// - Returns: Array of current segment memberships
    func getCurrentMemberships() async -> [SegmentService.SegmentMembership]
    
    /// Update segment definitions for a specific user
    /// - Parameters:
    ///   - segments: New segment definitions
    ///   - distinctId: Distinct ID of the user
    func updateSegments(_ segments: [Segment], for distinctId: String) async
    
    /// Handle user change (identity transition)
    /// - Parameters:
    ///   - oldDistinctId: Previous distinct ID
    ///   - newDistinctId: New distinct ID
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async
    
    /// Clear all segment data for a specific user
    /// - Parameter distinctId: Distinct ID of the user to clear segments for
    func clearSegments(for distinctId: String) async
    
    /// Get async stream of segment changes
    var segmentChanges: AsyncStream<SegmentService.SegmentEvaluationResult> { get }
    
    /// Check if user is in a specific segment
    /// - Parameter segmentId: Segment ID to check
    /// - Returns: True if user is in the segment
    func isInSegment(_ segmentId: String) async -> Bool
    
    /// Is the current user a member of this segment? (alias for isInSegment)
    /// - Parameter segmentId: Segment ID to check
    /// - Returns: True if user is member of the segment
    func isMember(_ segmentId: String) async -> Bool
    
    /// When did the user enter this segment?
    /// - Parameter segmentId: Segment ID to check
    /// - Returns: Date when user entered the segment, nil if never/unknown
    func enteredAt(_ segmentId: String) async -> Date?
}

/// Manages segment evaluation, membership tracking, and change notifications
public actor SegmentService: SegmentServiceProtocol {
    
    // MARK: - Types
    
    /// Represents a user's membership in a segment
    public struct SegmentMembership: Codable {
        let segmentId: String
        let segmentName: String
        let enteredAt: Date
        let lastEvaluated: Date
        
        init(segmentId: String, segmentName: String, enteredAt: Date, lastEvaluated: Date? = nil) {
            self.segmentId = segmentId
            self.segmentName = segmentName
            self.enteredAt = enteredAt
            self.lastEvaluated = lastEvaluated ?? enteredAt
        }
    }
    
    /// Result of segment evaluation
    public struct SegmentEvaluationResult {
        public let distinctId: String     // User this evaluation is for
        public let entered: [Segment]     // Segments user just entered
        public let exited: [Segment]      // Segments user just exited
        public let remained: [Segment]    // Segments user remained in
        
        public var hasChanges: Bool {
            return !entered.isEmpty || !exited.isEmpty
        }
    }
    
    /// Context for segment evaluation
    public struct EvaluationContext {
        let distinctId: String
        let attributes: [String: Any]  // Derived from recent identify events
        let events: [StoredEvent]
        let currentDate: Date
        
        init(distinctId: String, attributes: [String: Any] = [:], events: [StoredEvent], currentDate: Date) {
            self.distinctId = distinctId
            self.attributes = attributes
            self.events = events
            self.currentDate = currentDate
        }
    }
    
    public enum EvaluationMode {
        case eager      // Evaluate immediately on every change
        case lazy       // Evaluate only when needed
        case hybrid     // Cache with TTL, evaluate on significant changes
    }
    
    // MARK: - Properties
    
    // Core evaluation properties
    private var segments: [Segment] = []
    private var memberships: [String: SegmentMembership] = [:] // segmentId -> membership
    private var irCache: [String: IRExpr] = [:] // segmentId -> compiled IR expression
    private let membershipCache: DiskCache<[String: SegmentMembership]>?
    
    // User and event management
    private var cachedAttributes: [String: Any] = [:] // Cached from identify events
    private var attributesCacheTime: Date?
    
    // Dependencies
    @Injected(\.eventService) private var eventService: EventServiceProtocol
    @Injected(\.identityService) private var identityService: IdentityServiceProtocol
    @Injected(\.dateProvider) private var dateProvider: DateProviderProtocol
    @Injected(\.sleepProvider) private var sleepProvider: SleepProviderProtocol
    @Injected(\.irRuntime) private var irRuntime: IRRuntime
    
    // AsyncStream for segment changes
    private var segmentChangesContinuation: AsyncStream<SegmentEvaluationResult>.Continuation?
    public let segmentChanges: AsyncStream<SegmentEvaluationResult>
    
    // Monitoring task
    private var monitoringTask: Task<Void, Never>?
    private let evaluationInterval: TimeInterval
    private let evaluationMode: EvaluationMode
    private let cacheTTLSeconds: TimeInterval
    
    // MARK: - Initialization
    
    /// Initialize with default configuration
    init() {
        self.evaluationInterval = 60 // Check segments every minute
        self.evaluationMode = .hybrid
        self.cacheTTLSeconds = 300 // 5 minutes
        
        // Set up AsyncStream
        var continuation: AsyncStream<SegmentEvaluationResult>.Continuation?
        self.segmentChanges = AsyncStream { cont in
            continuation = cont
        }
        self.segmentChangesContinuation = continuation
        
        // Try to initialize DiskCache for segment memberships (optional)
        if let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let cacheOptions = DiskCacheOptions(
                baseDirectory: cachesDirectory,
                subdirectory: "nuxie-segments",
                defaultTTL: nil,  // No TTL for segment memberships
                maxTotalBytes: 10 * 1024 * 1024,  // 10 MB cap
                excludeFromBackup: true,
                fileProtection: .completeUntilFirstUserAuthentication
            )
            
            do {
                self.membershipCache = try DiskCache<[String: SegmentMembership]>(options: cacheOptions)
                LogDebug("Segment disk cache initialized successfully")
            } catch {
                self.membershipCache = nil
                LogWarning("Failed to initialize segment disk cache, using in-memory only: \(error)")
            }
        } else {
            self.membershipCache = nil
            LogWarning("Could not access caches directory, using in-memory segment storage only")
        }
        
        // Load cached memberships will be done asynchronously when needed
        
        LogInfo("SegmentService initialized")
    }
    
    /// Initialize with custom configuration
    init(
        evaluationInterval: TimeInterval = 60,
        evaluationMode: EvaluationMode = .hybrid,
        cacheTTLSeconds: TimeInterval = 300
    ) {
        self.evaluationInterval = evaluationInterval
        self.evaluationMode = evaluationMode
        self.cacheTTLSeconds = cacheTTLSeconds
        
        // Set up AsyncStream
        var continuation: AsyncStream<SegmentEvaluationResult>.Continuation?
        self.segmentChanges = AsyncStream { cont in
            continuation = cont
        }
        self.segmentChangesContinuation = continuation
        
        // Try to initialize DiskCache for segment memberships (optional)
        if let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let cacheOptions = DiskCacheOptions(
                baseDirectory: cachesDirectory,
                subdirectory: "nuxie-segments",
                defaultTTL: nil,  // No TTL for segment memberships
                maxTotalBytes: 10 * 1024 * 1024,  // 10 MB cap
                excludeFromBackup: true,
                fileProtection: .completeUntilFirstUserAuthentication
            )
            
            do {
                self.membershipCache = try DiskCache<[String: SegmentMembership]>(options: cacheOptions)
                LogDebug("Segment disk cache initialized successfully")
            } catch {
                self.membershipCache = nil
                LogWarning("Failed to initialize segment disk cache, using in-memory only: \(error)")
            }
        } else {
            self.membershipCache = nil
            LogWarning("Could not access caches directory, using in-memory segment storage only")
        }
        
        // Load cached memberships will be done asynchronously when needed
        
        LogInfo("SegmentService initialized with custom config")
    }
    
    deinit {
        monitoringTask?.cancel()
        segmentChangesContinuation?.finish()
    }
    
    // MARK: - Public Methods - Segment Management
    
    /// Update segment definitions for a specific user
    public func updateSegments(_ segments: [Segment], for distinctId: String) async {
        self.segments = segments
        
        // Cache IR expressions for each segment
        irCache.removeAll()
        for segment in segments {
            // Use condition field which is now IREnvelope
            irCache[segment.id] = segment.condition.expr
        }
        
        LogInfo("Updated \(segments.count) segment definitions with IR expressions for user \(NuxieLogger.shared.logDistinctID(distinctId))")
        
        // Load cached memberships if not already loaded
        if memberships.isEmpty, let cache = membershipCache {
            let cacheKey = getCacheKey(for: distinctId)
            if let cached = await cache.retrieve(forKey: cacheKey) {
                self.memberships = cached
                LogDebug("Loaded \(cached.count) cached segment memberships")
            }
        }
        
        // Perform evaluation for the specified user
        _ = await performEvaluation(for: distinctId)
        
        // Start monitoring if not already running (ensures segments are re-evaluated periodically)
        if monitoringTask == nil {
            await startMonitoring()
        }
    }
    
    /// Handle user change (identity transition)
    public func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
        LogInfo("Handling user change from \(NuxieLogger.shared.logDistinctID(oldDistinctId)) to \(NuxieLogger.shared.logDistinctID(newDistinctId))")
        
        // Clear cached attributes for old user
        cachedAttributes = [:]
        attributesCacheTime = nil
        
        // Save old user's memberships if needed
        if !memberships.isEmpty, let cache = membershipCache {
            let oldCacheKey = getCacheKey(for: oldDistinctId)
            try? await cache.store(memberships, forKey: oldCacheKey)
        }
        
        // Load new user's cached memberships if available
        if let cache = membershipCache {
            let newCacheKey = getCacheKey(for: newDistinctId)
            if let cached = await cache.retrieve(forKey: newCacheKey) {
                self.memberships = cached
                LogDebug("Loaded \(cached.count) cached segment memberships for new user")
            } else {
                self.memberships = [:]
            }
        } else {
            self.memberships = [:]
        }
        
        // Evaluate segments for the new user if we have segment definitions
        if !segments.isEmpty {
            _ = await performEvaluation(for: newDistinctId)
            // Start monitoring for the new user
            await startMonitoring()
        }
    }
    
    // MARK: - Public Methods - Evaluation
    
    /// Manually trigger segment evaluation
    @discardableResult
    public func evaluateSegments() async -> SegmentEvaluationResult {
        let distinctId = identityService.getDistinctId()
        return await performEvaluation(for: distinctId)
    }
    
    // MARK: - Public Methods - Membership Queries
    
    /// Get current segment memberships
    public func getCurrentMemberships() async -> [SegmentMembership] {
        return Array(memberships.values)
    }
    
    /// Check if user is in a specific segment
    public func isInSegment(_ segmentId: String) async -> Bool {
        return memberships[segmentId] != nil
    }
    
    /// Is the current user a member of this segment? (alias for isInSegment)
    public func isMember(_ segmentId: String) async -> Bool {
        return memberships[segmentId] != nil
    }
    
    /// When did the user enter this segment?
    public func enteredAt(_ segmentId: String) async -> Date? {
        return memberships[segmentId]?.enteredAt
    }
    
    /// Get segments user recently entered
    public func getRecentlyEnteredSegments(since: Date) async -> [SegmentMembership] {
        return memberships.values.filter { $0.enteredAt >= since }
    }
    
    // MARK: - Public Methods - Monitoring
    
    /// Start automatic segment monitoring
    public func startMonitoring() async {
        stopMonitoring() // Stop any existing task
        
        monitoringTask = Task { [weak self] in
            guard let self = self else { return }
            LogInfo("Started segment monitoring (interval: \(self.evaluationInterval)s)")
            while !Task.isCancelled {
                do {
                    try await self.sleepProvider.sleep(for: self.evaluationInterval)
                    guard !Task.isCancelled else { break }
                    let distinctId = await self.identityService.getDistinctId()
                    _ = await self.performEvaluation(for: distinctId)
                } catch {
                    // Task was cancelled or sleep interrupted
                    break
                }
            }
            LogInfo("Segment monitoring stopped")
        }
    }
    
    /// Stop automatic segment monitoring
    public func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }
    
    /// Clear all segment data for a specific user
    public func clearSegments(for distinctId: String) async {
        memberships.removeAll()
        cachedAttributes.removeAll()
        attributesCacheTime = nil
        if let cache = membershipCache {
            let cacheKey = getCacheKey(for: distinctId)
            await cache.remove(forKey: cacheKey)
        }
        LogInfo("Cleared segment data for user \(NuxieLogger.shared.logDistinctID(distinctId))")
    }
    
    /// Clear all data (e.g., on user logout)
    public func clearData() async {
        cachedAttributes = [:]
        attributesCacheTime = nil
        segments = []
        memberships.removeAll()
        stopMonitoring()
        LogInfo("Cleared all segment data")
    }
    
    /// Clear just the memberships (keep segments and user)
    public func clearMemberships() async {
        memberships.removeAll()
        let distinctId = identityService.getDistinctId()
        await persistMemberships(for: distinctId)
        LogInfo("Cleared all segment memberships")
    }
    
    // MARK: - Private Methods - Evaluation
    
    private func performEvaluation(for distinctId: String) async -> SegmentEvaluationResult {
        
        // Get recent events for evaluation - filtered by user
        let events = await getRecentEvents(for: distinctId)
        
        // Update cached attributes if needed
        updateCachedAttributesIfNeeded(from: events)
        
        // Create evaluation context
        let context = EvaluationContext(
            distinctId: distinctId,
            attributes: cachedAttributes,
            events: events,
            currentDate: dateProvider.now()
        )
        
        var entered: [Segment] = []
        var exited: [Segment] = []
        var remained: [Segment] = []
        var newMemberships: [String: SegmentMembership] = [:]
        
        // Evaluate each segment
        for segment in segments {
            let qualifies = await evaluateSegmentCondition(segment, context: context)
            
            if qualifies {
                if let existingMembership = memberships[segment.id] {
                    // User remained in segment
                    remained.append(segment)
                    newMemberships[segment.id] = SegmentMembership(
                        segmentId: existingMembership.segmentId,
                        segmentName: existingMembership.segmentName,
                        enteredAt: existingMembership.enteredAt,
                        lastEvaluated: dateProvider.now()
                    )
                } else {
                    // User entered segment
                    entered.append(segment)
                    let now = dateProvider.now()
                    newMemberships[segment.id] = SegmentMembership(
                        segmentId: segment.id,
                        segmentName: segment.name,
                        enteredAt: now,
                        lastEvaluated: now
                    )
                    LogInfo("User entered segment: \(segment.name)")
                }
            } else if memberships[segment.id] != nil {
                // User exited segment
                exited.append(segment)
                LogInfo("User exited segment: \(segment.name)")
            }
        }
        
        // Update memberships
        memberships = newMemberships
        await persistMemberships(for: distinctId)
        
        let result = SegmentEvaluationResult(
            distinctId: distinctId,
            entered: entered,
            exited: exited,
            remained: remained
        )
        
        // Track and notify on changes
        if result.hasChanges {
            // Internal-only signals; do not persist as analytics events
            for segment in entered {
              LogDebug("Internal: segment_entered -> id=\(segment.id), name=\(segment.name)")
            }
            for segment in exited {
              LogDebug("Internal: segment_exited -> id=\(segment.id), name=\(segment.name)")
            }
            segmentChangesContinuation?.yield(result)
        }
        
        return result
    }
    
    private func evaluateSegmentCondition(_ segment: Segment, context: EvaluationContext) async -> Bool {
        // Use IR if available, otherwise return false
        guard let expr = irCache[segment.id] else {
            // Should not happen since we cache all segment conditions
            LogWarning("No IR expression cached for segment \(segment.name)")
            return false
        }
        
        // Create adapters for full IR context (matching JourneyService pattern)
        let userAdapter = IRUserPropsAdapter(identityService: identityService)
        let eventsAdapter = IREventQueriesAdapter(eventService: Container.shared.eventService())
        let segmentsAdapter = IRSegmentQueriesAdapter(segmentService: self)
        
        let cfg = IRRuntime.Config(
            now: context.currentDate,
            user: userAdapter,
            events: eventsAdapter,
            segments: segmentsAdapter
        )
        
        do {
            let interpreter = await irRuntime.makeInterpreter(cfg)
            return try await interpreter.evalBool(expr)
        } catch {
            LogError("IR evaluation failed for segment \(segment.name): \(error)")
            return false
        }
    }
    
    private func getRecentEvents(for distinctId: String) async -> [StoredEvent] {
        // Get events for specific user (not all users) with higher limit for better evaluation
        return await eventService.getEventsForUser(distinctId, limit: 1000)
    }
    
    private func persistMemberships(for distinctId: String) async {
        guard let cache = membershipCache else {
            LogDebug("No disk cache available for segment memberships")
            return
        }
        
        let cacheKey = getCacheKey(for: distinctId)
        do {
            try await cache.store(memberships, forKey: cacheKey)
            LogDebug("Persisted \(memberships.count) segment memberships to disk for user \(NuxieLogger.shared.logDistinctID(distinctId))")
        } catch {
            LogWarning("Failed to persist segment memberships to disk: \(error)")
        }
    }
    
    /// Generate cache key for a specific user
    private func getCacheKey(for distinctId: String) -> String {
        return "segments_\(distinctId)"
    }
        
    /// Update cached attributes from identify events
    private func updateCachedAttributesIfNeeded(from events: [StoredEvent]) {
        // Check if cache is still valid (5 minutes)
        if let cacheTime = attributesCacheTime,
           dateProvider.timeIntervalSince(cacheTime) < cacheTTLSeconds {
            return // Cache is still fresh
        }
        
        // Find the most recent identify event
        let identifyEvents = events.filter { $0.name == "identify" || $0.name == "user_attributes_updated" }
        guard let latestIdentifyEvent = identifyEvents.first else {
            return // No identify events found
        }
        
        // Extract attributes from the event properties
        do {
            let properties = try latestIdentifyEvent.getProperties()
            let propertiesDict = properties.mapValues { $0.value }
            if !propertiesDict.isEmpty {
                // Remove system properties, keep user attributes
                var attributes = propertiesDict
                attributes.removeValue(forKey: "$device_id")
                attributes.removeValue(forKey: "$os")
                attributes.removeValue(forKey: "$app_version")
                attributes.removeValue(forKey: "timestamp")
                
                self.cachedAttributes = attributes
                self.attributesCacheTime = dateProvider.now()
                LogDebug("Updated cached attributes from identify event")
            }
        } catch {
            LogError("Failed to decode event properties: \(error)")
        }
    }
}