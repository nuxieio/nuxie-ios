import Foundation
import FactoryKit

/// Protocol defining the FlowService interface
protocol FlowServiceProtocol: AnyObject {
    /// Prefetch flows - triggers fetch of flow data and preloads web archives
    func prefetchFlows(_ remoteFlows: [RemoteFlow])
    
    /// Remove flows from cache
    func removeFlows(_ flowIds: [String]) async

    /// Fetch flow data with products - does not create UI
    func fetchFlow(id: String) async throws -> Flow
    
    /// Get a view controller for a flow by ID
    @MainActor
    func viewController(for flowId: String) async throws -> FlowViewController

    /// Get a view controller for a flow by ID with a runtime delegate
    @MainActor
    func viewController(for flowId: String, runtimeDelegate: FlowRuntimeDelegate?) async throws -> FlowViewController
    
    /// Clear all cached data (flows and WebArchives)
    func clearCache() async
}

/// FlowService: Clean implementation following FLOW_REQUIREMENTS.md exactly
/// This is the umbrella container that orchestrates all flow subsystems
final class FlowService: FlowServiceProtocol {
    
    // MARK: - Subsystems
    
    private let flowStore: FlowStore
    private let flowArchiver: FlowArchiver
    private let fontStore: FontStore
    private let rendererAdapterRegistry: FlowRendererAdapterRegistry
    
    // Lazy initialization ensures this is created on MainActor when first accessed
    @MainActor
    private lazy var viewControllerCache: FlowViewControllerCache = {
        FlowViewControllerCache(
            flowArchiver: self.flowArchiver,
            fontStore: self.fontStore,
            rendererAdapterRegistry: self.rendererAdapterRegistry
        )
    }()
    
    // MARK: - Initialization
    
    internal init(
        flowArchiver: FlowArchiver? = nil,
        rendererAdapter: (any FlowRendererAdapter)? = nil,
        rendererAdapterRegistry: FlowRendererAdapterRegistry? = nil
    ) {
        self.flowStore = FlowStore()
        // Use injected flowArchiver or create new instance
        self.flowArchiver = flowArchiver ?? FlowArchiver()
        self.fontStore = FontStore()
        if let rendererAdapterRegistry {
            self.rendererAdapterRegistry = rendererAdapterRegistry
        } else if let rendererAdapter {
            self.rendererAdapterRegistry = FlowRendererAdapterRegistry(
                adapters: [rendererAdapter],
                defaultCompilerBackend: rendererAdapter.id
            )
        } else {
            self.rendererAdapterRegistry = FlowRendererAdapterRegistry.standard()
        }
        
        LogInfo("FlowService initialized with all subsystems (default renderer: \(self.rendererAdapterRegistry.defaultCompilerBackend))")
    }
    
    // MARK: - Flow Lifecycle Management (called by ProfileService)
    
    /// Prefetch flows - triggers fetch of flow data and preloads web archives
    func prefetchFlows(_ remoteFlows: [RemoteFlow]) {
        LogInfo("Prefetching \(remoteFlows.count) flows")
        
        Task {
            let fontEntries = remoteFlows.flatMap { $0.fontManifest?.fonts ?? [] }
            if !fontEntries.isEmpty {
                await fontStore.prefetchFonts(fontEntries)
            }
            // Preload all flows with products into cache (concurrent)
            await flowStore.preloadFlows(remoteFlows)
            
            // Preload web archives for all flows
            for remoteFlow in remoteFlows {
                let flow = Flow(remoteFlow: remoteFlow, products: [])
                await flowArchiver.preloadArchive(for: flow)
            }
        }
    }
    
    /// Remove flows from cache
    func removeFlows(_ flowIds: [String]) async {
        LogInfo("Removing \(flowIds.count) flows")
        
        await withTaskGroup(of: Void.self) { group in
            for flowId in flowIds {
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    // Remove from all caches
                    await self.flowStore.removeFlow(id: flowId)
                    await self.flowArchiver.removeArchive(for: flowId)
                }
            }
        }
        
        // View controller cache is MainActor-isolated
        await MainActor.run {
            for flowId in flowIds {
                viewControllerCache.removeViewController(for: flowId)
            }
        }
    }
    
    // MARK: - Data Operations (can be called from any thread)
    
    /// Fetch flow data with products - does not create UI
    func fetchFlow(id: String) async throws -> Flow {
        // This can be called from any thread
        return try await flowStore.flow(with: id)
    }
        
    // MARK: - UI Operations (MUST be called from main thread)
    
    /// Get view controller for flow - dead simple
    /// Path A: Cache hit - update if needed and return
    /// Path B: Cache miss - create new one and return it
    /// Must be called from main thread as it creates UIViewController
    @MainActor
    func viewController(for flow: Flow) -> FlowViewController {
        // Path A: Check cache first
        if let cached = viewControllerCache.getCachedViewController(for: flow.id) {
            LogDebug("Cache hit: returning cached view controller for flow: \(flow.id)")
            
            // Update the cached view controller with the latest flow data
            // This will check if content changed and reload if necessary
            cached.updateFlowIfNeeded(flow)
            
            return cached
        }
        
        // Path B: Create new view controller and cache it
        LogDebug("Cache miss: creating new view controller for flow: \(flow.id)")
        let viewController = viewControllerCache.createViewController(for: flow)
        return viewController
    }
    
    /// Get view controller for flow by ID - fetches flow first then creates view controller
    @MainActor
    func viewController(for flowId: String) async throws -> FlowViewController {
        // Fetch the flow data first
        let flow = try await fetchFlow(id: flowId)
        
        // Then get or create the view controller
        return viewController(for: flow)
    }

    @MainActor
    func viewController(for flowId: String, runtimeDelegate: FlowRuntimeDelegate?) async throws -> FlowViewController {
        let controller = try await viewController(for: flowId)
        controller.runtimeDelegate = runtimeDelegate
        return controller
    }
    
    // MARK: - Cache Management
    
    /// Clear all cached data (flows and WebArchives)
    func clearCache() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await self?.flowStore.clearCache()
            }
            group.addTask { [weak self] in
                await self?.flowArchiver.clearAllArchives()
            }
            group.addTask { [weak self] in
                await self?.fontStore.clearCache()
            }
        }
        
        // View controller cache is MainActor-isolated
        await MainActor.run {
            viewControllerCache.clearCache()
        }
        
        LogInfo("Cleared all flow caches")
    }
    
    /// Clear only view controller cache
    @MainActor
    func clearViewControllerCache() {
        viewControllerCache.clearCache()
        LogInfo("Cleared view controller cache")
    }
}

// MARK: - Flow Errors

enum FlowError: LocalizedError {
    case flowNotFound(String)
    case invalidManifest
    case downloadFailed
    case noProductsConfigured
    case productsUnavailable
    case configurationFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .flowNotFound(let id):
            return "Flow not found: \(id)"
        case .invalidManifest:
            return "Invalid manifest data"
        case .downloadFailed:
            return "Failed to download flow assets"
        case .noProductsConfigured:
            return "No products configured for flow"
        case .productsUnavailable:
            return "Products unavailable from StoreKit"
        case .configurationFailed(let error):
            return "Flow configuration failed: \(error.localizedDescription)"
        }
    }
}
