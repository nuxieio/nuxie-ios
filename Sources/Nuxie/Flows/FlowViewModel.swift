import Foundation
import FactoryKit

/// View model for FlowViewController - handles business logic and state management
@MainActor
class FlowViewModel {
    
    // MARK: - State
    
    enum State: Equatable {
        case loading
        case loaded
        case error
    }
    
    // MARK: - Properties
    
    private(set) var flow: Flow
    private(set) var products: [FlowProduct]
    private(set) var currentState: State = .loading {
        didSet {
            onStateChanged?(currentState)
        }
    }
    
    private let archiveService: FlowArchiver
    private let fontStore: FontStore?
    
    // MARK: - Bindings (Closures)
    
    /// Called when state changes
    var onStateChanged: ((State) -> Void)?
    
    /// Called when products need to be injected
    var onInjectProducts: (([FlowProduct]) -> Void)?
    
    /// Called when we need to load a URL
    var onLoadURL: ((URL) -> Void)?
    
    /// Called when we need to load a request
    var onLoadRequest: ((URLRequest) -> Void)?
    
    // MARK: - Timer
    
    private var loadingTimer: Timer?
    private let loadingTimeoutSeconds: TimeInterval = 15.0
    
    // MARK: - Initialization
    
    init(flow: Flow, archiveService: FlowArchiver, fontStore: FontStore? = nil) {
        self.flow = flow
        self.products = flow.products
        self.archiveService = archiveService
        self.fontStore = fontStore
        LogDebug("FlowViewModel initialized for flow: \(flow.id)")
    }
    
    deinit {
        loadingTimer?.invalidate()
        loadingTimer = nil
    }
    
    // MARK: - Public Methods
    
    /// Start loading the flow content
    func loadFlow() {
        currentState = .loading
        startLoadingTimeout()
        
        Task {
            await loadFlowAsync()
        }
    }
    
    /// Async version of loadFlow
    private func loadFlowAsync() async {
        if let fontStore {
            await fontStore.registerManifest(flow.remoteFlow.fontManifest)
        }
        // 1. Try loading from cached WebArchive first
        if let archiveURL = await archiveService.getArchiveURL(for: flow) {
            onLoadURL?(archiveURL)
            LogDebug("Loading flow from cached WebArchive: \(archiveURL)")
            return
        }
        
        // 2. Fallback to loading from remote URL
        if let remoteURL = URL(string: flow.url) {
            let request = URLRequest(url: remoteURL)
            onLoadRequest?(request)
            LogDebug("Loading flow from remote URL: \(remoteURL)")
            
            // 3. Download archive in background for next time
            await archiveService.preloadArchive(for: flow)
        } else {
            // 4. Show error state
            currentState = .error
            LogError("Failed to load flow: \(flow.id) - no content available")
        }
    }
    
    /// Called when loading starts
    func handleLoadingStarted() {
        LogDebug("Started loading flow: \(flow.id)")
        currentState = .loading
    }
    
    /// Called when loading finishes successfully
    func handleLoadingFinished() {
        LogDebug("Finished loading flow: \(flow.id)")
        cancelLoadingTimeout()
        currentState = .loaded
        
        // Trigger product injection
        onInjectProducts?(products)
    }
    
    /// Called when loading fails
    func handleLoadingFailed(_ error: Error) {
        LogError("Failed to load flow \(flow.id): \(error)")
        cancelLoadingTimeout()
        currentState = .error
    }
    
    /// Update products
    func updateProducts(_ newProducts: [FlowProduct]) {
        self.products = newProducts
        
        // If already loaded, inject the new products
        if case .loaded = currentState {
            onInjectProducts?(products)
        }
        
        LogDebug("Updated products for flow: \(flow.id)")
    }
    
    /// Update the flow and reload if content has changed
    func updateFlowIfNeeded(_ newFlow: Flow) {
        // Check if the flow content has changed (using manifest hash)
        let hasContentChanged = flow.manifest.contentHash != newFlow.manifest.contentHash
        
        // Always update the flow reference
        self.flow = newFlow
        self.products = newFlow.products
        
        // If content or URL changed, reload the web view
        if hasContentChanged {
            LogDebug("Flow content changed for \(flow.id), reloading web view")
            loadFlow()
        } else if products != newFlow.products {
            // Just products changed, inject them without full reload
            LogDebug("Only products changed for \(flow.id), updating products")
            updateProducts(newFlow.products)
        }
    }
    
    /// Retry loading
    func retry() {
        loadFlow()
    }
    
    /// Generate JSON string for products
    func generateProductsJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        
        do {
            let productsData = try encoder.encode(products)
            return String(data: productsData, encoding: .utf8)
        } catch {
            LogError("Failed to encode products: \(error)")
            return nil
        }
    }
    
    // MARK: - Private Methods
    
    private func startLoadingTimeout() {
        cancelLoadingTimeout()
        
        loadingTimer = Timer.scheduledTimer(withTimeInterval: loadingTimeoutSeconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if case .loading = self.currentState {
                self.currentState = .error
                LogDebug("Loading timeout reached for flow: \(self.flow.id)")
            }
        }
    }
    
    private func cancelLoadingTimeout() {
        loadingTimer?.invalidate()
        loadingTimer = nil
    }
}
