import FactoryKit
import Foundation

// MARK: - StoreReadySignal (fileprivate)

/// Emits once when the event store has finished initializing; callers wait() before touching storage.
fileprivate actor StoreReadySignal {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func open() {
    guard !opened else { return }
    opened = true
    let toResume = waiters
    waiters.removeAll()
    toResume.forEach { $0.resume() }
  }

  func wait() async {
    if opened { return }
    await withCheckedContinuation { cont in
      waiters.append(cont)
    }
  }
}

// MARK: - Commands processed by the single worker
private enum Command {
  case track(TrackPayload)
  case flush(CheckedContinuation<Bool, Never>)
  case barrier(CheckedContinuation<Void, Never>)  // test-only: "drain until here"
  case shutdown
}

private struct TrackPayload {
  let name: String
  let properties: [String: Any]
  let forcedDistinctId: String  // snapshot at call site
}

/// Protocol for event routing operations
public protocol EventServiceProtocol {
  /// Configure the router with network queue, journey service, context builder and configuration
  /// - Parameters:
  ///   - networkQueue: Queue for remote event delivery
  ///   - journeyService: Service for journey evaluation
  ///   - contextBuilder: Context builder for event enrichment
  ///   - configuration: SDK configuration for sanitizers and hooks
  func configure(
    networkQueue: NuxieNetworkQueue?,
    journeyService: JourneyServiceProtocol?,
    contextBuilder: NuxieContextBuilder?,
    configuration: NuxieConfiguration?
  ) async throws

  func onAppDidEnterBackground() async
  func onAppBecameActive() async

  /// Track an event with optional user properties (main async entry point)
  /// - Parameters:
  ///   - event: Event name
  ///   - properties: Event properties
  ///   - userProperties: Properties to set on the user profile (mapped to $set)
  ///   - userPropertiesSetOnce: Properties to set once on the user profile (mapped to $set_once)
  func track(
    _ event: String,
    properties: [String: Any]?,
    userProperties: [String: Any]?,
    userPropertiesSetOnce: [String: Any]?
  )

  /// Track an event and return both the enriched event and server response
  /// Used for trigger flows that need gate plans and local evaluation
  /// - Parameters:
  ///   - event: Event name
  ///   - properties: Event properties
  ///   - userProperties: Properties to set on the user profile (mapped to $set)
  ///   - userPropertiesSetOnce: Properties to set once on the user profile (mapped to $set_once)
  /// - Returns: Tuple containing the enriched event and server response
  /// - Throws: NuxieError if tracking fails
  func trackForTrigger(
    _ event: String,
    properties: [String: Any]?,
    userProperties: [String: Any]?,
    userPropertiesSetOnce: [String: Any]?
  ) async throws -> (NuxieEvent, EventResponse)

  /// Track an event synchronously and wait for server response
  /// Used for journey lifecycle events that need server-side state
  /// - Parameters:
  ///   - event: Event name
  ///   - properties: Event properties
  /// - Returns: Server response with journey state and execution results
  /// - Throws: NuxieError if tracking fails
  func trackWithResponse(
    _ event: String,
    properties: [String: Any]?
  ) async throws -> EventResponse

  /// Reassign events from one user to another (for anonymous → identified transitions)
  /// - Parameters:
  ///   - fromUserId: Old user ID (typically anonymous)
  ///   - toUserId: New user ID (typically identified)
  /// - Returns: Number of events reassigned
  /// - Throws: EventStorageError if update fails
  func reassignEvents(from fromUserId: String, to toUserId: String) async throws -> Int

  // MARK: - Network Queue Management

  /// Manually flush the network queue
  /// - Returns: True if flush was initiated
  @discardableResult
  func flushEvents() async -> Bool

  /// Get current network queue size
  /// - Returns: Number of events queued for network delivery
  func getQueuedEventCount() async -> Int

  /// Pause event queue (stops network delivery)
  func pauseEventQueue() async

  /// Resume event queue (enables network delivery)
  func resumeEventQueue() async

  /// Close the event service and its underlying storage
  func close() async

  /// Wait until all previously enqueued commands are processed.
  /// Useful in tests for determinism and ensuring events are stored before querying.
  func drain() async

  // MARK: - Event History Access

