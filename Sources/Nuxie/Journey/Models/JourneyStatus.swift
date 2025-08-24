import Foundation

/// Status of a journey through its lifecycle
public enum JourneyStatus: String, Codable {
    /// Journey created but not yet started
    case pending = "pending"
    
    /// Journey is actively executing nodes
    case active = "active"
    
    /// Journey is waiting (for time, event, or condition)
    case paused = "paused"
    
    /// Journey reached a natural exit
    case completed = "completed"
    
    /// Journey timed out or expired
    case expired = "expired"
    
    /// Journey was manually cancelled or replaced
    case cancelled = "cancelled"
    
    /// Check if journey is in an active state (can still progress)
    var isActive: Bool {
        switch self {
        case .active, .paused, .pending:
            return true
        case .completed, .expired, .cancelled:
            return false
        }
    }
    
    /// Check if journey is in a terminal state (cannot progress)
    var isTerminal: Bool {
        !isActive
    }
    
    /// Check if journey is live (running or paused, but not terminal)
    var isLive: Bool {
        switch self {
        case .active, .paused:
            return true
        case .pending, .completed, .expired, .cancelled:
            return false
        }
    }
}

/// Reason why a journey exited
public enum JourneyExitReason: String, Codable {
    /// Journey reached an exit node naturally
    case completed = "completed"
    
    /// Campaign goal was achieved
    case goalMet = "goal_met"
    
    /// No longer meets trigger criteria
    case triggerUnmatched = "trigger_unmatched"
    
    /// Journey timeout reached
    case expired = "expired"
    
    /// Manually cancelled (user change, etc)
    case cancelled = "cancelled"
    
    /// Unrecoverable error occurred
    case error = "error"
}

/// Result of executing a node
public enum NodeExecutionResult {
    /// Continue to the next node(s)
    case `continue`([String])
    
    /// Enter async wait state (with optional deadline)
    case async(Date?)
    
    /// Skip this node and continue
    case skip(String?)
    
    /// Journey complete
    case complete(JourneyExitReason)
}

/// Frequency policy for campaign re-entry
public enum FrequencyPolicy: String, Codable {
    /// User can only enter once ever
    case once = "once"
    
    /// User can re-enter after exiting
    case everyRematch = "every_rematch"
    
    /// User can re-enter after a fixed interval
    case fixedInterval = "fixed_interval"
}