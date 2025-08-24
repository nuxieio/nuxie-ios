import Foundation

/// Protocol defining the API interface for Nuxie SDK
public protocol NuxieApiProtocol: AnyObject {
    /// Send batch of events
    func sendBatch(events: [BatchEventItem]) async throws -> BatchResponse
    
    /// Fetch user profile
    func fetchProfile(for distinctId: String) async throws -> ProfileResponse
    
    /// Fetch user profile with custom timeout
    func fetchProfileWithTimeout(for distinctId: String, timeout: TimeInterval) async throws -> ProfileResponse
    
    /// Fetch flow by ID
    func fetchFlow(flowId: String) async throws -> RemoteFlow
    
    /// Track a single event
    func trackEvent(
        event: String,
        distinctId: String,
        properties: [String: Any]?,
        value: Double?
    ) async throws -> EventResponse
}