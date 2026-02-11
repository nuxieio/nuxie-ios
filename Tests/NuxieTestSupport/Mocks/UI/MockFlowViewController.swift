import Foundation
@testable import Nuxie

/// Mock FlowViewController for testing purposes
class MockFlowViewController: FlowViewController {
    
    // MARK: - Initialization
    
    /// Create a mock flow view controller with test data
    init(mockFlowId: String = "test-flow") {
        let description = RemoteFlow(
            id: mockFlowId,
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
            screens: [
                RemoteFlowScreen(
                    id: "screen-1",
                    defaultViewModelId: nil,
                    defaultInstanceId: nil
                )
            ],
            interactions: [:],
            viewModels: [],
            viewModelInstances: nil,
            converters: nil,
        )

        let flow = Flow(remoteFlow: description, products: [])
        // Create a mock FlowArchiver for testing
        let mockArchiver = FlowArchiver()
        super.init(flow: flow, archiveService: mockArchiver)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Test Helper Methods
    
    /// Simulate the onClose callback being triggered
    func simulateClose(with reason: CloseReason) {
        onClose?(reason)
    }
}
