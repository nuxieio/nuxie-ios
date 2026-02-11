import Foundation

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
    @MainActor func present(_ viewController: NuxiePlatformViewController) async
    
    /// Dismiss the currently presented view controller
    @MainActor func dismiss() async
    
    /// Destroy the window and clean up resources
    @MainActor func destroy()
    
    /// Check if a view controller is currently being presented
    @MainActor var isPresenting: Bool { get }
}

// MARK: - Default Implementation

/// Default window provider using UIApplication / NSApplication.
@MainActor
class DefaultWindowProvider: WindowProviderProtocol {

    func canPresentWindow() -> Bool {
        #if canImport(UIKit)
        return UIApplication.shared.activeWindowScene != nil
        #elseif canImport(AppKit)
        return NSApplication.shared.activeWindow != nil || NSScreen.main != nil
        #else
        return false
        #endif
    }

    func createPresentationWindow() -> PresentationWindowProtocol? {
        #if canImport(UIKit)
        guard let scene = UIApplication.shared.activeWindowScene else {
            return nil
        }
        return IOSPresentationWindow(scene: scene)
        #elseif canImport(AppKit)
        let frame =
            NSApplication.shared.activeWindow?.frame
            ?? NSScreen.main?.frame
            ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        return MacPresentationWindow(frame: frame)
        #else
        return nil
        #endif
    }
}

#if canImport(UIKit)
import UIKit

@MainActor
private final class IOSPresentationWindow: PresentationWindowProtocol {
    private let window: UIWindow
    private let rootViewController: UIViewController

    init(scene: UIWindowScene) {
        self.window = UIWindow(windowScene: scene)
        self.rootViewController = UIViewController()

        rootViewController.view.backgroundColor = .clear
        window.rootViewController = rootViewController
        window.windowLevel = .alert
        window.backgroundColor = .clear
    }

    func present(_ viewController: NuxiePlatformViewController) async {
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
#endif

#if canImport(AppKit)
import AppKit

@MainActor
private final class MacPresentationWindow: PresentationWindowProtocol {
    private let window: NSWindow
    private var presentedViewController: NSViewController?

    init(frame: NSRect) {
        self.window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    }

    func present(_ viewController: NuxiePlatformViewController) async {
        presentedViewController = viewController
        window.contentViewController = viewController
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func dismiss() async {
        guard presentedViewController != nil else { return }
        window.orderOut(nil)
        window.contentViewController = nil
        presentedViewController = nil
    }

    func destroy() {
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
        presentedViewController = nil
    }

    var isPresenting: Bool {
        return presentedViewController != nil
    }
}
#endif
