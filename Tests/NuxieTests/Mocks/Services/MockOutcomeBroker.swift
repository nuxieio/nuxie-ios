import Foundation
@testable import Nuxie

/// Mock implementation of OutcomeBrokerProtocol for testing
public actor MockOutcomeBroker: OutcomeBrokerProtocol {
    
    // Track calls for test verification
    public private(set) var registerCallCount = 0
    public private(set) var bindCallCount = 0
    public private(set) var observeCallCount = 0
    public private(set) var lastRegisteredEventId: String?
    public private(set) var lastBoundJourneyId: String?
    
    public init() {}
    
    public func register(eventId: String, timeout: TimeInterval, completion: @escaping (EventResult) -> Void) {
        registerCallCount += 1
        lastRegisteredEventId = eventId
        
        // Immediately call completion with .noInteraction for unit tests
        // This simulates the timeout without actually waiting
        completion(.noInteraction)
    }
    
    public func bind(eventId: String, journeyId: String, flowId: String) {
        bindCallCount += 1
        lastBoundJourneyId = journeyId
    }
    
    public func observe(event: NuxieEvent) {
        observeCallCount += 1
    }
    
    public func reset() {
        registerCallCount = 0
        bindCallCount = 0
        observeCallCount = 0
        lastRegisteredEventId = nil
        lastBoundJourneyId = nil
    }
}