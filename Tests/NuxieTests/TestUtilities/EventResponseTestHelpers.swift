import Foundation
@testable import Nuxie

// MARK: - EventResponse Test Helpers

extension EventResponse {
    /// Create a successful response with no additional data
    static func success() -> EventResponse {
        EventResponse(
            status: "ok",
            payload: nil,
            customer: nil,
            event: nil,
            message: nil,
            featuresMatched: nil,
            usage: nil,
            journey: nil,
            execution: nil
        )
    }

    /// Create a response with execution result
    static func withExecution(
        success: Bool,
        statusCode: Int? = nil,
        contextUpdates: [String: AnyCodable]? = nil
    ) -> EventResponse {
        EventResponse(
            status: "ok",
            payload: nil,
            customer: nil,
            event: nil,
            message: nil,
            featuresMatched: nil,
            usage: nil,
            journey: nil,
            execution: ExecutionResult(
                success: success,
                statusCode: statusCode ?? (success ? 200 : 500),
                error: success ? nil : ExecutionResult.ExecutionError(
                    message: "Test error",
                    retryable: false,
                    retryAfter: nil
                ),
                contextUpdates: contextUpdates
            )
        )
    }

    /// Create a response with a retryable error
    static func withRetryableError(message: String = "Service unavailable", retryAfter: Int = 5) -> EventResponse {
        EventResponse(
            status: "ok",
            payload: nil,
            customer: nil,
            event: nil,
            message: nil,
            featuresMatched: nil,
            usage: nil,
            journey: nil,
            execution: ExecutionResult(
                success: false,
                statusCode: 503,
                error: ExecutionResult.ExecutionError(
                    message: message,
                    retryable: true,
                    retryAfter: retryAfter
                ),
                contextUpdates: nil
            )
        )
    }

    /// Create a response with a non-retryable error
    static func withNonRetryableError(message: String = "Bad request") -> EventResponse {
        EventResponse(
            status: "ok",
            payload: nil,
            customer: nil,
            event: nil,
            message: nil,
            featuresMatched: nil,
            usage: nil,
            journey: nil,
            execution: ExecutionResult(
                success: false,
                statusCode: 400,
                error: ExecutionResult.ExecutionError(
                    message: message,
                    retryable: false,
                    retryAfter: nil
                ),
                contextUpdates: nil
            )
        )
    }

    /// Create a response with journey info
    static func withJourney(sessionId: String, currentNodeId: String? = nil, status: String = "active") -> EventResponse {
        EventResponse(
            status: "ok",
            payload: nil,
            customer: nil,
            event: nil,
            message: nil,
            featuresMatched: nil,
            usage: nil,
            journey: JourneyInfo(
                sessionId: sessionId,
                currentNodeId: currentNodeId,
                status: status
            ),
            execution: nil
        )
    }
}
