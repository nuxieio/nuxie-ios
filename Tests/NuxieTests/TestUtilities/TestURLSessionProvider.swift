import Foundation

/// Provides URLSession instances configured for testing with StubURLProtocol
struct TestURLSessionProvider {
    
    /// Create a URLSession configured for testing with StubURLProtocol
    /// - Parameter additionalHeaders: Optional additional headers to include in requests
    /// - Returns: URLSession configured with ephemeral configuration and StubURLProtocol
    static func createTestSession(additionalHeaders: [String: String]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        
        // Register StubURLProtocol to intercept all requests
        configuration.protocolClasses = [StubURLProtocol.self]
        
        // Disable caching
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        // Set timeouts
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        
        // Add any additional headers
        if let headers = additionalHeaders {
            configuration.httpAdditionalHeaders = headers
        }
        
        return URLSession(configuration: configuration)
    }
    
    /// Create a URLSession configured to match NuxieApi's configuration
    /// - Parameters:
    ///   - useGzipCompression: Whether to include gzip compression headers
    ///   - sdkVersion: SDK version string (defaults to current)
    /// - Returns: URLSession configured similarly to production NuxieApi
    static func createNuxieTestSession(
        useGzipCompression: Bool = false,
        sdkVersion: String = "1.0.0"
    ) -> URLSession {
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept-Encoding": "gzip",
            "User-Agent": "Nuxie-iOS-SDK/\(sdkVersion)"
        ]
        
        if useGzipCompression {
            headers["Content-Encoding"] = "gzip"
        }
        
        return createTestSession(additionalHeaders: headers)
    }
    
    /// Reset the StubURLProtocol handlers
    /// Call this in test tearDown to ensure clean state
    static func reset() {
        StubURLProtocol.reset()
    }
}