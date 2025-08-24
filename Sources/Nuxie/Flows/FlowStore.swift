import Foundation
import FactoryKit

/// Manages fetching and coordinating flow information with products
actor FlowStore {
    
    // MARK: - Properties
    
    // Client-side flow models keyed by composite hash
    // Contains both RemoteFlow data and enriched product data
    private var flowModels: [FlowCacheKey: Flow] = [:]
    
    // Deduplication of concurrent requests
    private var pendingFetches: [FlowCacheKey: Task<Flow, Error>] = [:]
    
    @Injected(\.nuxieApi) private var api: NuxieApiProtocol
    @Injected(\.productService) private var productService: ProductService
    
    // MARK: - Initialization
    
    init() {
        LogDebug("FlowStore initialized")
    }
    
    // MARK: - Cache Management
    
    /// Preload multiple flows with RemoteFlow data (typically from ProfileService)
    /// This enriches the RemoteFlows with products and caches them
    func preloadFlows(_ remoteFlows: [RemoteFlow]) async {
        LogDebug("Preloading \(remoteFlows.count) flows")
        
        // Process flows concurrently for better performance
        await withTaskGroup(of: Void.self) { group in
            for remoteFlow in remoteFlows {
                group.addTask { [weak self] in
                    guard let self else { return }
                    
                    let key = FlowCacheKey(id: remoteFlow.id)
                    
                    // Check if already cached and valid
                    if let cached = await self.flowModels[key], cached.isValid {
                        LogDebug("Flow already cached and valid: \(remoteFlow.id)")
                        return
                    }
                    
                    // Enrich and cache the flow
                    do {
                        LogDebug("Preloading flow: \(remoteFlow.id)")
                        let flow = try await self.enrichFlow(remoteFlow)
                        await self.setFlow(flow, for: key)
                    } catch {
                        LogError("Failed to preload flow \(remoteFlow.id): \(error)")
                    }
                }
            }
        }
        
        LogDebug("Completed preloading flows")
    }
    
    /// Remove flow from all caches
    func removeFlow(id: String) {
        // Remove all variants of this flow
        flowModels = flowModels.filter { $0.key.id != id }
        LogDebug("Removed flow from cache: \(id)")
    }
    
    /// Invalidate cached Flow model (but keep RemoteFlow)
    func invalidateFlow(id: String) {
        // Remove all variants of this flow
        flowModels = flowModels.filter { $0.key.id != id }
        LogDebug("Invalidated flow model: \(id)")
    }
    
    /// Clear all caches
    func clearCache() {
        flowModels.removeAll()
        pendingFetches.removeAll()
        LogDebug("Cleared all flow info caches")
    }
    
    // MARK: - Cache Access (Synchronous)
    
    /// Get cached Flow if available (synchronous, thread-safe)
    func getCachedFlow(id: String) -> Flow? {
        let key = FlowCacheKey(id: id)
        let cached = flowModels[key]
        return cached?.isValid == true ? cached : nil
    }
    
    // MARK: - Flow Fetching
    
    /// Get flow with products
    /// Checks cache first, then fetches from API if needed
    func flow(with id: String) async throws -> Flow {
        let key = FlowCacheKey(id: id)
        
        // Check for pending fetch - await existing task
        if let pendingTask = pendingFetches[key] {
            LogDebug("Awaiting pending fetch for flow: \(id)")
            return try await pendingTask.value
        }
        
        // Check cached model
        if let cached = flowModels[key], cached.isValid {
            LogDebug("Returning cached flow model: \(id)")
            return cached
        }
        
        // Start new fetch with deduplication
        LogDebug("Starting new fetch for flow: \(id)")
        
        let task = Task<Flow, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            
            do {
                // Fetch from API
                LogInfo("Fetching flow from API: \(id)")
                let remote = try await self.api.fetchFlow(flowId: id)
                
                // Enrich and cache
                let flow = try await self.enrichFlow(remote)
                await self.setFlow(flow, for: key)
                
                // Clear pending after successful completion
                await self.clearPending(for: key)
                return flow
            } catch {
                // Clear pending on error as well
                await self.clearPending(for: key)
                throw error
            }
        }
        
        pendingFetches[key] = task
        return try await task.value
    }
    
    // MARK: - Private Methods
    
    private func clearPending(for key: FlowCacheKey) {
        pendingFetches[key] = nil
    }
    
    private func setFlow(_ flow: Flow, for key: FlowCacheKey) {
        flowModels[key] = flow
    }
    
    private func enrichFlow(_ remoteFlow: RemoteFlow) async throws -> Flow {
        // Fetch products if the flow has any defined
        let products = try await fetchProducts(for: remoteFlow)
        
        // Create and return the flow with fetched products
        let flow = Flow(
            remoteFlow: remoteFlow,
            products: products
        )
        
        LogDebug("Created flow with \(products.count) products: \(remoteFlow.id)")
        return flow
    }
    
    private func fetchProducts(for remoteFlow: RemoteFlow) async throws -> [FlowProduct] {
        // Early return if no products defined in the flow
        guard !remoteFlow.products.isEmpty else {
            LogDebug("No products defined for flow: \(remoteFlow.id)")
            return []
        }
        
        // Use ProductService to fetch products for this flow
        let flowProducts = try await productService.fetchProducts(for: [remoteFlow])
        
        guard let storeProducts = flowProducts[remoteFlow.id] else {
            LogWarning("ProductService returned no products for flow: \(remoteFlow.id)")
            return []
        }
        
        // Map to flow products with StoreKit data
        let flowProductList = storeProducts.compactMap { storeProduct -> FlowProduct? in
            guard let flowProductMetadata = remoteFlow.products.first(where: { $0.extId == storeProduct.id }) else {
                LogWarning("Product \(storeProduct.id) not found in flow manifest")
                return nil
            }
            
            // Get period directly from StoreKit subscription info
            let period = mapSubscriptionPeriod(storeProduct.subscriptionPeriod)
            
            return FlowProduct(
                id: storeProduct.id,
                name: storeProduct.displayName,
                price: storeProduct.displayPrice,
                period: period
            )
        }
        
        return flowProductList
    }
    
    private func mapSubscriptionPeriod(_ subscriptionPeriod: SubscriptionPeriod?) -> ProductPeriod? {
        guard let period = subscriptionPeriod else { return nil }
        
        // Map from StoreKit subscription period to our ProductPeriod enum
        switch period.unit {
        case .week where period.value == 1:
            return .week
        case .month where period.value == 1:
            return .month
        case .year where period.value == 1:
            return .year
        default:
            // For non-standard periods, we'll need to decide how to handle them
            // For now, map to closest standard period
            switch period.unit {
            case .week:
                return .week
            case .month:
                return .month
            case .year:
                return .year
            case .day:
                // No daily period in our enum, treat as weekly
                return .week
            }
        }
    }
}