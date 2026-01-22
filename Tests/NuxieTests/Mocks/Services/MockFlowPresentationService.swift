import Foundation
@testable import Nuxie

/// Mock implementation of FlowPresentationService for testing
public class MockFlowPresentationService: FlowPresentationServiceProtocol {
    
    // MARK: - Tracking Properties
    
    public var presentedFlows: [(flowId: String, journey: Journey?)] = []
    public var dismissedFlows: [String] = []
    public var isPresentingFlow = false
    public var mockViewControllers: [String: FlowViewController] = [:]
    public var defaultMockViewController: FlowViewController?
    
    // MARK: - Error Testing Properties
    
    public var shouldFailPresentation = false
    public var presentationError: Error?
    public var presentationDelay: TimeInterval = 0
    
    // MARK: - Call Tracking
    
    public var presentFlowCallCount = 0
    public var dismissCurrentFlowCallCount = 0
    
    // MARK: - FlowPresentationServiceProtocol Implementation
    
    @MainActor
    public var isFlowPresented: Bool {
        return isPresentingFlow
    }
    
    @MainActor
    public func presentFlow(_ flowId: String, from journey: Journey?, runtimeDelegate: FlowRuntimeDelegate?) async throws -> FlowViewController {
        LogDebug("[MockFlowPresentationService] presentFlow called with flowId: \(flowId), journey: \(journey?.id ?? "nil")")
        presentFlowCallCount += 1
        
        // Add delay if specified (for testing timing)
        if presentationDelay > 0 {
            LogDebug("[MockFlowPresentationService] Adding delay of \(presentationDelay)s before presentation")
            try await Task.sleep(nanoseconds: UInt64(presentationDelay * 1_000_000_000))
        }
        
        // Check if we should fail
        if shouldFailPresentation {
            let error = presentationError ?? FlowPresentationError.noActiveScene
            LogWarning("[MockFlowPresentationService] Failing presentation as configured: \(error)")
            throw error
        }
        
        // Track the presentation attempt
        LogInfo("[MockFlowPresentationService] Successfully presenting flow: \(flowId)")
        presentedFlows.append((flowId: flowId, journey: journey))
        isPresentingFlow = true

        let controller = mockViewControllers[flowId]
            ?? defaultMockViewController
            ?? MockFlowViewController(mockFlowId: flowId)
        controller.runtimeDelegate = runtimeDelegate
        return controller
    }
    
    @MainActor
    public func dismissCurrentFlow() async {
        dismissCurrentFlowCallCount += 1
        
        // Track dismissal if there's a current flow
        if let lastFlow = presentedFlows.last {
            dismissedFlows.append(lastFlow.flowId)
        }
        
        isPresentingFlow = false
    }
    
    @MainActor
    public func onAppBecameActive() {
        // Mock implementation - no-op for tests
    }
    
    @MainActor
    public func onAppDidEnterBackground() {
        // Mock implementation - no-op for tests
    }
    
    // MARK: - Test Helper Methods
    
    /// Simulate successful flow presentation
    public func simulateSuccessfulPresentation(flowId: String, journey: Journey? = nil) {
        presentedFlows.append((flowId: flowId, journey: journey))
        isPresentingFlow = true
        presentFlowCallCount += 1
    }
    
    /// Simulate flow dismissal
    public func simulateDismissal() {
        if let lastFlow = presentedFlows.last {
            dismissedFlows.append(lastFlow.flowId)
        }
        isPresentingFlow = false
        dismissCurrentFlowCallCount += 1
    }
    
    /// Configure the mock to fail on next presentation
    public func configureToFail(with error: Error? = nil) {
        shouldFailPresentation = true
        presentationError = error ?? FlowPresentationError.noActiveScene
    }
    
    /// Configure the mock to succeed on next presentation
    public func configureToSucceed() {
        shouldFailPresentation = false
        presentationError = nil
    }
    
    /// Set presentation delay for testing timing scenarios
    public func setDelay(_ delay: TimeInterval) {
        presentationDelay = delay
    }
    
    /// Get the last presented flow ID
    public var lastPresentedFlowId: String? {
        return presentedFlows.last?.flowId
    }
    
    /// Get the last presented journey
    public var lastPresentedJourney: Journey? {
        return presentedFlows.last?.journey
    }
    
    /// Check if a specific flow was presented
    public func wasFlowPresented(_ flowId: String) -> Bool {
        return presentedFlows.contains { $0.flowId == flowId }
    }
    
    /// Check if a specific flow was dismissed
    public func wasFlowDismissed(_ flowId: String) -> Bool {
        return dismissedFlows.contains(flowId)
    }
    
    /// Get all presented flow IDs
    public var allPresentedFlowIds: [String] {
        return presentedFlows.map { $0.flowId }
    }
    
    /// Reset all mock state
    public func reset() {
        presentedFlows = []
        dismissedFlows = []
        isPresentingFlow = false
        shouldFailPresentation = false
        presentationError = nil
        presentationDelay = 0
        presentFlowCallCount = 0
        dismissCurrentFlowCallCount = 0
        mockViewControllers = [:]
        defaultMockViewController = nil
    }
}
