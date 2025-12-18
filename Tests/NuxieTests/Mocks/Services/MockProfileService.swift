import Foundation
@testable import Nuxie

/// Mock implementation of ProfileService for testing
public class MockProfileService: ProfileServiceProtocol {
    public var profileResponse: ProfileResponse?
    public var shouldThrow = false
    public var fetchCallCount = 0
    private var cache: [String: ProfileResponse] = [:]
    
    public init() {
        setupDefaultProfileResponse()
    }
    
    private func setupDefaultProfileResponse() {
        // Create default profile response matching MockNuxieApi
        let campaign = Campaign(
            id: "campaign-1",
            name: "Test Campaign",
            versionId: "version-1",
            versionNumber: 1,
            frequencyPolicy: "unlimited",
            frequencyInterval: nil,
            messageLimit: nil,
            publishedAt: "2024-01-01T00:00:00Z",
            trigger: .event(EventTriggerConfig(
                eventName: "test_event",
                condition: IREnvelope(
                    ir_version: 1,
                    engine_min: nil,
                    compiled_at: nil,
                    expr: .bool(true)
                )
            )),
            entryNodeId: "node-1",
            workflow: Workflow(nodes: []),
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            campaignType: nil
        )
        
        let segment = Segment(
            id: "segment-1",
            name: "Test Segment",
            condition: IREnvelope(
                ir_version: 1,
                engine_min: nil,
                compiled_at: nil,
                expr: .bool(true)  // Simple test expression
            )
        )
        
        let flow = RemoteFlow(
            id: "flow-1",
            name: "Test Flow",
            url: "https://example.com/flow",
            products: [],
            manifest: BuildManifest(
                totalFiles: 5,
                totalSize: 1024,
                contentHash: "hash123",
                files: []
            )
        )
        
        self.profileResponse = ProfileResponse(
            campaigns: [campaign],
            segments: [segment],
            flows: [flow],
            userProperties: nil,
            experimentAssignments: nil,
            features: nil
        )
    }
    
    public func fetchProfile(distinctId: String) async throws -> ProfileResponse {
        fetchCallCount += 1
        
        if shouldThrow {
            throw NSError(domain: "TestError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Mock profile fetch error"])
        }
        
        guard let response = profileResponse else {
            throw NSError(domain: "TestError", code: 4, userInfo: [NSLocalizedDescriptionKey: "No mock profile configured"])
        }
        
        cache[distinctId] = response
        return response
    }
    
    public func getCachedProfile(distinctId: String) async -> ProfileResponse? {
        return cache[distinctId]
    }
    
    public func clearCache(distinctId: String) async {
        cache.removeValue(forKey: distinctId)
    }
    
    public func clearAllCache() async {
        cache.removeAll()
    }
    
    public func cleanupExpired() async -> Int {
        let count = cache.count
        cache.removeAll()
        return count
    }
    
    public func getCacheStats() async -> [String: Any] {
        return [
            "total_cached_profiles": cache.count,
            "valid_profiles": cache.count,
            "expired_profiles": 0,
            "max_cache_age_hours": 24
        ]
    }
    
    public func refetchProfile() async throws -> ProfileResponse {
        return try await fetchProfile(distinctId: "default")
    }
    
    public func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
        // Clear cache for old user
        cache.removeValue(forKey: oldDistinctId)
        // No-op for other aspects in mock
    }
    
    public func onAppBecameActive() async {
        // Mock implementation - no-op for tests
    }
    
    // Test helpers
    public func reset() {
        setupDefaultProfileResponse()
        shouldThrow = false
        fetchCallCount = 0
        cache.removeAll()
    }
    
    // Test helper method to set campaigns
    public func setCampaigns(_ campaigns: [Campaign]) {
        guard let response = profileResponse else { return }
        profileResponse = ProfileResponse(
            campaigns: campaigns,
            segments: response.segments,
            flows: response.flows,
            userProperties: response.userProperties,
            experimentAssignments: response.experimentAssignments,
            features: response.features
        )
    }
    
    public func setProfileResponse(_ response: ProfileResponse) {
        profileResponse = response
    }
}