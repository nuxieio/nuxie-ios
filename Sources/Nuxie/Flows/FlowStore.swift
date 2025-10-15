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

    private var remoteFlows: [String: RemoteFlow] = [:]
    private var localeCatalog: [String: [String: RemoteFlowLocaleVariant]] = [:]
    
    // MARK: - Initialization
    
    init() {
        LogDebug("FlowStore initialized")
    }
    
    // MARK: - Cache Management
    
    /// Preload multiple flows with RemoteFlow data (typically from ProfileService)
    /// This enriches the RemoteFlows with products and caches them
    func preloadFlows(_ remoteFlows: [RemoteFlow]) async {
        LogDebug("Preloading \(remoteFlows.count) flows")
        for remoteFlow in remoteFlows {
            await preloadFlow(remoteFlow)
        }
        
        LogDebug("Completed preloading flows")
    }
    
    /// Remove flow from all caches
    func removeFlow(id: String) {
        flowModels = flowModels.filter { $0.key.id != id }
        pendingFetches = pendingFetches.filter { $0.key.id != id }
        remoteFlows[id] = nil
        localeCatalog[id] = nil
        LogDebug("Removed flow from cache: \(id)")
    }
    
    /// Invalidate cached Flow model (but keep RemoteFlow)
    func invalidateFlow(id: String) {
        flowModels = flowModels.filter { $0.key.id != id }
        pendingFetches = pendingFetches.filter { $0.key.id != id }
        LogDebug("Invalidated flow model: \(id)")
    }
    
    /// Clear all caches
    func clearCache() {
        flowModels.removeAll()
        pendingFetches.removeAll()
        remoteFlows.removeAll()
        localeCatalog.removeAll()
        LogDebug("Cleared all flow info caches")
    }
    
    // MARK: - Cache Access (Synchronous)
    
    /// Get cached Flow if available (synchronous, thread-safe)
    func getCachedFlow(id: String, locale: String? = nil) -> Flow? {
        let key = cacheKey(id: id, requestedLocale: locale)
        if let cached = flowModels[key], cached.isValid {
            return cached
        }
        if let locale,
           let base = remoteFlows[id],
           normalize(locale: locale) == normalize(locale: base.locale ?? base.defaultLocale) {
            let defaultKey = cacheKey(id: id, requestedLocale: nil)
            let cached = flowModels[defaultKey]
            if cached?.isValid == true {
                return cached
            }
        }
        return nil
    }
    
    // MARK: - Flow Fetching
    
    /// Get flow with products
    /// Checks cache first, then fetches from API if needed
    func flow(with id: String, locale: String? = nil) async throws -> Flow {
        let key = cacheKey(id: id, requestedLocale: locale)
        let normalizedLocale = key.locale
        
        if let pendingTask = pendingFetches[key] {
            LogDebug("Awaiting pending fetch for flow: \(id) (locale: \(normalizedLocale ?? "default"))")
            return try await pendingTask.value
        }
        
        if let cached = flowModels[key], cached.isValid {
            LogDebug("Returning cached flow model: \(id) (locale: \(normalizedLocale ?? "default"))")
            return cached
        }
        
        LogDebug("Starting new fetch for flow: \(id) (locale: \(normalizedLocale ?? "default"))")
        
        let task = Task<Flow, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            
            do {
                let remote = try await self.resolveRemoteFlow(
                    id: id,
                    requestedLocale: locale,
                    normalizedLocale: normalizedLocale
                )
                
                let flow = try await self.enrichFlow(remote)
                await self.setFlow(flow, for: key)
                await self.clearPending(for: key)
                return flow
            } catch {
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

    private func preloadFlow(_ remoteFlow: RemoteFlow) async {
        storeRemoteFlowMetadata(remoteFlow)

        let defaultKey = cacheKey(id: remoteFlow.id, requestedLocale: nil)
        let localeIdentifier = remoteFlow.locale ?? remoteFlow.defaultLocale
        let localeKey = localeIdentifier != nil ? cacheKey(id: remoteFlow.id, requestedLocale: localeIdentifier) : defaultKey

        if let cached = flowModels[localeKey], cached.isValid {
            LogDebug("Flow already cached and valid for locale \(localeIdentifier ?? "default"): \(remoteFlow.id)")
            return
        }

        if localeKey != defaultKey, let cachedDefault = flowModels[defaultKey], cachedDefault.isValid {
            LogDebug("Default flow already cached for \(remoteFlow.id)")
            return
        }

        do {
            LogDebug("Preloading flow: \(remoteFlow.id)")
            let flow = try await enrichFlow(remoteFlow)
            setFlow(flow, for: defaultKey)
            if localeKey != defaultKey {
                setFlow(flow, for: localeKey)
            }
        } catch {
            LogError("Failed to preload flow \(remoteFlow.id): \(error)")
        }
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

    private func storeRemoteFlowMetadata(_ remoteFlow: RemoteFlow) {
        let incomingLocale = normalize(locale: remoteFlow.locale ?? remoteFlow.defaultLocale)
        var shouldReplaceBase = true

        if let existing = remoteFlows[remoteFlow.id] {
            let existingLocale = normalize(locale: existing.locale ?? existing.defaultLocale)
            if let existingLocale, let incomingLocale, existingLocale != incomingLocale {
                shouldReplaceBase = false
            } else if existingLocale != nil, incomingLocale == nil {
                shouldReplaceBase = false
            }
        }

        if shouldReplaceBase || remoteFlows[remoteFlow.id] == nil {
            remoteFlows[remoteFlow.id] = remoteFlow
        }

        var entries = localeCatalog[remoteFlow.id] ?? [:]
        if !remoteFlow.availableLocales.isEmpty {
            for variant in remoteFlow.availableLocales {
                let normalized = normalize(locale: variant.locale) ?? variant.locale
                entries[normalized] = variant
                if normalized != variant.locale {
                    entries[variant.locale] = variant
                }
            }
        }
        localeCatalog[remoteFlow.id] = entries
    }

    private func normalize(locale: String?) -> String? {
        guard let locale = locale?.trimmingCharacters(in: .whitespacesAndNewlines), !locale.isEmpty else {
            return nil
        }
        return locale.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private func cacheKey(id: String, requestedLocale: String?) -> FlowCacheKey {
        let normalizedLocale = normalize(locale: requestedLocale)
        return FlowCacheKey(id: id, locale: normalizedLocale)
    }

    private func resolveRemoteFlow(
        id: String,
        requestedLocale: String?,
        normalizedLocale: String?
    ) async throws -> RemoteFlow {
        if let normalizedLocale, let existing = localeMatch(for: id, normalizedLocale: normalizedLocale) {
            return existing
        }
        if normalizedLocale == nil, let base = remoteFlows[id] {
            return base
        }

        let fetched = try await api.fetchFlow(flowId: id, locale: requestedLocale)
        storeRemoteFlowMetadata(fetched)

        if let normalizedLocale,
           let matched = localeMatch(for: id, normalizedLocale: normalizedLocale) {
            return matched
        }

        return fetched
    }

    private func localeMatch(for id: String, normalizedLocale: String) -> RemoteFlow? {
        guard let base = remoteFlows[id] else { return nil }
        if normalize(locale: base.locale ?? base.defaultLocale) == normalizedLocale {
            return base
        }
        guard let variants = localeCatalog[id],
              let variant = variants[normalizedLocale] else { return nil }

        let products = variant.products ?? base.products

        return RemoteFlow(
            id: base.id,
            name: variant.name ?? base.name,
            url: variant.url,
            products: products,
            manifest: variant.manifest,
            locale: variant.locale,
            defaultLocale: base.defaultLocale ?? base.locale,
            availableLocales: base.availableLocales
        )
    }
}
