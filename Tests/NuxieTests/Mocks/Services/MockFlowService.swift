import Foundation
@testable import Nuxie

/// Mock implementation of FlowService for testing
public class MockFlowService: FlowServiceProtocol {
    public var prefetchedFlows: [FlowDescription] = []
    public var removedFlowIds: [String] = []
    
    // Error testing properties
    public var shouldFailFlowDisplay = false
    public var failureError: Error?
    public var displayAttempts: [(flowId: String, timestamp: Date)] = []
    
    // Property storage for testing
    private var properties: [String: Any] = [:]
    
    // View controller generation for testing
    public var mockViewControllers: [String: FlowViewController] = [:]
    public var defaultMockViewController: FlowViewController?
    
    public func prefetchFlows(_ descriptions: [FlowDescription]) {
        prefetchedFlows.append(contentsOf: descriptions)
    }
    
    public func removeFlows(_ flowIds: [String]) async {
        removedFlowIds.append(contentsOf: flowIds)
    }
    
    @MainActor
    public func viewController(for flowId: String) async throws -> FlowViewController {
        // Track display attempts
        displayAttempts.append((flowId: flowId, timestamp: Date()))
        
        // Check if we should fail
        if shouldFailFlowDisplay {
            throw failureError ?? FlowError.flowNotFound(flowId)
        }
        
        // Return specific mock view controller if available
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

    @MainActor
    public func viewController(for flowId: String, runtimeDelegate: FlowRuntimeDelegate?) async throws -> FlowViewController {
        let controller = try await viewController(for: flowId)
        controller.runtimeDelegate = runtimeDelegate
        return controller
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
}

public enum FlowError: Error {
    case flowNotFound(String)
    case presentationFailed(String)
}
