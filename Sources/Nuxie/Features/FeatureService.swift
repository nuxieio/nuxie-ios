import FactoryKit
import Foundation

/// Protocol defining the FeatureService interface
protocol FeatureServiceProtocol: AnyObject {
    /// Check feature access from cache (instant, non-blocking)
    func getCached(featureId: String, entityId: String?) async -> FeatureAccess?

    /// Check feature access via real-time API call
    func check(
        featureId: String,
        requiredBalance: Int?,
        entityId: String?
    ) async throws -> FeatureCheckResult

    /// Check feature access with cache-first strategy
    func checkWithCache(
        featureId: String,
        requiredBalance: Int?,
        entityId: String?,
        forceRefresh: Bool
    ) async throws -> FeatureAccess

    /// Clear all feature cache
    func clearCache() async

    /// Handle user identity change
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async
}

/// Manages feature access checking with caching
/// Uses ProfileService's cached features as primary source, with real-time API fallback
internal actor FeatureService: FeatureServiceProtocol {

    // MARK: - Properties

    // In-memory cache for real-time check results: (featureId:entityId) -> (result, cachedAt)
    private var realTimeCache: [String: (result: FeatureCheckResult, cachedAt: Date)] = [:]

    @Injected(\.nuxieApi) private var api: NuxieApiProtocol
    @Injected(\.identityService) private var identityService: IdentityServiceProtocol
    @Injected(\.profileService) private var profileService: ProfileServiceProtocol
    @Injected(\.dateProvider) private var dateProvider: DateProviderProtocol
    @Injected(\.sdkConfiguration) private var config: NuxieConfiguration

    // Cache TTL for real-time results (from configuration)
    private var realTimeCacheTTL: TimeInterval {
        config.featureCacheTTL
    }

    // MARK: - Init

    init() {}

    // MARK: - Public Methods

    /// Get cached feature access (instant, non-blocking)
    /// First checks profile cache, then real-time cache
    func getCached(featureId: String, entityId: String?) async -> FeatureAccess? {
        let distinctId = identityService.getDistinctId()

        // 1. Try profile cache first (features from profile response)
        if let profile = await profileService.getCachedProfile(distinctId: distinctId),
           let features = profile.features,
           let feature = features.first(where: { $0.id == featureId }) {
            // For entity-based features, check entity balance
            if let entityId = entityId, let entities = feature.entities {
                if let entityBalance = entities[entityId] {
                    return FeatureAccess(
                        from: Feature(
                            id: feature.id,
                            type: feature.type,
                            balance: entityBalance.balance,
                            unlimited: feature.unlimited,
                            nextResetAt: feature.nextResetAt,
                            interval: feature.interval,
                            entities: nil
                        )
                    )
                }
                // Entity not in cache - return denied instead of nil
                // This allows callers to distinguish "feature exists but entity denied"
                // from "not cached at all"
                return FeatureAccess.notFound
            }
            return FeatureAccess(from: feature)
        }

        // 2. Try real-time cache
        let cacheKey = makeCacheKey(featureId: featureId, entityId: entityId)
        if let cached = realTimeCache[cacheKey] {
            let age = dateProvider.timeIntervalSince(cached.cachedAt)
            if age < realTimeCacheTTL {
                return FeatureAccess(from: cached.result)
            }
        }

        return nil
    }

    /// Check feature via real-time API (always fresh)
    func check(
        featureId: String,
        requiredBalance: Int? = nil,
        entityId: String? = nil
    ) async throws -> FeatureCheckResult {
        let customerId = identityService.getDistinctId()

        let result = try await api.checkFeature(
            customerId: customerId,
            featureId: featureId,
            requiredBalance: requiredBalance,
            entityId: entityId
        )

        // Cache the result
        let cacheKey = makeCacheKey(featureId: featureId, entityId: entityId)
        realTimeCache[cacheKey] = (result: result, cachedAt: dateProvider.now())

        return result
    }

    /// Check feature with cache-first strategy
    func checkWithCache(
        featureId: String,
        requiredBalance: Int? = nil,
        entityId: String? = nil,
        forceRefresh: Bool = false
    ) async throws -> FeatureAccess {
        if !forceRefresh {
            // Try cache first
            if let cached = await getCached(featureId: featureId, entityId: entityId) {
                // For boolean features, cache is good enough
                if cached.type == .boolean {
                    return cached
                }

                // For metered features, check if we need to verify balance
                let required = requiredBalance ?? 1
                if cached.unlimited || (cached.balance ?? 0) >= required {
                    return cached
                }

                // Balance might be insufficient, do real-time check
            }
        }

        // No valid cache or force refresh, fetch from network
        let result = try await check(
            featureId: featureId,
            requiredBalance: requiredBalance,
            entityId: entityId
        )

        return FeatureAccess(from: result)
    }

    /// Clear all cached data
    func clearCache() async {
        realTimeCache.removeAll()
        LogInfo("Feature cache cleared")
    }

    /// Handle user identity change
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
        await clearCache()
        LogInfo("Feature cache cleared due to user change")
    }

    // MARK: - Private Methods

    private func makeCacheKey(featureId: String, entityId: String?) -> String {
        if let entityId = entityId {
            return "\(featureId):\(entityId)"
        }
        return featureId
    }
}
