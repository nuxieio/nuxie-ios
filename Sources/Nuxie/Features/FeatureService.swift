import FactoryKit
import Foundation

/// Protocol defining the FeatureService interface
public protocol FeatureServiceProtocol: AnyObject {
    /// Check feature access from cache (instant, non-blocking)
    func getCached(featureId: String, entityId: String?) async -> FeatureAccess?

    /// Get all cached features from profile
    func getAllCached() async -> [String: FeatureAccess]

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

    /// Sync FeatureInfo from profile cache (call after profile refresh)
    func syncFeatureInfo() async

    /// Update feature cache from purchase response
    func updateFromPurchase(_ features: [PurchaseFeature]) async
}

/// Manages effective feature state across profile snapshots, real-time checks, and local updates.
internal actor FeatureService: FeatureServiceProtocol {

    private struct FeatureCacheKey: Hashable {
        let featureId: String
        let entityId: String?
    }

    private enum FeatureRecordSource {
        case profileSnapshot
        case realtimeCheck
        case purchaseSync
        case optimisticUsage
        case confirmedUsage

        var usesTTL: Bool {
            switch self {
            case .realtimeCheck, .purchaseSync:
                return true
            case .profileSnapshot, .optimisticUsage, .confirmedUsage:
                return false
            }
        }

        var isLocalUsage: Bool {
            switch self {
            case .optimisticUsage, .confirmedUsage:
                return true
            case .profileSnapshot, .realtimeCheck, .purchaseSync:
                return false
            }
        }
    }

    private struct CachedFeatureValue {
        let type: FeatureType
        let unlimited: Bool
        let balance: Int?
        let allowed: Bool

        init(feature: Feature, balance: Int? = nil) {
            self.type = feature.type
            self.unlimited = feature.unlimited
            self.balance = balance ?? feature.balance
            self.allowed = Self.defaultAllowed(
                type: feature.type,
                unlimited: feature.unlimited,
                balance: balance ?? feature.balance
            )
        }

        init(result: FeatureCheckResult) {
            self.type = result.type
            self.unlimited = result.unlimited
            self.balance = result.balance
            self.allowed = result.allowed
        }

        init(purchase: PurchaseFeature) {
            self.type = purchase.type
            self.unlimited = purchase.unlimited
            self.balance = purchase.balance
            self.allowed = purchase.allowed
        }

        init(access: FeatureAccess) {
            self.type = access.type
            self.unlimited = access.unlimited
            self.balance = access.balance
            self.allowed = access.allowed
        }

        func access(requiredBalance: Int?) -> FeatureAccess {
            switch type {
            case .boolean:
                return FeatureAccess(
                    allowed: allowed,
                    unlimited: unlimited,
                    balance: balance,
                    type: type
                )
            case .metered, .creditSystem:
                if unlimited {
                    return FeatureAccess(
                        allowed: true,
                        unlimited: true,
                        balance: balance,
                        type: type
                    )
                }

                if let balance {
                    return FeatureAccess(
                        allowed: balance >= (requiredBalance ?? 1),
                        unlimited: false,
                        balance: balance,
                        type: type
                    )
                }

                return FeatureAccess(
                    allowed: allowed,
                    unlimited: unlimited,
                    balance: nil,
                    type: type
                )
            }
        }

        func updatingBalance(_ newBalance: Int) -> CachedFeatureValue {
            CachedFeatureValue(
                type: type,
                unlimited: unlimited,
                balance: newBalance,
                allowed: unlimited || newBalance > 0
            )
        }

        private static func defaultAllowed(
            type: FeatureType,
            unlimited: Bool,
            balance: Int?
        ) -> Bool {
            switch type {
            case .boolean:
                return true
            case .metered, .creditSystem:
                return unlimited || (balance ?? 0) > 0
            }
        }

        private init(type: FeatureType, unlimited: Bool, balance: Int?, allowed: Bool) {
            self.type = type
            self.unlimited = unlimited
            self.balance = balance
            self.allowed = allowed
        }
    }

    private struct CachedFeatureRecord {
        let value: CachedFeatureValue
        let source: FeatureRecordSource
        let cachedAt: Date

        func isFresh(now: Date, ttl: TimeInterval) -> Bool {
            guard source.usesTTL else { return true }
            return now.timeIntervalSince(cachedAt) < ttl
        }
    }

    private struct StoredFeatureState {
        var snapshot: CachedFeatureRecord?
        var override: CachedFeatureRecord?

        var isEmpty: Bool {
            snapshot == nil && override == nil
        }
    }

    // MARK: - Properties

    private var featureStates: [FeatureCacheKey: StoredFeatureState] = [:]
    private var entityBackedFeatureIds: Set<String> = []
    private var syncedProfileDistinctId: String?

    @Injected(\.nuxieApi) private var api: NuxieApiProtocol
    @Injected(\.identityService) private var identityService: IdentityServiceProtocol
    @Injected(\.profileService) private var profileService: ProfileServiceProtocol
    @Injected(\.dateProvider) private var dateProvider: DateProviderProtocol
    @Injected(\.sdkConfiguration) private var config: NuxieConfiguration
    @Injected(\.featureInfo) private var featureInfo: FeatureInfo

    private var realTimeCacheTTL: TimeInterval {
        config.featureCacheTTL
    }

    // MARK: - Init

    init() {}

    // MARK: - Public Methods

    func getCached(featureId: String, entityId: String?) async -> FeatureAccess? {
        await cachedAccess(
            featureId: featureId,
            requiredBalance: nil,
            entityId: entityId
        )
    }

    func getAllCached() async -> [String: FeatureAccess] {
        await ensureProfileSnapshotLoaded()
        pruneExpiredOverrides()
        return projectPublicFeatures()
    }

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

        await applyRealtimeCheck(result, entityId: entityId)
        return result
    }

    func checkWithCache(
        featureId: String,
        requiredBalance: Int? = nil,
        entityId: String? = nil,
        forceRefresh: Bool = false
    ) async throws -> FeatureAccess {
        if !forceRefresh {
            if let cached = await cachedAccess(
                featureId: featureId,
                requiredBalance: requiredBalance,
                entityId: entityId
            ) {
                if cached.type == .boolean {
                    return cached
                }

                let required = requiredBalance ?? 1
                if cached.unlimited || (cached.balance ?? 0) >= required {
                    return cached
                }
            }
        }

        let result = try await check(
            featureId: featureId,
            requiredBalance: requiredBalance,
            entityId: entityId
        )

        return FeatureAccess(from: result)
    }

    func clearCache() async {
        featureStates.removeAll()
        entityBackedFeatureIds.removeAll()
        syncedProfileDistinctId = nil
        await publishProjection()
        LogInfo("Feature cache cleared")
    }

    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
        featureStates.removeAll()
        entityBackedFeatureIds.removeAll()
        syncedProfileDistinctId = nil
        await synchronizeProfileSnapshotFromCache(distinctId: newDistinctId, publish: true)
        LogInfo("Feature cache cleared due to user change")
    }

    func syncFeatureInfo() async {
        await synchronizeProfileSnapshotFromCache(publish: true)
    }

    func updateFromPurchase(_ features: [PurchaseFeature]) async {
        LogInfo("Updating feature cache from purchase response with \(features.count) features")
        await applyPurchaseSync(features)
        LogInfo("Feature cache updated from purchase")
    }

    // MARK: - Internal Mutation APIs

    func applyProfileSnapshot(_ profile: ProfileResponse?, distinctId: String) async {
        applyProfileSnapshot(profile, distinctId: distinctId, publish: true)
        await publishProjection()
    }

    func applyRealtimeCheck(_ result: FeatureCheckResult, entityId: String?) async {
        pruneExpiredOverrides()
        let cacheKey = makeCacheKey(featureId: result.featureId, entityId: entityId)
        let record = CachedFeatureRecord(
            value: CachedFeatureValue(result: result),
            source: .realtimeCheck,
            cachedAt: dateProvider.now()
        )
        var state = featureStates[cacheKey] ?? StoredFeatureState()
        state.override = record
        featureStates[cacheKey] = state
        await publishProjection()
    }

    func applyPurchaseSync(_ features: [PurchaseFeature]) async {
        pruneExpiredOverrides()
        let cachedAt = dateProvider.now()

        for purchaseFeature in features {
            let cacheKey = makeCacheKey(featureId: purchaseFeature.id, entityId: nil)
            let record = CachedFeatureRecord(
                value: CachedFeatureValue(purchase: purchaseFeature),
                source: .purchaseSync,
                cachedAt: cachedAt
            )
            var state = featureStates[cacheKey] ?? StoredFeatureState()
            state.override = record
            featureStates[cacheKey] = state
        }

        await publishProjection()
    }

    func applyOptimisticUsage(featureId: String, amount: Int, entityId: String?) async {
        guard amount > 0 else { return }
        await ensureProfileSnapshotLoaded()
        pruneExpiredOverrides()

        // Preserve current behavior: entity-scoped usage updates the public non-entity view.
        let projectionKey = makeCacheKey(featureId: featureId, entityId: nil)
        guard let current = resolveAccess(
            featureId: featureId,
            requiredBalance: nil,
            entityId: nil
        ), !current.unlimited else {
            return
        }

        let newBalance = max(0, (current.balance ?? 0) - amount)
        let record = CachedFeatureRecord(
            value: CachedFeatureValue(access: current).updatingBalance(newBalance),
            source: .optimisticUsage,
            cachedAt: dateProvider.now()
        )

        var state = featureStates[projectionKey] ?? StoredFeatureState()
        state.override = record
        featureStates[projectionKey] = state
        await publishProjection()
    }

    func applyConfirmedUsage(featureId: String, remainingBalance: Int, entityId: String?) async {
        await ensureProfileSnapshotLoaded()
        pruneExpiredOverrides()

        // Preserve current behavior: entity-scoped confirmations update the public non-entity view.
        let projectionKey = makeCacheKey(featureId: featureId, entityId: nil)
        guard let current = resolveAccess(
            featureId: featureId,
            requiredBalance: nil,
            entityId: nil
        ) else {
            return
        }

        let record = CachedFeatureRecord(
            value: CachedFeatureValue(access: current).updatingBalance(max(0, remainingBalance)),
            source: .confirmedUsage,
            cachedAt: dateProvider.now()
        )

        var state = featureStates[projectionKey] ?? StoredFeatureState()
        state.override = record
        featureStates[projectionKey] = state
        await publishProjection()
    }

    // MARK: - Private Helpers

    private func cachedAccess(
        featureId: String,
        requiredBalance: Int?,
        entityId: String?
    ) async -> FeatureAccess? {
        await ensureProfileSnapshotLoaded()
        pruneExpiredOverrides()
        return resolveAccess(
            featureId: featureId,
            requiredBalance: requiredBalance,
            entityId: entityId
        )
    }

    private func ensureProfileSnapshotLoaded() async {
        let distinctId = identityService.getDistinctId()
        guard syncedProfileDistinctId != distinctId else { return }
        await synchronizeProfileSnapshotFromCache(distinctId: distinctId, publish: false)
    }

    private func synchronizeProfileSnapshotFromCache(
        distinctId: String? = nil,
        publish: Bool
    ) async {
        let distinctId = distinctId ?? identityService.getDistinctId()
        let profile = await profileService.getCachedProfile(distinctId: distinctId)
        applyProfileSnapshot(profile, distinctId: distinctId, publish: publish)
        if publish {
            await publishProjection()
        }
    }

    private func applyProfileSnapshot(
        _ profile: ProfileResponse?,
        distinctId: String,
        publish: Bool
    ) {
        if syncedProfileDistinctId != distinctId {
            featureStates.removeAll()
        }

        syncedProfileDistinctId = distinctId
        entityBackedFeatureIds.removeAll()

        for key in Array(featureStates.keys) {
            var state = featureStates[key] ?? StoredFeatureState()
            state.snapshot = nil
            if let override = state.override, override.source.isLocalUsage {
                state.override = nil
            }
            featureStates[key] = state
        }

        guard let features = profile?.features else {
            compactState()
            return
        }

        let snapshotTime = dateProvider.now()
        for feature in features {
            let rootKey = makeCacheKey(featureId: feature.id, entityId: nil)
            let rootRecord = CachedFeatureRecord(
                value: CachedFeatureValue(feature: feature),
                source: .profileSnapshot,
                cachedAt: snapshotTime
            )

            var rootState = featureStates[rootKey] ?? StoredFeatureState()
            rootState.snapshot = rootRecord
            featureStates[rootKey] = rootState

            if let entities = feature.entities {
                entityBackedFeatureIds.insert(feature.id)

                for (entityId, entityBalance) in entities {
                    let entityKey = makeCacheKey(featureId: feature.id, entityId: entityId)
                    let entityRecord = CachedFeatureRecord(
                        value: CachedFeatureValue(feature: feature, balance: entityBalance.balance),
                        source: .profileSnapshot,
                        cachedAt: snapshotTime
                    )

                    var entityState = featureStates[entityKey] ?? StoredFeatureState()
                    entityState.snapshot = entityRecord
                    featureStates[entityKey] = entityState
                }
            }
        }

        compactState()

        if publish {
            // Marker to make intent clear at call sites. Actual publishing happens after state mutation.
        }
    }

    private func makeCacheKey(featureId: String, entityId: String?) -> FeatureCacheKey {
        FeatureCacheKey(featureId: featureId, entityId: entityId)
    }

    private func resolveAccess(
        featureId: String,
        requiredBalance: Int?,
        entityId: String?
    ) -> FeatureAccess? {
        if let entityId {
            let entityKey = makeCacheKey(featureId: featureId, entityId: entityId)
            if let entityAccess = resolvedAccess(for: entityKey, requiredBalance: requiredBalance) {
                return entityAccess
            }

            if entityBackedFeatureIds.contains(featureId) {
                return FeatureAccess.notFound
            }
        }

        let rootKey = makeCacheKey(featureId: featureId, entityId: nil)
        return resolvedAccess(for: rootKey, requiredBalance: requiredBalance)
    }

    private func resolvedAccess(
        for key: FeatureCacheKey,
        requiredBalance: Int?
    ) -> FeatureAccess? {
        guard let state = featureStates[key] else { return nil }
        let now = dateProvider.now()

        if let override = state.override, override.isFresh(now: now, ttl: realTimeCacheTTL) {
            return override.value.access(requiredBalance: requiredBalance)
        }

        if let snapshot = state.snapshot {
            return snapshot.value.access(requiredBalance: requiredBalance)
        }

        return nil
    }

    private func projectPublicFeatures() -> [String: FeatureAccess] {
        var result: [String: FeatureAccess] = [:]

        for key in featureStates.keys where key.entityId == nil {
            if let access = resolvedAccess(for: key, requiredBalance: nil) {
                result[key.featureId] = access
            }
        }

        return result
    }

    private func pruneExpiredOverrides() {
        let now = dateProvider.now()

        for key in Array(featureStates.keys) {
            guard var state = featureStates[key], let override = state.override else { continue }
            if !override.isFresh(now: now, ttl: realTimeCacheTTL) {
                state.override = nil
                featureStates[key] = state
            }
        }

        compactState()
    }

    private func compactState() {
        for (key, state) in Array(featureStates) where state.isEmpty {
            featureStates.removeValue(forKey: key)
        }
    }

    private func publishProjection() async {
        pruneExpiredOverrides()
        let info = featureInfo
        let allFeatures = projectPublicFeatures()
        await MainActor.run {
            info.update(allFeatures)
        }
    }
}
