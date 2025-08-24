import Foundation
@testable import Nuxie

/// Mock implementation of sleep provider for testing async operations
public final class MockSleepProvider: SleepProviderProtocol {
    
    // MARK: - Types
    
    /// Represents a pending sleep operation
    public struct PendingSleep {
        public let duration: TimeInterval
        public let continuation: CheckedContinuation<Void, Error>
        public let timestamp: Date
        
        init(duration: TimeInterval, continuation: CheckedContinuation<Void, Error>) {
            self.duration = duration
            self.continuation = continuation
            self.timestamp = Date()
        }
    }
    
    // MARK: - Properties
    
    private var pendingSleeps: [UUID: PendingSleep] = [:]
    private let lock = NSLock()
    
    /// All sleep calls that have been made (for testing assertions)
    public private(set) var sleepCalls: [(duration: TimeInterval, timestamp: Date)] = []
    
    /// Whether to immediately complete sleep operations (default: false)
    public var shouldCompleteImmediately = false
    
    /// Error to throw on sleep operations (for testing error scenarios)
    public var errorToThrow: Error?
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - SleepProviderProtocol
    
    public func sleep(for duration: TimeInterval) async throws {
        lock.withLock {
            sleepCalls.append((duration: duration, timestamp: Date()))
        }
        
        // If configured to throw an error, do so
        if let error = errorToThrow {
            throw error
        }
        
        // If configured to complete immediately, return
        if shouldCompleteImmediately {
            return
        }
        
        // Otherwise, wait for manual completion
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID.v7()
            let pendingSleep = PendingSleep(duration: duration, continuation: continuation)
            
            lock.withLock {
                pendingSleeps[id] = pendingSleep
            }
        }
    }
    
    // MARK: - Test Control Methods
    
    /// Complete all pending sleep operations
    public func completeAllSleeps() {
        lock.withLock {
            for sleep in pendingSleeps.values {
                sleep.continuation.resume()
            }
            pendingSleeps.removeAll()
        }
    }
    
    /// Complete sleep operations with the specified duration
    public func completeSleeps(withDuration duration: TimeInterval) {
        lock.withLock {
            let sleepsToComplete = pendingSleeps.filter { $0.value.duration == duration }
            for (id, sleep) in sleepsToComplete {
                sleep.continuation.resume()
                pendingSleeps.removeValue(forKey: id)
            }
        }
    }
    
    /// Cancel all pending sleep operations with CancellationError
    public func cancelAllSleeps() {
        lock.withLock {
            for sleep in pendingSleeps.values {
                sleep.continuation.resume(throwing: CancellationError())
            }
            pendingSleeps.removeAll()
        }
    }
    
    /// Get the number of currently pending sleep operations
    public var pendingSleepCount: Int {
        lock.withLock {
            return pendingSleeps.count
        }
    }
    
    /// Get all pending sleep durations
    public var pendingSleepDurations: [TimeInterval] {
        lock.withLock {
            return pendingSleeps.values.map { $0.duration }
        }
    }
    
    /// Reset all state for clean test setup
    public func reset() {
        lock.withLock {
            // Cancel any pending sleeps
            for sleep in pendingSleeps.values {
                sleep.continuation.resume(throwing: CancellationError())
            }
            pendingSleeps.removeAll()
            sleepCalls.removeAll()
            shouldCompleteImmediately = false
            errorToThrow = nil
        }
    }
}

// MARK: - Extensions

extension NSLock {
    /// Execute a closure while holding the lock
    func withLock<T>(_ closure: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try closure()
    }
}