import Foundation
import FactoryKit

/// Manages fetching and coordinating flow information with products
actor FlowStore {
    
    // MARK: - Properties
    
    // Client-side flow models keyed by composite hash
    // Contains both FlowDescription data and enriched product data
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
    
    /// Preload multiple flows with FlowDescription data (typically from warm caches)
    /// This enriches the FlowDescriptions with products and caches them
    func preloadFlows(_ descriptions: [FlowDescription]) async {
        LogDebug("Preloading \(descriptions.count) flows")
        
        // Process flows concurrently for better performance
        await withTaskGroup(of: Void.self) { group in
            for description in descriptions {
                group.addTask { [weak self] in
                    guard let self else { return }
                    
                    let key = FlowCacheKey(id: description.id)
                    
                    // Check if already cached and valid
                    if let cached = await self.flowModels[key], cached.isValid {
                        LogDebug("Flow already cached and valid: \(description.id)")
                        return
                    }
                    
                    // Enrich and cache the flow
                    do {
                        LogDebug("Preloading flow: \(description.id)")
                        let flow = try await self.enrichFlow(description)
                        await self.setFlow(flow, for: key)
                    } catch {
                        LogError("Failed to preload flow \(description.id): \(error)")
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
    
    /// Invalidate cached Flow model
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
                let description = try await self.api.fetchFlow(flowId: id)
                
                // Enrich and cache
                let flow = try await self.enrichFlow(description)
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
    
    private func enrichFlow(_ description: FlowDescription) async throws -> Flow {
        // Fetch products if the flow references any
        let products = try await fetchProducts(for: description)
        
        // Create and return the flow with fetched products
        let flow = Flow(
            description: description,
            products: products
        )
        
        LogDebug("Created flow with \(products.count) products: \(description.id)")
        return flow
    }
    
    private func fetchProducts(for description: FlowDescription) async throws -> [FlowProduct] {
        let productIds = extractProductIds(from: description)
        guard !productIds.isEmpty else {
            LogDebug("No products referenced in flow: \(description.id)")
            return []
        }
        
        let storeProducts = try await productService.fetchProducts(for: Set(productIds))
        
        let flowProducts = storeProducts.map { storeProduct in
            FlowProduct(
                id: storeProduct.id,
                name: storeProduct.displayName,
                price: storeProduct.displayPrice,
                period: mapSubscriptionPeriod(storeProduct.subscriptionPeriod)
            )
        }
        
        return flowProducts
    }
    
    private func extractProductIds(from description: FlowDescription) -> [String] {
        var ids = Set<String>()
        let viewModelsById = Dictionary(uniqueKeysWithValues: description.viewModels.map { ($0.id, $0) })
        
        for instance in description.viewModelInstances ?? [] {
            guard let viewModel = viewModelsById[instance.viewModelId] else { continue }
            collectProductIds(
                schema: viewModel.properties,
                values: instance.values,
                into: &ids
            )
        }
        
        return Array(ids)
    }
    
    private func collectProductIds(
        schema: [String: ViewModelProperty],
        values: [String: AnyCodable],
        into ids: inout Set<String>
    ) {
        for (key, property) in schema {
            let value = values[key]?.value
            switch property.type {
            case .product:
                if let productId = extractProductId(from: value) {
                    ids.insert(productId)
                }
            case .list:
                if let itemType = property.itemType, itemType.type == .product {
                    if let list = value as? [Any] {
                        for entry in list {
                            if let productId = extractProductId(from: entry) {
                                ids.insert(productId)
                            }
                        }
                    }
                } else if let itemType = property.itemType, itemType.type == .object,
                          let list = value as? [Any],
                          let schema = itemType.schema {
                    for entry in list {
                        if let dict = entry as? [String: AnyCodable] {
                            collectProductIds(schema: schema, values: dict, into: &ids)
                        } else if let dict = entry as? [String: Any] {
                            let wrapped = dict.mapValues { AnyCodable($0) }
                            collectProductIds(schema: schema, values: wrapped, into: &ids)
                        }
                    }
                }
            case .object:
                if let schema = property.schema {
                    if let dict = value as? [String: AnyCodable] {
                        collectProductIds(schema: schema, values: dict, into: &ids)
                    } else if let dict = value as? [String: Any] {
                        let wrapped = dict.mapValues { AnyCodable($0) }
                        collectProductIds(schema: schema, values: wrapped, into: &ids)
                    }
                }
            default:
                continue
            }
        }
    }
    
    private func extractProductId(from value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let dict = value as? [String: Any] {
            if let productId = dict["productId"] as? String {
                return productId
            }
            if let productId = dict["id"] as? String {
                return productId
            }
        }
        if let dict = value as? [String: AnyCodable] {
            if let productId = dict["productId"]?.value as? String {
                return productId
            }
            if let productId = dict["id"]?.value as? String {
                return productId
            }
        }
        return nil
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