  /// Get recent events for analysis
  /// - Parameter limit: Maximum events to return (default: 100)
  /// - Returns: Array of stored events
  func getRecentEvents(limit: Int) async -> [StoredEvent]

  /// Get events for a specific user
  /// - Parameters:
  ///   - distinctId: Distinct ID to filter by
  ///   - limit: Maximum events to return
  /// - Returns: Array of stored events for the user
  func getEventsForUser(_ distinctId: String, limit: Int) async -> [StoredEvent]

  /// Get events for a specific session
  /// - Parameter sessionId: Session ID to filter by
  /// - Returns: Array of events from the specified session
  func getEvents(for sessionId: String) async -> [StoredEvent]

  // MARK: - Event Query Methods

  /// Check if a specific event exists for a user
  /// - Parameters:
  ///   - name: Event name to search for
  ///   - distinctId: User ID to filter by
  ///   - since: Optional date to filter events after
  /// - Returns: True if event exists, false otherwise
  func hasEvent(name: String, distinctId: String, since: Date?) async -> Bool

  /// Count events of a specific type for a user
  /// - Parameters:
  ///   - name: Event name to count
  ///   - distinctId: User ID to filter by
  ///   - since: Optional start date (inclusive)
  ///   - until: Optional end date (inclusive)
  /// - Returns: Number of matching events
  func countEvents(name: String, distinctId: String, since: Date?, until: Date?) async -> Int

  /// Get the timestamp of the last occurrence of an event
  /// - Parameters:
  ///   - name: Event name to search for
  ///   - distinctId: User ID to filter by
  ///   - since: Optional start date (inclusive)
  ///   - until: Optional end date (inclusive)
  /// - Returns: Date of last event, or nil if no event found
  func getLastEventTime(name: String, distinctId: String, since: Date?, until: Date?) async -> Date?

  // MARK: - IR Evaluation Support

