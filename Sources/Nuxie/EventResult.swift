import Foundation

/// Result of tracking an event
public enum EventResult: Equatable {
    /// Event was accepted and tracked, no immediate flow was shown
    case noInteraction
    
    /// A flow shown as a direct result of this event finished
    case flow(FlowCompletion)
    
    /// Event wasn't accepted or couldn't be processed
    case failed(Error)
    
    public static func == (lhs: EventResult, rhs: EventResult) -> Bool {
        switch (lhs, rhs) {
        case (.noInteraction, .noInteraction):
            return true
        case let (.flow(l), .flow(r)):
            return l == r
        case let (.failed(l), .failed(r)):
            return (l as NSError) == (r as NSError)
        default:
            return false
        }
    }
    
    /// Check if a purchase was made (convenience)
    public var didPurchase: Bool {
        switch self {
        case .flow(let completion):
            if case .purchased = completion.outcome {
                return true
            }
            return false
        default:
            return false
        }
    }
    
    /// Check if a flow was shown immediately (convenience)
    public var didShowFlow: Bool {
        switch self {
        case .flow:
            return true
        default:
            return false
        }
    }
    
    /// Get the flow completion if one exists (convenience)
    public var flowCompletion: FlowCompletion? {
        switch self {
        case .flow(let completion):
            return completion
        default:
            return nil
        }
    }
}

/// Details about a flow completion
public struct FlowCompletion: Equatable {
    /// Journey ID that contained the flow
    public let journeyId: String
    
    /// Flow ID that was shown
    public let flowId: String
    
    /// Outcome of the flow interaction
    public let outcome: FlowOutcome
    
    public init(journeyId: String, flowId: String, outcome: FlowOutcome) {
        self.journeyId = journeyId
        self.flowId = flowId
        self.outcome = outcome
    }
}

/// Possible outcomes when a flow completes
public enum FlowOutcome: Equatable {
    /// User completed a purchase
    case purchased(productId: String?, transactionId: String?)
    
    /// User started a trial
    case trialStarted(productId: String?)
    
    /// User restored purchases
    case restored
    
    /// User dismissed or closed the flow
    case dismissed
    
    /// SDK opted not to show the flow
    case skipped
    
    /// An error occurred during flow presentation
    case error(message: String?)
}