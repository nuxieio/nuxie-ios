import Foundation
@testable import Nuxie

/// Helper methods for creating common API responses in tests
struct ResponseBuilders {
    
    // MARK: - Profile Response
    
    static func buildProfileResponse(
        campaigns: [Campaign] = [],
        segments: [Segment] = [],
        flows: [RemoteFlow] = [],
        userProperties: [String: AnyCodable]? = nil,
        experimentAssignments: [String: ExperimentAssignment]? = nil,
        features: [Feature]? = nil
    ) -> ProfileResponse {
        return ProfileResponse(
            campaigns: campaigns,
            segments: segments,
            flows: flows,
            userProperties: userProperties,
            experimentAssignments: experimentAssignments,
            features: features
        )
    }
    
    static func buildCampaign(
        id: String = "campaign-1",
        name: String = "Test Campaign",
        versionId: String = "version-1",
        versionNumber: Int = 1,
        triggerType: String = "event",
        eventName: String = "app_open"
    ) -> Campaign {
        return Campaign(
            id: id,
            name: name,
            versionId: versionId,
            versionNumber: versionNumber,
            frequencyPolicy: "once",
            frequencyInterval: nil,
            messageLimit: nil,
            publishedAt: Date().ISO8601Format(),
            trigger: .event(EventTriggerConfig(
                eventName: eventName,
                condition: nil
            )),
            entryNodeId: nil,
            workflow: Workflow(nodes: []),
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            campaignType: nil
        )
    }
    
    // MARK: - Batch Response
    
    static func buildBatchResponse(
        processed: Int,
        failed: Int = 0,
        errors: [BatchError]? = nil
    ) -> BatchResponse {
        return BatchResponse(
            status: failed > 0 ? "partial" : "success",
            processed: processed,
            failed: failed,
            total: processed + failed,
            errors: errors
        )
    }
    
    static func buildBatchError(
        index: Int,
        event: String,
        error: String
    ) -> BatchError {
        return BatchError(
            index: index,
            event: event,
            error: error
        )
    }
    
    // MARK: - Event Response

    static func buildEventResponse(
        status: String = "success"
    ) -> EventResponse {
        return EventResponse(
            status: status,
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

    static func buildFeatureUsedResponse(
        status: String = "ok",
        message: String? = "Feature usage tracked successfully",
        current: Double = 5,
        limit: Double? = 100,
        remaining: Double? = 95
    ) -> EventResponse {
        return EventResponse(
            status: status,
            payload: nil,
            customer: nil,
            event: nil,
            message: message,
            featuresMatched: nil,
            usage: EventResponse.Usage(
                current: current,
                limit: limit,
                remaining: remaining
            ),
            journey: nil,
            execution: nil
        )
    }
    
    // MARK: - Flow Response
    
    static func buildRemoteFlow(
        id: String = "flow-1",
        name: String = "Test Flow",
        url: String = "https://example.com/builds/flow-1",
        products: [RemoteFlowProduct] = [],
        manifest: BuildManifest? = nil
    ) -> RemoteFlow {
        return RemoteFlow(
            id: id,
            name: name,
            url: url,
            products: products,
            manifest: manifest ?? buildManifest(files: [])
        )
    }
    
    static func buildRemoteFlowProduct(
        id: String = "product-1",
        extId: String = "com.example.premium",
        name: String = "Premium"
    ) -> RemoteFlowProduct {
        return RemoteFlowProduct(
            id: id,
            extId: extId,
            name: name
        )
    }
    
    // MARK: - Error Response
    
    static func buildErrorResponse(
        message: String = "Test error",
        code: String? = nil,
        details: [String: AnyCodable]? = nil
    ) -> APIErrorResponse {
        return APIErrorResponse(
            message: message,
            code: code,
            details: details
        )
    }
    
    // MARK: - Build Manifest
    
    static func buildManifest(
        files: [BuildFile],
        contentHash: String = "test-hash"
    ) -> BuildManifest {
        let totalSize = files.reduce(0) { $0 + $1.size }
        return BuildManifest(
            totalFiles: files.count,
            totalSize: totalSize,
            contentHash: contentHash,
            files: files
        )
    }
    
    static func buildFile(
        path: String,
        size: Int = 100,
        contentType: String = "text/html"
    ) -> BuildFile {
        return BuildFile(
            path: path,
            size: size,
            contentType: contentType
        )
    }
    
    // MARK: - JSON Data Helpers
    
    /// Convert any Encodable to JSON data
    static func toJSON<T: Encodable>(_ object: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(object)
    }
    
    /// Create a simple JSON error response
    static func errorJSON(message: String, statusCode: Int = 400) -> Data {
        let json = """
        {
            "message": "\(message)",
            "statusCode": \(statusCode)
        }
        """
        return json.data(using: .utf8)!
    }
}