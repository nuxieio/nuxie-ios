import Foundation
@testable import Nuxie

/// Mock implementation of FlowService for testing
public class MockFlowService: FlowServiceProtocol {
    public var prefetchedFlows: [RemoteFlow] = []
    public var removedFlowIds: [String] = []
    
    // Error testing properties
    public var shouldFailFlowDisplay = false
    public var failureError: Error?
    public var displayAttempts: [(flowId: String, locale: String?, timestamp: Date)] = []
    
    // Property storage for testing
    private var properties: [String: Any] = [:]
    
    // View controller generation for testing
    public var mockViewControllers: [String: FlowViewController] = [:]
    public var defaultMockViewController: FlowViewController?
    
    public func prefetchFlows(_ flows: [RemoteFlow]) {
        prefetchedFlows.append(contentsOf: flows)
    }
    
    public func removeFlows(_ flowIds: [String]) async {
        removedFlowIds.append(contentsOf: flowIds)
    }
    
    @MainActor
    public func viewController(for flowId: String, locale: String? = nil) async throws -> FlowViewController {
        // Track display attempts
        displayAttempts.append((flowId: flowId, locale: locale, timestamp: Date()))
        
        // Check if we should fail
        if shouldFailFlowDisplay {
            throw failureError ?? FlowError.flowNotFound(flowId)
        }
        
        // Return specific mock view controller if available
        let localeKey = storageKey(for: flowId, locale: locale)
        if let mockVC = mockViewControllers[localeKey] {
            return mockVC
        }
        
        if let mockVC = mockViewControllers[flowId] {
            return mockVC
        }
        
        // Return default mock view controller if available
        if let defaultVC = defaultMockViewController {
            return defaultVC
        }
        
        // Create a basic mock view controller
        return MockFlowViewController(mockFlowId: flowId)
    }
    
    public func clearCache() async {
        // Mock implementation - just clear tracked data
        prefetchedFlows = []
        removedFlowIds = []
    }
    
    public func reset() {
        prefetchedFlows = []
        removedFlowIds = []
        shouldFailFlowDisplay = false
        failureError = nil
        displayAttempts = []
        properties = [:]
        mockViewControllers = [:]
        defaultMockViewController = nil
    }
    
    // Property storage methods for testing
    public func getProperty(_ key: String) -> Any? {
        return properties[key]
    }
    
    public func setProperty(_ key: String, value: Any?) {
        properties[key] = value
    }

    private func storageKey(for flowId: String, locale: String?) -> String {
        let normalized = locale?.lowercased() ?? "default"
        return "\(flowId)#\(normalized)"
    }
}

public enum FlowError: Error {
    case flowNotFound(String)
    case presentationFailed(String)
}
