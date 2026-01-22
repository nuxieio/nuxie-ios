import Foundation
import UIKit
@testable import Nuxie

/// Mock FlowViewController for testing purposes
class MockFlowViewController: FlowViewController {
    
    // MARK: - Tracking Properties
    
    var dismissCalled = false
    var dismissAnimated = false
    var onCloseInvoked: CloseReason?
    var presentCalled = false
    var presentAnimated = false
    
    // MARK: - Initialization
    
    /// Create a mock flow view controller with test data
    init(mockFlowId: String = "test-flow") {
        let description = RemoteFlow(
            id: mockFlowId,
            version: "v1",
            bundle: FlowBundleRef(
                url: "https://example.com/flow/\(mockFlowId)",
                manifest: BuildManifest(
                    totalFiles: 1,
                    totalSize: 100,
                    contentHash: "test-hash",
                    files: [
                        BuildFile(path: "index.html", size: 100, contentType: "text/html")
                    ]
                )
            ),
            entryScreenId: "screen-1",
            entryActions: nil,
            screens: [
                RemoteFlowScreen(
                    id: "screen-1",
                    name: nil,
                    locale: nil,
                    route: nil,
                    defaultViewModelId: nil,
                    defaultInstanceId: nil
                )
            ],
            interactions: RemoteFlowInteractions(screens: [:], components: nil),
            viewModels: [],
            viewModelInstances: nil,
            converters: nil,
            pathIndex: nil
        )

        let flow = Flow(remoteFlow: description, products: [])
        // Create a mock FlowArchiver for testing
        let mockArchiver = FlowArchiver()
        super.init(flow: flow, archiveService: mockArchiver)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Overridden Methods
    
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        dismissCalled = true
        dismissAnimated = flag
        
        // Simulate the actual dismissal behavior
        DispatchQueue.main.async {
            completion?()
        }
    }
    
    override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
        presentCalled = true
        presentAnimated = flag
        
        // Simulate the actual presentation behavior
        DispatchQueue.main.async {
            completion?()
        }
    }
    
    // MARK: - Test Helper Methods
    
    /// Simulate the onClose callback being triggered
    func simulateClose(with reason: CloseReason) {
        onCloseInvoked = reason
        onClose?(reason)
    }
    
    /// Reset all tracking properties
    func reset() {
        dismissCalled = false
        dismissAnimated = false
        onCloseInvoked = nil
        presentCalled = false
        presentAnimated = false
    }
}
