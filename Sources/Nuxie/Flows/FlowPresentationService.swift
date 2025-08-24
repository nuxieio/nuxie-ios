import Foundation
import UIKit
import FactoryKit

/// Protocol for presenting flows in dedicated windows
protocol FlowPresentationServiceProtocol: AnyObject {
    /// Present a flow by ID in a dedicated window
    @MainActor func presentFlow(_ flowId: String, from journey: Journey?) async throws
    
    /// Dismiss the currently presented flow
    @MainActor func dismissCurrentFlow() async
    
    /// Check if a flow is currently presented
    @MainActor var isFlowPresented: Bool { get }
}

/// Service for presenting flows in dedicated windows over the entire app
final class FlowPresentationService: FlowPresentationServiceProtocol {
    
    // MARK: - Dependencies
    
    @Injected(\.flowService) private var flowService: FlowServiceProtocol
    @Injected(\.eventService) private var eventService: EventServiceProtocol
    private let windowProvider: WindowProviderProtocol
    
    // MARK: - State
    
    internal var currentWindow: PresentationWindowProtocol?
    internal var currentFlowId: String?
    internal var currentJourney: Journey?
    
    // MARK: - Initialization
    
    init(windowProvider: WindowProviderProtocol? = nil) {
        self.windowProvider = windowProvider ?? DefaultWindowProvider()
    }
    
    // MARK: - Public API
    
    @MainActor
    var isFlowPresented: Bool {
        currentWindow?.isPresenting ?? false
    }
    
    @MainActor
    func presentFlow(_ flowId: String, from journey: Journey?) async throws {
        LogInfo("FlowPresentationService: Presenting flow \(flowId)")
        
        // Dismiss any currently presented flow first
        if isFlowPresented {
            LogWarning("FlowPresentationService: Dismissing existing flow before presenting new one")
            await dismissCurrentFlow()
        }
        
        // 1. Check if we can present
        guard windowProvider.canPresentWindow() else {
            LogError("FlowPresentationService: No active window scene available")
            throw FlowPresentationError.noActiveScene
        }
        
        // 2. Get flow view controller from FlowService
        let flowViewController = try await flowService.viewController(for: flowId)
        
        // 3. Create presentation window
        guard let window = windowProvider.createPresentationWindow() else {
            LogError("FlowPresentationService: Failed to create presentation window")
            throw FlowPresentationError.noActiveScene
        }
        
        // 4. Set up dismissal handler
        flowViewController.onClose = { [weak self] reason in
            Task { @MainActor in
                await self?.handleFlowDismissal(reason: reason)
            }
        }
        
        // 5. Store state before presenting to avoid race conditions
        self.currentWindow = window
        self.currentFlowId = flowId
        self.currentJourney = journey
        
        // 6. Present flow
        await window.present(flowViewController)
        
        LogDebug("FlowPresentationService: Successfully presented flow \(flowId)")
    }
    
    @MainActor
    func dismissCurrentFlow() async {
        guard let window = currentWindow else {
            LogDebug("FlowPresentationService: No flow to dismiss")
            return
        }
        
        LogInfo("FlowPresentationService: Dismissing current flow")
        
        // Dismiss the presented view controller
        await window.dismiss()
        
        // Clean up window and state
        await cleanupPresentation()
    }
    
    // MARK: - Private Methods
    
    @MainActor
    private func handleFlowDismissal(reason: CloseReason) async {
        let flowId = currentFlowId ?? "unknown"
        let journey = currentJourney
        
        LogInfo("FlowPresentationService: Flow \(flowId) dismissed with reason: \(reason)")
        
        // Track flow completion event with detailed properties
        if let journey = journey {
            let completionType = mapCloseReasonToCompletionType(reason)
            var properties = JourneyEvents.flowCompletedProperties(
                flowId: flowId,
                journey: journey,
                completionType: completionType
            )
            
            // Add additional properties based on reason
            switch reason {
            case .purchaseCompleted:
                // In a real implementation, we'd get these from the purchase flow
                // For now, we'll leave them unset and let the purchase delegate handle it
                break
            case .error(let error):
                properties["error_message"] = error.localizedDescription
            default:
                break
            }
            
            eventService.track(JourneyEvents.flowCompleted, properties: properties)
        }
        
        // Clean up
        await cleanupPresentation()
    }
    
    private func mapCloseReasonToCompletionType(_ reason: CloseReason) -> String {
        switch reason {
        case .userDismissed:
            return "dismissed"
        case .purchaseCompleted:
            return "purchase"
        case .timeout:
            return "timeout"
        case .error:
            return "error"
        }
    }
    
    @MainActor
    private func cleanupPresentation() async {
        LogDebug("FlowPresentationService: Cleaning up presentation")
        
        // Destroy window
        currentWindow?.destroy()
        currentWindow = nil
        
        // Reset state
        currentFlowId = nil
        currentJourney = nil
    }
}

// MARK: - Errors

enum FlowPresentationError: LocalizedError {
    case noActiveScene
    case flowNotFound(String)
    case presentationFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .noActiveScene:
            return "No active window scene available for presentation"
        case .flowNotFound(let flowId):
            return "Flow not found: \(flowId)"
        case .presentationFailed(let error):
            return "Flow presentation failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - UIViewController Async Presentation Extension

private extension UIViewController {
    @MainActor
    func present(_ viewControllerToPresent: UIViewController, animated: Bool) async {
        await withCheckedContinuation { continuation in
            self.present(viewControllerToPresent, animated: animated) {
                continuation.resume()
            }
        }
    }
    
    @MainActor
    func dismiss(animated: Bool) async {
        await withCheckedContinuation { continuation in
            self.dismiss(animated: animated) {
                continuation.resume()
            }
        }
    }
}