  /// Check if event exists
  func exists(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Bool

  /// Count events
  func count(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Int

  /// Get first time event occurred
  func firstTime(name: String, where predicate: IRPredicate?) async -> Date?

  /// Get last time event occurred
  func lastTime(name: String, where predicate: IRPredicate?) async -> Date?

  /// Aggregate event property values
  func aggregate(
    _ agg: Aggregate, name: String, prop: String, since: Date?, until: Date?,
    where predicate: IRPredicate?
  ) async -> Double?

  /// Check if events occurred in order
  func inOrder(
    steps: [StepQuery], overallWithin: TimeInterval?, perStepWithin: TimeInterval?, since: Date?,
    until: Date?
  ) async -> Bool

  /// Check if user was active in periods
  func activePeriods(
    name: String, period: Period, total: Int, min: Int, where predicate: IRPredicate?
  ) async -> Bool

  /// Check if user stopped performing event
  func stopped(name: String, inactiveFor: TimeInterval, where predicate: IRPredicate?) async -> Bool

  /// Check if user restarted performing event
  func restarted(
    name: String, inactiveFor: TimeInterval, within: TimeInterval, where predicate: IRPredicate?
  ) async -> Bool
}

/// Dual-purpose event service that handles local storage and network queuing
public class EventService: EventServiceProtocol {

  private let eventStore: EventStoreProtocol
  private let ready = StoreReadySignal()

  // the pipeline
  private let stream: AsyncStream<Command>
  private let continuation: AsyncStream<Command>.Continuation
  private var worker: Task<Void, Never>?

  internal init(eventStore: EventStoreProtocol? = nil) {
    self.eventStore = eventStore ?? EventStore()
    // Create the channel immediately so calls before configure() are buffered.
    var cont: AsyncStream<Command>.Continuation!
    self.stream = AsyncStream { c in cont = c }
    self.continuation = cont
    startWorker()
  }

  // MARK: - Dependencies

  @Injected(\.identityService) private var identityService: IdentityServiceProtocol
  @Injected(\.sessionService) private var sessionService: SessionServiceProtocol
  @Injected(\.dateProvider) private var dateProvider: DateProviderProtocol
  @Injected(\.nuxieApi) private var apiClient: NuxieApiProtocol

  private var networkQueue: NuxieNetworkQueue?
  // Weak to avoid retain cycle with JourneyService (which @Injects EventService)
  private weak var journeyService: JourneyServiceProtocol?
  private var contextBuilder: NuxieContextBuilder?
  private var configuration: NuxieConfiguration?

  // MARK: - Configuration

  /// Configure the service with network queue, journey service, context builder and configuration
  /// - Parameters:
  ///   - networkQueue: Queue for remote event delivery
  ///   - journeyService: Service for journey evaluation
  ///   - contextBuilder: Context builder for event enrichment
  ///   - configuration: SDK configuration for sanitizers and hooks
  public func configure(
    networkQueue: NuxieNetworkQueue?,
    journeyService: JourneyServiceProtocol? = nil,
    contextBuilder: NuxieContextBuilder? = nil,
    configuration: NuxieConfiguration? = nil
  ) async throws {
    self.networkQueue = networkQueue
    self.journeyService = journeyService
    self.contextBuilder = contextBuilder
    self.configuration = configuration
    try await eventStore.initialize(path: configuration?.customStoragePath)

    LogInfo(
      "EventService configured with network queue: \(networkQueue != nil), journey service: \(journeyService != nil), context builder: \(contextBuilder != nil)"
    )
    // Signal that storage is initialized and safe to use
    await ready.open()
  }

  public func onAppDidEnterBackground() async {
    await pauseEventQueue()
  }

  public func onAppBecameActive() async {
    await resumeEventQueue()
    _ = await flushEvents()  // optional; may jitter
  }

  // MARK: - Public Track Method

  /// Track an event with optional user properties (main entry point with enrichment)
  /// - Parameters:
  ///   - event: Event name
  ///   - properties: Event properties
  ///   - userProperties: Properties to set on the user profile (mapped to $set)
  ///   - userPropertiesSetOnce: Properties to set once on the user profile (mapped to $set_once)
  public func track(
    _ event: String,
    properties: [String: Any]? = nil,
    userProperties: [String: Any]? = nil,
    userPropertiesSetOnce: [String: Any]? = nil
  ) {
    guard !event.isEmpty else {
      LogWarning("Event name cannot be empty")
      return
    }

    // Build lightweight custom payload. Full enrichment happens in the worker.
    var custom = properties ?? [:]
    if let userProperties { custom["$set"] = userProperties }
    if let userPropertiesSetOnce { custom["$set_once"] = userPropertiesSetOnce }

    // Snapshot id NOW to preserve pre/post identify semantics.
    let idSnapshot = identityService.getDistinctId()

    continuation.yield(
      .track(
        .init(
          name: event,
          properties: custom,
          forcedDistinctId: idSnapshot
        )))
  }

  /// Track an event synchronously and wait for server response
  /// Used for journey lifecycle events that need server-side state
  /// - Parameters:
  ///   - event: Event name
  ///   - properties: Event properties
  /// - Returns: Server response with journey state and execution results
  /// - Throws: NuxieError if tracking fails
  public func trackWithResponse(
    _ event: String,
    properties: [String: Any]? = nil
  ) async throws -> EventResponse {
    guard !event.isEmpty else {
      throw NuxieError.invalidConfiguration("Event name cannot be empty")
    }

    // Wait for initialization
    await ready.wait()

    // Flush pending events first to ensure ordering
    // (any queued events should reach the server before this synchronous one)
    _ = await flushEvents()

    // Get current distinct ID
    let distinctId = identityService.getDistinctId()

    // Build enriched properties
    var finalProperties = properties ?? [:]

    // Add session ID if not present
    if finalProperties["$session_id"] == nil {
      if let sessionId = sessionService.getSessionId(at: Date(), readOnly: false) {
        finalProperties["$session_id"] = sessionId
        sessionService.touchSession()
      }
    }

    // Apply enrichment
    finalProperties = enrich(finalProperties)

    // Store event locally (for history)
    do {
      try await eventStore.storeEvent(
        name: event,
        properties: finalProperties,
        distinctId: distinctId
      )
    } catch {
      LogWarning("Failed to store event locally: \(error)")
      // Continue - server tracking is more important for journey events
    }

    // Send directly to API and return response
    return try await apiClient.trackEvent(
      event: event,
      distinctId: distinctId,
      properties: finalProperties,
      value: finalProperties["value"] as? Double,
      entityId: finalProperties["entityId"] as? String
    )
  }

  /// Track an event and return the enriched event plus server response
  public func trackForTrigger(
    _ event: String,
    properties: [String: Any]? = nil,
    userProperties: [String: Any]? = nil,
    userPropertiesSetOnce: [String: Any]? = nil
  ) async throws -> (NuxieEvent, EventResponse) {
    guard !event.isEmpty else {
      throw NuxieError.invalidConfiguration("Event name cannot be empty")
    }

    await ready.wait()

    _ = await flushEvents()

    let distinctId = identityService.getDistinctId()

    var finalProperties = properties ?? [:]
    if let userProperties { finalProperties["$set"] = userProperties }
    if let userPropertiesSetOnce { finalProperties["$set_once"] = userPropertiesSetOnce }

    if finalProperties["$session_id"] == nil {
      if let sessionId = sessionService.getSessionId(at: Date(), readOnly: false) {
        finalProperties["$session_id"] = sessionId
        sessionService.touchSession()
      }
    }

    finalProperties = enrich(finalProperties)

    do {
      try await eventStore.storeEvent(
        name: event,
        properties: finalProperties,
        distinctId: distinctId
      )
    } catch {
      LogWarning("Failed to store event locally: \(error)")
    }

    let response = try await apiClient.trackEvent(
      event: event,
      distinctId: distinctId,
      properties: finalProperties,
      value: finalProperties["value"] as? Double,
      entityId: finalProperties["entityId"] as? String
    )

    let eventId = response.event?.id ?? UUID.v7().uuidString
    let enrichedEvent = NuxieEvent(
      id: eventId,
      name: event,
      distinctId: distinctId,
      properties: finalProperties
    )

    return (enrichedEvent, response)
  }

  /// Reassign events from one user to another (for anonymous → identified transitions)
  /// - Parameters:
  ///   - fromUserId: Old user ID (typically anonymous)
  ///   - toUserId: New user ID (typically identified)
  /// - Returns: Number of events reassigned
  /// - Throws: EventStorageError if update fails
  public func reassignEvents(from fromUserId: String, to toUserId: String) async throws -> Int {
    await ready.wait()
    return try await eventStore.reassignEvents(from: fromUserId, to: toUserId)
  }

  /// Close the event service and its underlying storage
  public func close() async {
    continuation.yield(.shutdown)
    await eventStore.close()
    LogInfo("EventService closed")
  }

  // MARK: - Internal Event Routing

  /// Route an event to appropriate destinations (storage and/or network)
  /// - Parameter event: Event to route
  /// - Returns: Routed event, or nil if routing failed
  @discardableResult
  private func route(_ event: NuxieEvent) async -> NuxieEvent? {
    // Ensure the store is initialized before touching it
    await ready.wait()

    // 1) Always persist & drive business logic
    extractUserProperties(from: event)
    do {
      LogDebug("Attempting to store event: \(event.name) for user: \(event.distinctId)")
      try await eventStore.storeEvent(
        name: event.name,
        properties: event.properties,
        distinctId: event.distinctId
      )
      LogDebug("Successfully stored event: \(event.name)")
    } catch {
      LogError("Failed to store event locally: \(error)")
      // Continue routing to other services even if storage fails
    }

    await journeyService?.handleEvent(event)

    // 2) Network ordering: preserve $identify-first ordering during identity transitions
    await networkQueue?.enqueue(event)

    return event
  }

  // MARK: - Private Routing Implementation

  /// Extract and update user properties from event
  /// - Parameter event: Event to extract properties from
  private func extractUserProperties(from event: NuxieEvent) {
    // Check for $set properties (overwrites existing)
    if let setProperties = event.properties["$set"] as? [String: Any] {
      identityService.setUserProperties(setProperties)
      LogDebug("Updated \(setProperties.count) user properties from $set")
    }

    // Check for $set_once properties (only sets if not present)
    if let setOnceProperties = event.properties["$set_once"] as? [String: Any] {
      identityService.setOnceUserProperties(setOnceProperties)
      LogDebug("Updated user properties from $set_once")
    }
  }

  // MARK: - Network Queue Management

  /// Manually flush the network queue
  /// - Returns: True if flush was initiated
  @discardableResult
  public func flushEvents() async -> Bool {
    await withCheckedContinuation { cont in
      continuation.yield(.flush(cont))
    }
  }

  /// Get current network queue size
  /// - Returns: Number of events queued for network delivery
  public func getQueuedEventCount() async -> Int {
    await networkQueue?.getQueueSize() ?? 0
  }

  /// Pause event queue (stops network delivery)
  public func pauseEventQueue() async {
    await networkQueue?.pause()
  }

  /// Resume event queue (enables network delivery)
  public func resumeEventQueue() async {
    await networkQueue?.resume()
  }

  // MARK: - Worker

  private func startWorker() {
    worker = Task {
      for await cmd in stream {
        switch cmd {
        case .track(let payload):
          await handleTrack(payload)

        case .flush(let cont):
          let ok = await networkQueue?.flush() ?? false
          cont.resume(returning: ok)

        case .barrier(let cont):
          // All prior commands are processed when we reach here
          cont.resume()

        case .shutdown:
          LogDebug("[Worker] shutdown received")
          return
        }
      }
    }
  }

  // MARK: - Worker handlers

  private func handleTrack(_ p: TrackPayload) async {
    // Stage 1: Add session ID if not already present
    var propertiesWithSession = p.properties
    if propertiesWithSession["$session_id"] == nil {
      // Get or create session ID and add to properties
      if let sessionId = sessionService.getSessionId(at: Date(), readOnly: false) {
        propertiesWithSession["$session_id"] = sessionId
        // Touch session to update activity
        sessionService.touchSession()
      }
    }

    let finalProperties = enrich(propertiesWithSession)

    let nuxieEvent = NuxieEvent(
      name: p.name,
      distinctId: p.forcedDistinctId,
      properties: finalProperties
    )

    // Stage 2: Apply beforeSend hook if configured
    let finalEvent: NuxieEvent
    if let beforeSend = configuration?.beforeSend {
      guard let transformedEvent = beforeSend(nuxieEvent) else {
        LogDebug("Event '\(nuxieEvent.name)' dropped by beforeSend hook")
        return
      }
      finalEvent = transformedEvent
    } else {
      finalEvent = nuxieEvent
    }

    // Stage 8: Route Event (handles storage/network/journeys)
    await route(finalEvent)
  }

  // MARK: - Worker helpers

  private func enrich(_ custom: [String: Any]) -> [String: Any] {
    let sanitized = EventSanitizer.sanitizeDataTypes(custom)
    let withContext: [String: Any]
    if let contextBuilder {
      withContext = contextBuilder.buildEnrichedProperties(customProperties: sanitized)
    } else {
      withContext = sanitized
    }
    return EventSanitizer.sanitizeProperties(
      withContext, customSanitizer: configuration?.propertiesSanitizer)
  }

  // MARK: - Test helper (optional)

  /// Wait until all previously enqueued commands are processed.
  /// Useful in tests for determinism and ensuring events are stored before querying.
  public func drain() async {
    await withCheckedContinuation { cont in
      continuation.yield(.barrier(cont))
    }
  }

  // MARK: - Event History Access

  /// Get recent events for analysis
  /// - Parameter limit: Maximum events to return (default: 100)
  /// - Returns: Array of stored events
  public func getRecentEvents(limit: Int = 100) async -> [StoredEvent] {
    await ready.wait()
    do {
      return try await eventStore.getRecentEvents(limit: limit)
    } catch {
      LogError("Failed to get recent events: \(error)")
      return []
    }
  }

  /// Get events for a specific user
  /// - Parameters:
  ///   - distinctId: Distinct ID to filter by
  ///   - limit: Maximum events to return
  /// - Returns: Array of stored events for the user
  public func getEventsForUser(_ distinctId: String, limit: Int = 100) async -> [StoredEvent] {
    await ready.wait()
    do {
      return try await eventStore.getEventsForUser(distinctId, limit: limit)
    } catch {
      LogError("Failed to get events for user \(distinctId): \(error)")
      return []
    }
  }

  /// Get events for a specific session
  /// - Parameter sessionId: Session ID to filter by
  /// - Returns: Array of events from the specified session
  public func getEvents(for sessionId: String) async -> [StoredEvent] {
    await ready.wait()
    do {
      return try await eventStore.getEvents(for: sessionId)
    } catch {
      LogError("Failed to get session events: \(error)")
      return []
    }
  }

  // MARK: - Event Query Methods

  /// Check if a specific event exists for a user
  /// - Parameters:
  ///   - name: Event name to search for
  ///   - distinctId: User ID to filter by
  ///   - since: Optional date to filter events after
  /// - Returns: True if event exists, false otherwise
  public func hasEvent(name: String, distinctId: String, since: Date? = nil) async -> Bool {
    await ready.wait()
    do {
      return try await eventStore.hasEvent(name: name, distinctId: distinctId, since: since)
    } catch {
      LogError("Failed to check event existence: \(error)")
      return false
    }
  }

  /// Count events of a specific type for a user
  /// - Parameters:
  ///   - name: Event name to count
  ///   - distinctId: User ID to filter by
  ///   - since: Optional start date (inclusive)
  ///   - until: Optional end date (inclusive)
  /// - Returns: Number of matching events
  public func countEvents(name: String, distinctId: String, since: Date? = nil, until: Date? = nil)
    async -> Int
  {
    await ready.wait()
    do {
      return try await eventStore.countEvents(
        name: name, distinctId: distinctId, since: since, until: until)
    } catch {
      LogError("Failed to count events: \(error)")
      return 0
    }
  }

  /// Get the timestamp of the last occurrence of an event
  /// - Parameters:
  ///   - name: Event name to search for
  ///   - distinctId: User ID to filter by
  ///   - since: Optional start date (inclusive)
  ///   - until: Optional end date (inclusive)
  /// - Returns: Date of last event, or nil if no event found
  public func getLastEventTime(
    name: String, distinctId: String, since: Date? = nil, until: Date? = nil
  ) async -> Date? {
    await ready.wait()
    do {
      return try await eventStore.getLastEventTime(
        name: name, distinctId: distinctId, since: since, until: until)
    } catch {
      LogError("Failed to get last event time: \(error)")
      return nil
    }
  }

  // MARK: - IREvents Protocol Implementation

  public func exists(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async
    -> Bool
  {
    return await count(name: name, since: since, until: until, where: predicate) > 0
  }

  public func count(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async
    -> Int
  {
    let distinctId = identityService.getDistinctId()
    let events = await getEventsForUser(distinctId, limit: 1000)

    return events.lazy
      .filter { $0.name == name }
      .filter { event in
        if let s = since, event.timestamp < s { return false }
        if let u = until, event.timestamp > u { return false }
        return true
      }
      .filter { event in
        guard let p = predicate else { return true }
        let props = event.getPropertiesDict()
        return PredicateEval.eval(p, props: props)
      }
      .count
  }

  public func firstTime(name: String, where predicate: IRPredicate?) async -> Date? {
    let distinctId = identityService.getDistinctId()
    let events = await getEventsForUser(distinctId, limit: 5000)

    let filtered =
      events
      .filter { $0.name == name }
      .filter { event in
        guard let p = predicate else { return true }
        let props = event.getPropertiesDict()
        return PredicateEval.eval(p, props: props)
      }
      .sorted(by: { $0.timestamp < $1.timestamp })

    return filtered.first?.timestamp
  }

  public func lastTime(name: String, where predicate: IRPredicate?) async -> Date? {
    let distinctId = identityService.getDistinctId()
    let events = await getEventsForUser(distinctId, limit: 5000)

    let filtered =
      events
      .filter { $0.name == name }
      .filter { event in
        guard let p = predicate else { return true }
        let props = event.getPropertiesDict()
        return PredicateEval.eval(p, props: props)
      }
      .sorted(by: { $0.timestamp > $1.timestamp })

    return filtered.first?.timestamp
  }

  public func aggregate(
    _ agg: Aggregate, name: String, prop: String, since: Date?, until: Date?,
    where predicate: IRPredicate?
  ) async -> Double? {
    let distinctId = identityService.getDistinctId()
    let events = await getEventsForUser(distinctId, limit: 5000)

    let values: [Double] =
      events
      .filter { $0.name == name }
      .filter { event in
        if let s = since, event.timestamp < s { return false }
        if let u = until, event.timestamp > u { return false }
        return true
      }
      .compactMap { event -> Double? in
        let props = event.getPropertiesDict()
        guard predicate.map({ PredicateEval.eval($0, props: props) }) ?? true else { return nil }
        return Coercion.asNumber(props[prop])
      }

    guard !values.isEmpty else { return nil }

    switch agg {
    case .sum:
      return values.reduce(0, +)
    case .avg:
      return values.reduce(0, +) / Double(values.count)
    case .min:
      return values.min()
    case .max:
      return values.max()
    case .unique:
      return Double(Set(values).count)
    }
  }

  public func inOrder(
    steps: [StepQuery], overallWithin: TimeInterval?, perStepWithin: TimeInterval?, since: Date?,
    until: Date?
  ) async -> Bool {
    let distinctId = identityService.getDistinctId()
    let events = await getEventsForUser(distinctId, limit: 5000)
      .filter { event in
        if let s = since, event.timestamp < s { return false }
        if let u = until, event.timestamp > u { return false }
        return true
      }
      .sorted(by: { $0.timestamp < $1.timestamp })

    var lastTime: Date? = nil
    let startRef = events.first?.timestamp

    for step in steps {
      guard
        let match = events.first(where: { event in
          guard event.timestamp >= (lastTime ?? since ?? Date.distantPast) else { return false }
          if event.name != step.name { return false }
          if let p = step.predicate {
            let props = event.getPropertiesDict()
            if !PredicateEval.eval(p, props: props) { return false }
          }
          if let per = perStepWithin, let lt = lastTime {
            if event.timestamp.timeIntervalSince(lt) > per { return false }
          }
          if let ov = overallWithin, let start = startRef {
            if event.timestamp.timeIntervalSince(start) > ov { return false }
          }
          return true
        })
      else {
        return false
      }
      lastTime = match.timestamp
    }

    return true
  }

  public func activePeriods(
    name: String, period: Period, total: Int, min: Int, where predicate: IRPredicate?
  ) async -> Bool {
    let distinctId = identityService.getDistinctId()
    let events = await getEventsForUser(distinctId, limit: 10000).filter { $0.name == name }
    guard total > 0 && min > 0 else { return false }

    // Calendar-bucket by UTC
    let cal = Calendar(identifier: .gregorian)
    let now = dateProvider.now()

    // Calculate the time window - the last 'total' periods from now
    let windowStart: Date
    switch period {
    case .day:
      windowStart = cal.date(byAdding: .day, value: -total, to: now) ?? now
    case .week:
      windowStart = cal.date(byAdding: .weekOfYear, value: -total, to: now) ?? now
    case .month:
      windowStart = cal.date(byAdding: .month, value: -total, to: now) ?? now
    case .year:
      windowStart = cal.date(byAdding: .year, value: -total, to: now) ?? now
    }

    // Count unique periods with activity within the time window
    var bucketsInWindow = Set<DateComponents>()

    for event in events {
      // Only consider events within the time window
      guard event.timestamp >= windowStart else { continue }

      let props = event.getPropertiesDict()
      if let p = predicate, !PredicateEval.eval(p, props: props) { continue }

      let comps: DateComponents
      switch period {
      case .day:
        comps = cal.dateComponents([.year, .month, .day], from: event.timestamp)
      case .week:
        comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: event.timestamp)
      case .month:
        comps = cal.dateComponents([.year, .month], from: event.timestamp)
      case .year:
        comps = cal.dateComponents([.year], from: event.timestamp)
      }
      bucketsInWindow.insert(comps)
    }

    // Return true if user was active in at least 'min' periods out of the last 'total' periods
    return bucketsInWindow.count >= min
  }

  public func stopped(name: String, inactiveFor: TimeInterval, where predicate: IRPredicate?) async
    -> Bool
  {
    guard let last = await lastTime(name: name, where: predicate) else { return false }
    return Date().timeIntervalSince(last) >= inactiveFor
  }

  public func restarted(
    name: String, inactiveFor: TimeInterval, within: TimeInterval, where predicate: IRPredicate?
  ) async -> Bool {
    let distinctId = identityService.getDistinctId()
    let now = Date()
    let events = await getEventsForUser(distinctId, limit: 5000)
      .filter { $0.name == name }
      .sorted(by: { $0.timestamp < $1.timestamp })

    // Find any gap
    var prev: Date? = nil
    var hadGap = false

    for event in events {
      if let p = predicate {
        let props = event.getPropertiesDict()
        if !PredicateEval.eval(p, props: props) { continue }
      }
      if let pv = prev, event.timestamp.timeIntervalSince(pv) >= inactiveFor {
        hadGap = true
      }
      prev = event.timestamp
    }

    guard hadGap else { return false }

    // Check for recent activity
    return events.contains { event in
      now.timeIntervalSince(event.timestamp) <= within
    }
  }

}
