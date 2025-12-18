import Foundation
@testable import Nuxie

/// Mock implementation of NuxieApi for testing
public actor MockNuxieApi: NuxieApiProtocol {
    // Response configuration
    public var shouldFailProfile = false
    public var shouldFailBatch = false
    public var shouldFailFlow = false
    public var shouldFailTrackEvent = false
    
    public var profileDelay: TimeInterval = 0
    public var profileResponse: ProfileResponse?
    public var batchResponse: BatchResponse = BatchResponse(
        status: "success",
        processed: 0,
        failed: 0,
        total: 0,
        errors: nil
    )
    
    // Call tracking
    public var fetchProfileCallCount = 0
    public var fetchProfileWithTimeoutCallCount = 0
    public var sendBatchCallCount = 0
    public var fetchFlowCallCount = 0
    public var trackEventCallCount = 0
    
    public var lastTimeoutUsed: TimeInterval?
    
    // Track sent events for test assertions
    public private(set) var sentEvents: [NuxieEvent] = []
    
    public init() {
        setupDefaultProfileResponse()
    }
    
    private func setupDefaultProfileResponse() {
        // Create default profile response
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
    
    // Configuration methods
    public func setProfileResponse(_ response: ProfileResponse) {
        self.profileResponse = response
    }
    
    public func setProfileDelay(_ delay: TimeInterval) {
        self.profileDelay = delay
    }
    
    public func setShouldFailProfile(_ shouldFail: Bool) {
        self.shouldFailProfile = shouldFail
    }
    
    // MARK: - NuxieApiProtocol Implementation
    
    public func sendBatch(events: [BatchEventItem]) async throws -> BatchResponse {
        sendBatchCallCount += 1
        
        // Track the events as NuxieEvents for test assertions
        for item in events {
            // Convert AnyCodable properties back to [String: Any]
            var props: [String: Any] = [:]
            if let properties = item.properties {
                for (key, value) in properties {
                    props[key] = value.value
                }
            }
            
            let nuxieEvent = NuxieEvent(
                name: item.event,
                distinctId: item.distinctId,
                properties: props,
                timestamp: Date()
            )
            sentEvents.append(nuxieEvent)
        }
        
        if shouldFailBatch {
            throw NuxieNetworkError.httpError(statusCode: 500, message: "Mock batch error")
        }
        
        return BatchResponse(
            status: batchResponse.status,
            processed: events.count,
            failed: 0,
            total: events.count,
            errors: nil
        )
    }
    
    public func fetchProfile(for distinctId: String, locale: String?) async throws -> ProfileResponse {
        fetchProfileCallCount += 1

        if profileDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(profileDelay * 1_000_000_000))
        }

        if shouldFailProfile {
            throw NuxieNetworkError.httpError(statusCode: 500, message: "Mock server error")
        }

        return profileResponse!
    }

    public func fetchProfileWithTimeout(for distinctId: String, locale: String?, timeout: TimeInterval) async throws -> ProfileResponse {
        fetchProfileWithTimeoutCallCount += 1
        lastTimeoutUsed = timeout

        // Simulate timeout if delay is longer than requested timeout
        if profileDelay > timeout {
            throw NuxieNetworkError.timeout
        }

        return try await fetchProfile(for: distinctId, locale: locale)
    }
    
    public func fetchFlow(flowId: String) async throws -> RemoteFlow {
        fetchFlowCallCount += 1
        
        if shouldFailFlow {
            throw NuxieNetworkError.httpError(statusCode: 404, message: "Flow not found")
        }
        
        return RemoteFlow(
            id: flowId,
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
    }
    
    public func trackEvent(
        event: String,
        distinctId: String,
        properties: [String: Any]?,
        value: Double?
    ) async throws -> EventResponse {
        trackEventCallCount += 1

        if shouldFailTrackEvent {
            throw NuxieNetworkError.httpError(statusCode: 500, message: "Mock tracking error")
        }

        return EventResponse(
            status: "success",
            payload: nil,
            customer: nil,
            event: nil,
            message: nil,
            featuresMatched: nil,
            usage: nil
        )
    }

    public func checkFeature(
        customerId: String,
        featureId: String,
        requiredBalance: Int?,
        entityId: String?
    ) async throws -> FeatureCheckResult {
        return FeatureCheckResult(
            customerId: customerId,
            featureId: featureId,
            requiredBalance: requiredBalance ?? 1,
            code: "granted",
            allowed: true,
            unlimited: false,
            balance: 100,
            type: .boolean,
            preview: nil
        )
    }

    // Test helpers
    public func reset() {
        shouldFailProfile = false
        shouldFailBatch = false
        shouldFailFlow = false
        shouldFailTrackEvent = false
        profileDelay = 0
        fetchProfileCallCount = 0
        fetchProfileWithTimeoutCallCount = 0
        sendBatchCallCount = 0
        fetchFlowCallCount = 0
        trackEventCallCount = 0
        lastTimeoutUsed = nil
        sentEvents.removeAll()
        
        // Reset profileResponse to default
        setupDefaultProfileResponse()
    }
}