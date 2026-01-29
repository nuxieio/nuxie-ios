import Foundation
import UIKit
import FactoryKit

/// Protocol for presenting flows in dedicated windows
protocol FlowPresentationServiceProtocol: AnyObject {
    /// Present a flow by ID in a dedicated window
    @discardableResult
    @MainActor func presentFlow(_ flowId: String, from journey: Journey?, runtimeDelegate: FlowRuntimeDelegate?) async throws -> FlowViewController
    
    /// Dismiss the currently presented flow
    @MainActor func dismissCurrentFlow() async
    
    /// Check if a flow is currently presented
    @MainActor var isFlowPresented: Bool { get }
    
    /// Called when app becomes active - starts grace period
    @MainActor func onAppBecameActive()
    
    /// Called when app enters background - clears grace period
    @MainActor func onAppDidEnterBackground()
}

/// Service for presenting flows in dedicated windows over the entire app
@MainActor
final class FlowPresentationService: FlowPresentationServiceProtocol {
    
    // MARK: - Dependencies
    
    @Injected(\.flowService) private var flowService: FlowServiceProtocol
    @Injected(\.eventService) private var eventService: EventServiceProtocol
    @Injected(\.triggerBroker) private var triggerBroker: TriggerBrokerProtocol
    private let windowProvider: WindowProviderProtocol
    
    // MARK: - State
    
    internal var currentWindow: PresentationWindowProtocol?
    internal var currentFlowId: String?
    internal var currentJourney: Journey?
    
    // MARK: - Grace Period
    
    private let foregroundGracePeriod: TimeInterval = 0.75  // UX grace window
    private var gracePeriodEndTime: Date?
    
    // MARK: - Initialization
    
    init(windowProvider: WindowProviderProtocol? = nil) {
        self.windowProvider = windowProvider ?? DefaultWindowProvider()
    }
    
    // MARK: - Public API
    
    var isFlowPresented: Bool {
        currentWindow?.isPresenting ?? false
    }
    
    @discardableResult
    func presentFlow(_ flowId: String, from journey: Journey?, runtimeDelegate: FlowRuntimeDelegate?) async throws -> FlowViewController {
        LogInfo("FlowPresentationService: Presenting flow \(flowId)")
        
        // Check if we're within the grace period
        if let gracePeriodEnd = gracePeriodEndTime {
            let now = Date()
            if now < gracePeriodEnd {
                let delaySeconds = gracePeriodEnd.timeIntervalSince(now)
                LogDebug("FlowPresentationService: Delaying flow presentation by \(delaySeconds) seconds (grace period)")
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }
        
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
        let flowViewController = try await flowService.viewController(for: flowId, runtimeDelegate: runtimeDelegate)
        
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

        if let journey = journey {
            eventService.track(
                JourneyEvents.flowShown,
                properties: JourneyEvents.flowShownProperties(flowId: flowId, journey: journey),
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
            if let originEventId = journey.getContext("_origin_event_id") as? String {
                let ref = JourneyRef(
                    journeyId: journey.id,
                    campaignId: journey.campaignId,
                    flowId: journey.flowId
                )
                await triggerBroker.emit(eventId: originEventId, update: .decision(.flowShown(ref)))
            }
        }

        LogDebug("FlowPresentationService: Successfully presented flow \(flowId)")
        return flowViewController
    }
    
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
    
    func onAppBecameActive() {
        LogDebug("FlowPresentationService: App became active, starting grace period")
        // Set grace period end time
        gracePeriodEndTime = Date().addingTimeInterval(foregroundGracePeriod)
    }
    
    func onAppDidEnterBackground() {
        LogDebug("FlowPresentationService: App entered background, clearing grace period")
        // Clear grace period when going to background
        gracePeriodEndTime = nil
    }
    
    // MARK: - Private Methods
    
    private func handleFlowDismissal(reason: CloseReason) async {
        let flowId = currentFlowId ?? "unknown"
        let journey = currentJourney

        LogInfo("FlowPresentationService: Flow \(flowId) dismissed with reason: \(reason)")

        // Track specific flow event based on reason
        if let journey = journey {
            switch reason {
            case .userDismissed:
                eventService.track(
                    JourneyEvents.flowDismissed,
                    properties: JourneyEvents.flowDismissedProperties(flowId: flowId, journey: journey),
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )

            case .purchaseCompleted:
                eventService.track(
                    JourneyEvents.flowPurchased,
                    properties: JourneyEvents.flowPurchasedProperties(flowId: flowId, journey: journey, productId: nil),
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )

            case .timeout:
                eventService.track(
                    JourneyEvents.flowTimedOut,
                    properties: JourneyEvents.flowTimedOutProperties(flowId: flowId, journey: journey),
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )

            case .error(let error):
                eventService.track(
                    JourneyEvents.flowErrored,
                    properties: JourneyEvents.flowErroredProperties(flowId: flowId, journey: journey, errorMessage: error.localizedDescription),
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
            }
        }

        // Clean up
        await cleanupPresentation()
    }
    
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
    func present(_ viewControllerToPresent: UIViewController, animated: Bool) async {
        await withCheckedContinuation { continuation in
            self.present(viewControllerToPresent, animated: animated) {
                continuation.resume()
            }
        }
    }
    
    func dismiss(animated: Bool) async {
        await withCheckedContinuation { continuation in
            self.dismiss(animated: animated) {
                continuation.resume()
            }
        }
    }
}
