import Foundation

/// Network queue for efficient event batching and delivery
public actor NuxieNetworkQueue {
    
    // MARK: - Configuration
    
    /// Number of events to trigger automatic flush
    private let flushAt: Int
    
    /// Time interval to trigger automatic flush (seconds)
    private let flushIntervalSeconds: TimeInterval
    
    /// Maximum events to keep in queue (oldest dropped when exceeded)
    private let maxQueueSize: Int
    
    /// Maximum events per batch when flushing
    private let maxBatchSize: Int
    
    /// Maximum retry attempts for failed requests
    private let maxRetries: Int
    
    /// Base retry delay (exponential backoff)
    private let baseRetryDelay: TimeInterval
    
    // MARK: - State
    
    /// In-memory event queue (FIFO)
    private var eventQueue: [NuxieEvent] = []
    
    /// Task for periodic flush
    private var flushTask: Task<Void, Never>?
    
    /// Current flush operation (prevents concurrent flushes)
    private var isCurrentlyFlushing = false
    
    /// Retry state tracking
    private var retryCount = 0
    private var nextRetryDate: Date?
    
    /// Pause state (for offline/error conditions)
    private var isPaused = false
    
    /// API client for network requests
    private weak var apiClient: NuxieApiProtocol?
    
    // MARK: - Initialization
    
    /// Initialize network queue with configuration
    /// - Parameters:
    ///   - flushAt: Number of events to trigger flush (default: 20)
    ///   - flushIntervalSeconds: Time interval to trigger flush (default: 30)
    ///   - maxQueueSize: Maximum queue size (default: 1000)
    ///   - maxBatchSize: Maximum batch size (default: 50)
    ///   - maxRetries: Maximum retry attempts (default: 3)
    ///   - baseRetryDelay: Base retry delay in seconds (default: 5)
    ///   - apiClient: API client for network requests
    public init(
        flushAt: Int = 20,
        flushIntervalSeconds: TimeInterval = 30,
        maxQueueSize: Int = 1000,
        maxBatchSize: Int = 50,
        maxRetries: Int = 3,
        baseRetryDelay: TimeInterval = 5,
        apiClient: NuxieApiProtocol?
    ) {
        self.flushAt = flushAt
        self.flushIntervalSeconds = flushIntervalSeconds
        self.maxQueueSize = maxQueueSize
        self.maxBatchSize = maxBatchSize
        self.maxRetries = maxRetries
        self.baseRetryDelay = baseRetryDelay
        self.apiClient = apiClient
        
        // Only start timer if not in test environment
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            startFlushTask()
        }
        LogInfo("NuxieNetworkQueue initialized (flushAt: \(flushAt), interval: \(flushIntervalSeconds)s)")
    }
    
    deinit {
        flushTask?.cancel()
    }
    
    // MARK: - Public Interface
    
    /// Stop all timers and clean up resources
    public func shutdown() {
        flushTask?.cancel()
        flushTask = nil
        LogDebug("NuxieNetworkQueue shutdown")
    }
    
    /// Enqueue an event for network delivery
    /// - Parameter event: Event to enqueue
    public func enqueue(_ event: NuxieEvent) {
        // Check if queue is full
        if eventQueue.count >= maxQueueSize {
            // Drop oldest event (FIFO)
            let dropped = eventQueue.removeFirst()
            LogWarning("Queue full, dropped oldest event: \(dropped.name)")
        }
        
        // Add new event
        eventQueue.append(event)
        LogDebug("Enqueued event: \(event.name) (queue size: \(eventQueue.count))")
        
        // Check if we should flush
        Task {
            await flushIfOverThreshold()
        }
    }
    
    /// Manually trigger a flush
    /// Force-sends events even when paused (pause only affects automatic sending)
    /// - Returns: True if flush was initiated, false if already flushing or queue is empty
    @discardableResult
    public func flush() async -> Bool {
        return await performFlush(forceSend: true)
    }
    
    /// Get current queue size
    /// - Returns: Number of events in queue
    public func getQueueSize() -> Int {
        return eventQueue.count
    }
    
    /// Pause the queue (stops automatic flushing)
    public func pause() {
        isPaused = true
        LogInfo("Network queue paused")
    }
    
    /// Resume the queue (enables automatic flushing)
    public func resume() async {
        isPaused = false
        retryCount = 0
        nextRetryDate = nil
        LogInfo("Network queue resumed")
        
        // Trigger flush if we have events
        await flushIfOverThreshold()
    }
    
    /// Clear all events from queue
    public func clear() {
        let count = eventQueue.count
        eventQueue.removeAll()
        LogInfo("Cleared \(count) events from queue")
    }
    
    // MARK: - Private Implementation
    
    /// Check if queue should flush and trigger if needed
    private func flushIfOverThreshold() async {
        guard !isPaused, !isCurrentlyFlushing else { return }
        
        // Check retry backoff
        if let nextRetry = nextRetryDate, Date() < nextRetry {
            return // Still in backoff period
        }
        
        // Check if we should flush
        if eventQueue.count >= flushAt {
            LogDebug("Queue threshold reached (\(eventQueue.count) >= \(flushAt)), triggering flush")
            _ = await performFlush()
        }
    }
    
    /// Perform the actual flush operation
    /// - Parameter forceSend: If true, bypass pause state (for manual flush)
    /// - Returns: True if flush was initiated
    private func performFlush(forceSend: Bool = false) async -> Bool {
        // Check conditions: 
        // - If forceSend is true, ignore pause state
        // - Always respect isCurrentlyFlushing and empty queue checks
        let shouldCheckPause = !forceSend
        guard (!shouldCheckPause || !isPaused), !isCurrentlyFlushing, !eventQueue.isEmpty else {
            return false
        }
        
        // Check retry backoff
        if let nextRetry = nextRetryDate, Date() < nextRetry {
            LogDebug("Still in retry backoff, skipping flush")
            return false
        }
        
        guard let apiClient = apiClient else {
            LogWarning("[performFlush] No API client available for flush")
            return false
        }
        
        // Mark as flushing
        isCurrentlyFlushing = true
        LogDebug("[performFlush] Set isCurrentlyFlushing = true")
        
        // Get batch to send (up to maxBatchSize events)
        let batchSize = min(eventQueue.count, maxBatchSize)
        let batch = Array(eventQueue.prefix(batchSize))
        
        LogInfo("[performFlush] Flushing \(batch.count) events to server (maxBatchSize: \(maxBatchSize))")
        LogDebug("[performFlush] API client type: \(type(of: apiClient))")
        
        // Convert events to batch items
        LogDebug("[performFlush] Converting \(batch.count) events to batch items...")
        let batchItems = batch.map { event -> BatchEventItem in
            LogDebug("[performFlush] Converting event: \(event.name) for user: \(event.distinctId)")
            return BatchEventItem(
                event: event.name,
                distinctId: event.distinctId,
                anonDistinctId: event.properties["$anon_distinct_id"] as? String,
                timestamp: event.timestamp,
                properties: event.properties,
                idempotencyKey: event.properties["idempotency_key"] as? String,
                value: event.properties["value"] as? Double,
                entityId: event.properties["entityId"] as? String
            )
        }
        
        LogDebug("[performFlush] Created \(batchItems.count) batch items, calling apiClient.sendBatch...")
        
        // Send batch asynchronously using the batch endpoint
        do {
            let response = try await apiClient.sendBatch(events: batchItems)
            LogDebug("[performFlush] Batch sendBatch completed")
            LogDebug("Batch response: processed=\(response.processed), failed=\(response.failed)")
            if response.failed == 0 {
                await handleBatchSuccess(batch)
            } else {
                // Some events failed, handle as partial failure
                await handleBatchPartialSuccess(batch, response: response)
            }
        } catch {
            await handleBatchFailure(batch, error: error)
        }
        
        return true
    }
    
    
    /// Handle successful batch delivery
    /// - Parameter batch: Successfully delivered events
    private func handleBatchSuccess(_ batch: [NuxieEvent]) async {
        // Remove delivered events from queue
        let batchIds = Set(batch.map { $0.id })
        eventQueue.removeAll { batchIds.contains($0.id) }
        
        // Reset retry state
        retryCount = 0
        nextRetryDate = nil
        
        // Mark as not flushing
        isCurrentlyFlushing = false
        
        LogInfo("Successfully delivered \(batch.count) events (queue size: \(eventQueue.count))")
        
        // Check if we should flush again
        await flushIfOverThreshold()
    }
    
    /// Handle partial batch success (some events failed)
    /// - Parameters:
    ///   - batch: Original batch of events
    ///   - response: Batch response with error details
    private func handleBatchPartialSuccess(_ batch: [NuxieEvent], response: BatchResponse) async {
        // Remove only successfully processed events
        // Since we don't have per-event status, we'll assume all were processed if failed < total
        let batchIds = Set(batch.map { $0.id })
        eventQueue.removeAll { batchIds.contains($0.id) }
        
        // Mark as not flushing
        isCurrentlyFlushing = false
        
        LogWarning("Partially delivered batch: \(response.processed) processed, \(response.failed) failed")
        
        if let errors = response.errors {
            for error in errors {
                LogDebug("Event error at index \(error.index): \(error.event) - \(error.error)")
            }
        }
        
        // Check if we should flush again
        await flushIfOverThreshold()
    }
    
    /// Handle failed batch delivery
    /// - Parameters:
    ///   - batch: Failed events
    ///   - error: Delivery error
    private func handleBatchFailure(_ batch: [NuxieEvent], error: Error) async {
        isCurrentlyFlushing = false
        
        // Check if this is a permanent failure (4xx errors)
        if let urlError = error as? URLError {
            if urlError.code.rawValue >= 400 && urlError.code.rawValue < 500 {
                // Permanent failure - drop events
                let batchIds = Set(batch.map { $0.id })
                eventQueue.removeAll { batchIds.contains($0.id) }
                LogWarning("Permanent failure (4xx), dropped \(batch.count) events: \(error)")
                return
            }
        }
        
        // Temporary failure - implement retry with exponential backoff
        retryCount += 1
        
        if retryCount <= maxRetries {
            // Calculate backoff delay: baseDelay * 2^(retryCount-1)
            let backoffDelay = baseRetryDelay * pow(2, Double(retryCount - 1))
            nextRetryDate = Date().addingTimeInterval(backoffDelay)
            
            LogWarning("Batch delivery failed (attempt \(retryCount)/\(maxRetries)), retrying in \(backoffDelay)s: \(error)")
        } else {
            // Max retries exceeded - drop events
            let batchIds = Set(batch.map { $0.id })
            eventQueue.removeAll { batchIds.contains($0.id) }
            
            // Reset retry state
            retryCount = 0
            nextRetryDate = nil
            
            LogError("Max retries exceeded, dropped \(batch.count) events: \(error)")
        }
    }
    
    // MARK: - Task Management
    
    /// Start the periodic flush task
    private func startFlushTask() {
        flushTask?.cancel() // Ensure no existing task
        
        flushTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(flushIntervalSeconds * 1_000_000_000))
                
                if !Task.isCancelled {
                    await handleTimerFlush()
                }
            }
        }
    }
    
    /// Handle timer-triggered flush
    private func handleTimerFlush() async {
        if !eventQueue.isEmpty {
            LogDebug("Timer flush triggered (\(eventQueue.count) events)")
            _ = await performFlush()
        }
    }
}
