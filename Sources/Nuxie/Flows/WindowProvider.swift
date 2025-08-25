import Foundation
import UIKit

// MARK: - Protocols

/// Protocol for providing window presentation capabilities
protocol WindowProviderProtocol {
    /// Check if window presentation is currently possible
    @MainActor func canPresentWindow() -> Bool
    
    /// Create a new presentation window
    @MainActor func createPresentationWindow() -> PresentationWindowProtocol?
}

/// Protocol for managing a presentation window
protocol PresentationWindowProtocol: AnyObject {
    /// Present a view controller in the window
    @MainActor func present(_ viewController: UIViewController) async
    
    /// Dismiss the currently presented view controller
    @MainActor func dismiss() async
    
    /// Destroy the window and clean up resources
    @MainActor func destroy()
    
    /// Check if a view controller is currently being presented
    @MainActor var isPresenting: Bool { get }
}

// MARK: - Default Implementation

/// Default window provider using UIApplication
@MainActor
class DefaultWindowProvider: WindowProviderProtocol {
    
    func canPresentWindow() -> Bool {
        return UIApplication.shared.activeWindowScene != nil
    }
    
    func createPresentationWindow() -> PresentationWindowProtocol? {
        guard let scene = UIApplication.shared.activeWindowScene else {
            return nil
        }
        return RealPresentationWindow(scene: scene)
    }
}

/// Real presentation window implementation
@MainActor
class RealPresentationWindow: PresentationWindowProtocol {
    private let window: UIWindow
    private let rootViewController: UIViewController
    
    init(scene: UIWindowScene) {
        self.window = UIWindow(windowScene: scene)
        self.rootViewController = UIViewController()
        
        // Configure the root view controller
        rootViewController.view.backgroundColor = .clear
        
        // Configure the window
        window.rootViewController = rootViewController
        window.windowLevel = .alert
        window.backgroundColor = .clear
    }
    
    func present(_ viewController: UIViewController) async {
        window.makeKeyAndVisible()
        
        await withCheckedContinuation { continuation in
            rootViewController.present(viewController, animated: true) {
                continuation.resume()
            }
        }
    }
    
    func dismiss() async {
        guard rootViewController.presentedViewController != nil else { return }
        
        await withCheckedContinuation { continuation in
            rootViewController.dismiss(animated: true) {
                continuation.resume()
            }
        }
    }
    
    func destroy() {
        window.isHidden = true
        window.rootViewController = nil
    }
    
    var isPresenting: Bool {
        return rootViewController.presentedViewController != nil
    }
}
