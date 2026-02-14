import Foundation

/// Manages creation and caching of flow view controllers
@MainActor
final class FlowViewControllerCache {
    
    // MARK: - Properties
    
    // Cache of view controllers by flow ID
    // MainActor-isolated so no need for dispatch queues
    private var cache: [String: FlowViewController] = [:]
    
    // Track which VCs are loaded vs just cached
    private var loadedViewControllers: Set<String> = []
    
    // Flow archiver for creating view controllers
    private let flowArchiver: FlowArchiver
    private let fontStore: FontStore
    private let rendererAdapterRegistry: FlowRendererAdapterRegistry
    
    // MARK: - Initialization
    
    init(
        flowArchiver: FlowArchiver,
        fontStore: FontStore,
        rendererAdapterRegistry: FlowRendererAdapterRegistry
    ) {
        self.flowArchiver = flowArchiver
        self.fontStore = fontStore
        self.rendererAdapterRegistry = rendererAdapterRegistry
        LogDebug("FlowViewControllerCache initialized")
    }
    
    // MARK: - Public Methods
    
    /// 1. Get view controller from cache (returns nil if not cached)
    func getCachedViewController(for flowId: String) -> FlowViewController? {
        return cache[flowId]
    }

    /// Update a cached view controller with the correct renderer-normalized flow.
    func updateCachedViewControllerIfNeeded(for flow: Flow) -> FlowViewController? {
        guard let cached = cache[flow.id] else {
            return nil
        }

        let rendererInput = resolveRendererInput(for: flow)
        cached.updateFlowIfNeeded(rendererInput.flow)
        cached.updateArtifactTelemetryContext(rendererInput.telemetryContext)
        return cached
    }
    
    /// 2. Create view controller and insert into cache
    func createViewController(for flow: Flow) -> FlowViewController {
        let rendererInput = resolveRendererInput(for: flow)
        let viewController = rendererInput.adapter.makeViewController(
            flow: rendererInput.flow,
            archiveService: flowArchiver,
            fontStore: fontStore
        )
        viewController.updateArtifactTelemetryContext(rendererInput.telemetryContext)
        cache[flow.id] = viewController
        return viewController
    }
    
    /// 3. Remove a specific view controller from cache
    func removeViewController(for flowId: String) {
        cache.removeValue(forKey: flowId)
        loadedViewControllers.remove(flowId)
    }
    
    /// 4. Clear all cached view controllers
    func clearCache() {
        cache.removeAll()
        loadedViewControllers.removeAll()
    }
    
    // MARK: - Cache Statistics (for debugging)
    
    /// Get current cache size
    var cacheSize: Int {
        return cache.count
    }
    
    /// Get loaded view controller count
    var loadedCount: Int {
        return loadedViewControllers.count
    }

    private func resolveRendererInput(
        for flow: Flow
    ) -> (
        adapter: any FlowRendererAdapter,
        flow: Flow,
        telemetryContext: FlowArtifactTelemetryContext
    ) {
        let targetSelection = flow.remoteFlow.selectedTargetResult
        let selectedCompilerBackend = targetSelection.selectedCompilerBackend
        let resolution = rendererAdapterRegistry.resolve(for: selectedCompilerBackend)

        let normalizedFlow: Flow
        if resolution.didFallback {
            normalizedFlow = forceFlow(flow, toCompilerBackend: resolution.resolvedCompilerBackend)
        } else {
            normalizedFlow = flow
        }

        let telemetryContext = FlowArtifactTelemetryContext(
            targetCompilerBackend: selectedCompilerBackend ?? "legacy",
            targetBuildId: targetSelection.selectedBuildId,
            targetSelectionReason: targetSelection.reason.rawValue,
            adapterCompilerBackend: resolution.resolvedCompilerBackend,
            adapterFallback: resolution.didFallback
        )

        return (
            adapter: resolution.adapter,
            flow: resolution.adapter.prepareFlowForRendering(normalizedFlow),
            telemetryContext: telemetryContext
        )
    }

    private func forceFlow(
        _ flow: Flow,
        toCompilerBackend compilerBackend: String
    ) -> Flow {
        let source = flow.remoteFlow
        let backendTarget = source.selectedTarget(
            supportedCapabilities: RemoteFlow.supportedCapabilities,
            preferredCompilerBackends: [compilerBackend],
            renderableCompilerBackends: [compilerBackend]
        )
        let forcedBundle = backendTarget?.bundle ?? source.bundle

        let forcedRemoteFlow = RemoteFlow(
            id: source.id,
            bundle: forcedBundle,
            targets: nil,
            screens: source.screens,
            interactions: source.interactions,
            viewModels: source.viewModels,
            viewModelInstances: source.viewModelInstances,
            converters: source.converters
        )
        return Flow(remoteFlow: forcedRemoteFlow, products: flow.products)
    }
}
