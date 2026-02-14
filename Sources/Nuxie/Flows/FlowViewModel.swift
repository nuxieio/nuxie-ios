import Foundation
import FactoryKit

struct FlowArtifactTelemetryContext {
    let targetCompilerBackend: String
    let targetBuildId: String?
    let targetSelectionReason: String
    let adapterCompilerBackend: String
    let adapterFallback: Bool

    static func from(flow: Flow) -> FlowArtifactTelemetryContext {
        let targetSelection = flow.remoteFlow.selectedTargetResult
        let targetCompilerBackend = targetSelection.selectedCompilerBackend ?? "legacy"
        return FlowArtifactTelemetryContext(
            targetCompilerBackend: targetCompilerBackend,
            targetBuildId: targetSelection.selectedBuildId,
            targetSelectionReason: targetSelection.reason.rawValue,
            adapterCompilerBackend: targetCompilerBackend,
            adapterFallback: false
        )
    }
}

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
    private var artifactTelemetryContext: FlowArtifactTelemetryContext
    @Injected(\.eventService) private var eventService: EventServiceProtocol
    
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
    private var currentArtifactSource: ArtifactSource = .unknown
    private var hasRecordedArtifactLoadOutcome = false

    private enum ArtifactSource: String {
        case cachedArchive = "cached_archive"
        case remoteURL = "remote_url"
        case unavailable = "unavailable"
        case unknown = "unknown"
    }
    
    // MARK: - Initialization
    
    init(
        flow: Flow,
        archiveService: FlowArchiver,
        fontStore: FontStore? = nil,
        artifactTelemetryContext: FlowArtifactTelemetryContext? = nil
    ) {
        self.flow = flow
        self.products = flow.products
        self.archiveService = archiveService
        self.fontStore = fontStore
        self.artifactTelemetryContext = artifactTelemetryContext ?? FlowArtifactTelemetryContext.from(flow: flow)
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
        hasRecordedArtifactLoadOutcome = false
        currentArtifactSource = .unknown
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
            currentArtifactSource = .cachedArchive
            onLoadURL?(archiveURL)
            LogDebug("Loading flow from cached WebArchive: \(archiveURL)")
            return
        }
        
        // 2. Fallback to loading from remote URL
        if let remoteURL = URL(string: flow.url) {
            currentArtifactSource = .remoteURL
            let request = URLRequest(url: remoteURL)
            onLoadRequest?(request)
            LogDebug("Loading flow from remote URL: \(remoteURL)")
            
            // 3. Download archive in background for next time
            await archiveService.preloadArchive(for: flow)
        } else {
            // 4. Show error state
            currentArtifactSource = .unavailable
            recordArtifactLoadFailure(errorMessage: "no_content_available")
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
        recordArtifactLoadSuccess()
        cancelLoadingTimeout()
        currentState = .loaded
        
        // Trigger product injection
        onInjectProducts?(products)
    }
    
    /// Called when loading fails
    func handleLoadingFailed(_ error: Error) {
        LogError("Failed to load flow \(flow.id): \(error)")
        recordArtifactLoadFailure(errorMessage: error.localizedDescription)
        cancelLoadingTimeout()
        currentState = .error
    }

    func updateArtifactTelemetryContext(_ context: FlowArtifactTelemetryContext) {
        artifactTelemetryContext = context
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
                self.recordArtifactLoadFailure(errorMessage: "loading_timeout")
                self.currentState = .error
                LogDebug("Loading timeout reached for flow: \(self.flow.id)")
            }
        }
    }
    
    private func cancelLoadingTimeout() {
        loadingTimer?.invalidate()
        loadingTimer = nil
    }

    private func recordArtifactLoadSuccess() {
        guard !hasRecordedArtifactLoadOutcome else { return }
        hasRecordedArtifactLoadOutcome = true

        eventService.track(
            JourneyEvents.flowArtifactLoadSucceeded,
            properties: JourneyEvents.flowArtifactLoadSucceededProperties(
                flowId: flow.id,
                targetCompilerBackend: artifactTelemetryContext.targetCompilerBackend,
                targetBuildId: artifactTelemetryContext.targetBuildId,
                targetSelectionReason: artifactTelemetryContext.targetSelectionReason,
                adapterCompilerBackend: artifactTelemetryContext.adapterCompilerBackend,
                adapterFallback: artifactTelemetryContext.adapterFallback,
                artifactSource: currentArtifactSource.rawValue,
                artifactContentHash: flow.manifest.contentHash
            ),
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
    }

    private func recordArtifactLoadFailure(errorMessage: String?) {
        guard !hasRecordedArtifactLoadOutcome else { return }
        hasRecordedArtifactLoadOutcome = true

        eventService.track(
            JourneyEvents.flowArtifactLoadFailed,
            properties: JourneyEvents.flowArtifactLoadFailedProperties(
                flowId: flow.id,
                targetCompilerBackend: artifactTelemetryContext.targetCompilerBackend,
                targetBuildId: artifactTelemetryContext.targetBuildId,
                targetSelectionReason: artifactTelemetryContext.targetSelectionReason,
                adapterCompilerBackend: artifactTelemetryContext.adapterCompilerBackend,
                adapterFallback: artifactTelemetryContext.adapterFallback,
                artifactSource: currentArtifactSource.rawValue,
                artifactContentHash: flow.manifest.contentHash,
                errorMessage: errorMessage
            ),
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
    }
}
