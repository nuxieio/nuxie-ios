import FactoryKit
import Foundation

/// Protocol defining the ProfileService interface
protocol ProfileServiceProtocol: AnyObject {
    /// Fetch profile with cache-first strategy
    func fetchProfile(distinctId: String) async throws -> ProfileResponse

    /// Get cached profile if available and valid
    func getCachedProfile(distinctId: String) async -> ProfileResponse?

    /// Clear cached profile for user
    func clearCache(distinctId: String) async

    /// Clear all cached profiles
    func clearAllCache() async

    /// Clean up expired profiles
    @discardableResult
    func cleanupExpired() async -> Int

    /// Get cache statistics
    func getCacheStats() async -> [String: Any]

    /// Refetch profile from server using cache-first strategy
    func refetchProfile() async throws -> ProfileResponse
    
    /// Handle user change - clear old cache and load new
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async

    func onAppBecameActive() async
}

/// Wrapper for cached profile data with metadata
public struct CachedProfile: Codable {
    public let response: ProfileResponse
    public let distinctId: String
    public let cachedAt: Date
    
    public init(response: ProfileResponse, distinctId: String, cachedAt: Date) {
        self.response = response
        self.distinctId = distinctId
        self.cachedAt = cachedAt
    }
}

/// Profile manager for user profile data with memory-first caching and disk backup
internal actor ProfileService: ProfileServiceProtocol {

    // MARK: - Properties

    // Memory cache for instant access
    private var cachedProfile: CachedProfile?
    
    // Disk cache for persistence
    private let diskCache: any CachedProfileStore
    
    // Background refresh timer
    private var refreshTimer: Task<Void, Never>?

    @Injected(\.identityService) private var identityService: IdentityServiceProtocol
    @Injected(\.nuxieApi) private var api: NuxieApiProtocol
    @Injected(\.segmentService) private var segmentService: SegmentServiceProtocol
    // Note: journeyService is resolved lazily in resumeActiveJourneys to avoid circular dependency
    // (JourneyService → ProfileService → JourneyService)
    @Injected(\.dateProvider) private var dateProvider: DateProviderProtocol
    @Injected(\.sleepProvider) private var sleepProvider: SleepProviderProtocol

    // Cache policy
    private let freshCacheAge: TimeInterval = 5 * 60      // 5 min - return immediately
    private let staleCacheAge: TimeInterval = 24 * 60 * 60 // 24h - return with background refresh
    private let refreshInterval: TimeInterval = 30 * 60    // 30 min - periodic refresh

    // MARK: - Init

    // Production initializer
    init(customStoragePath: URL? = nil) {
        // Determine the base directory
        let baseDir: URL
        if let customPath = customStoragePath {
            // Use custom path with nuxie subdirectory for profiles
            baseDir = customPath.appendingPathComponent("nuxie", isDirectory: true)
        } else {
            // Use default Caches/nuxie directory for profile cache
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            baseDir = caches.appendingPathComponent("nuxie", isDirectory: true)
        }
        
        let opts = DiskCacheOptions(
            baseDirectory: baseDir,
            subdirectory: "profiles",
            defaultTTL: staleCacheAge,
            maxTotalBytes: 10 * 1024 * 1024,  // 10 MB cap (only one profile)
            excludeFromBackup: true,
            fileProtection: .completeUntilFirstUserAuthentication
        )
        do {
            let disk = try DiskCache<CachedProfile>(options: opts)
            self.diskCache = disk
            
            // Load from disk into memory on startup
            Task { [weak self] in
                await self?.loadFromDisk()
            }
        } catch {
            LogWarning("Failed to initialize DiskCache<CachedProfile>: \(error)")
            fatalError("ProfileService requires disk cache")
        }
    }
    
    // Test initializer
    internal init(cache: any CachedProfileStore) {
        self.diskCache = cache
        
        // Load from disk into memory on startup
        Task { [weak self] in
            await self?.loadFromDisk()
        }
    }
    
    deinit {
        refreshTimer?.cancel()
    }

    // MARK: - Cache-first strategy

    func fetchProfile(distinctId: String) async throws -> ProfileResponse {
        // Check memory cache first
        if let cached = cachedProfile {
            let age = dateProvider.timeIntervalSince(cached.cachedAt)
            
            // Return immediately if fresh
            if age < freshCacheAge {
                LogDebug("Returning fresh profile from memory (age: \(Int(age))s)")
                return cached.response
            }
            
            // Return stale with background refresh if not too old
            if age < staleCacheAge {
                LogDebug("Returning stale profile from memory (age: \(Int(age/60))m), refreshing in background")
                Task { [weak self] in
                    await self?.refreshInBackground(distinctId: distinctId)
                }
                return cached.response
            }
        }
        
        // No valid cache, must fetch from network
        LogInfo("No valid cached profile, fetching from network")
        return try await refreshProfile(distinctId: distinctId)
    }

    // MARK: - Helpers

    /// Get the effective locale to send in profile requests
    /// Uses configured override or device locale
    private var effectiveLocale: String {
        // Check for configured locale override first
        if let overrideLocale = NuxieSDK.shared.configuration?.localeIdentifier {
            return overrideLocale
        }
        // Fall back to device locale
        return Locale.current.identifier
    }

    /// Load profile from disk cache into memory on startup
    private func loadFromDisk() async {
        let distinctId = identityService.getDistinctId()
        if let cached = await diskCache.retrieve(forKey: distinctId, allowStale: true) {
            self.cachedProfile = cached
            LogDebug("Loaded profile from disk (age: \(Int(cached.cachedAt.timeIntervalSinceNow * -1 / 60))m)")
            
            // Start refresh timer if cache is stale
            let age = dateProvider.timeIntervalSince(cached.cachedAt)
            if age > freshCacheAge {
                startRefreshTimer()
            }
        }
    }

    /// Refresh profile from network
    private func refreshProfile(distinctId: String) async throws -> ProfileResponse {
        do {
            let locale = effectiveLocale
            let fresh = try await api.fetchProfile(for: distinctId, locale: locale)
            LogInfo("Network fetch succeeded; updating cache (locale: \(locale))")
            await updateCache(profile: fresh, distinctId: distinctId)
            await handleProfileUpdate(fresh)
            return fresh
        } catch {
            LogError("Network fetch failed: \(error)")
            throw error
        }
    }

    /// Background refresh without throwing
    private func refreshInBackground(distinctId: String) async {
        do {
            let locale = effectiveLocale
            let fresh = try await api.fetchProfile(for: distinctId, locale: locale)
            LogInfo("Background refresh succeeded; updating cache (locale: \(locale))")
            await updateCache(profile: fresh, distinctId: distinctId)
            await handleProfileUpdate(fresh)
        } catch {
            LogDebug("Background refresh failed: \(error)")
        }
    }

    /// Update both memory and disk cache (write-through)
    private func updateCache(profile: ProfileResponse, distinctId: String) async {
        let item = CachedProfile(response: profile, distinctId: distinctId, cachedAt: dateProvider.now())
        
        // Update memory immediately
        self.cachedProfile = item
        LogDebug("Updated memory cache for \(NuxieLogger.shared.logDistinctID(distinctId))")
        
        // Write to disk (awaited to keep cache state consistent)
        do {
            try await diskCache.store(item, forKey: distinctId)
            LogDebug("Updated disk cache for \(NuxieLogger.shared.logDistinctID(distinctId))")
        } catch {
            LogWarning("Failed to update disk cache: \(error)")
        }
        
        // Start refresh timer
        startRefreshTimer()
    }

    /// Start or restart the periodic refresh timer
    private func startRefreshTimer() {
        // Cancel existing timer
        refreshTimer?.cancel()
        
        // Start new timer
        refreshTimer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                
                // Sleep for the refresh interval
                try? await self.sleepProvider.sleep(for: self.refreshInterval)
                
                guard !Task.isCancelled else { break }
                
                // Perform background refresh
                let distinctId = await self.identityService.getDistinctId()
                await self.refreshInBackground(distinctId: distinctId)
            }
        }
    }

    // MARK: - Cache management API

    func getCachedProfile(distinctId: String) async -> ProfileResponse? {
        // Return from memory if available and not too stale
        if let cached = cachedProfile {
            let age = dateProvider.timeIntervalSince(cached.cachedAt)
            if age < staleCacheAge {
                return cached.response
            }
        }
        return nil
    }

    func clearCache(distinctId: String) async {
        // Clear memory
        cachedProfile = nil
        
        // Clear disk
        await diskCache.remove(forKey: distinctId)
        
        // Cancel refresh timer
        refreshTimer?.cancel()
        refreshTimer = nil
        
        LogDebug("Cleared cached profile for \(NuxieLogger.shared.logDistinctID(distinctId))")
    }

    func clearAllCache() async {
        // Clear memory
        cachedProfile = nil
        
        // Clear disk
        await diskCache.clearAll()
        
        // Cancel refresh timer
        refreshTimer?.cancel()
        refreshTimer = nil
        
        LogInfo("Cleared all profile cache")
    }

    @discardableResult
    func cleanupExpired() async -> Int {
        // For memory-first approach, we only need to clean disk cache
        // Memory cache is always current user's profile
        return await diskCache.cleanupExpired()
    }

    func getCacheStats() async -> [String: Any] {
        var stats: [String: Any] = [:]
        
        // Memory cache stats
        if let cached = cachedProfile {
            let age = dateProvider.timeIntervalSince(cached.cachedAt)
            stats["memory_cache_age_seconds"] = Int(age)
            stats["memory_cache_fresh"] = age < freshCacheAge
            stats["memory_cache_valid"] = age < staleCacheAge
        } else {
            stats["memory_cache_age_seconds"] = nil
            stats["memory_cache_fresh"] = false
            stats["memory_cache_valid"] = false
        }
        
        // Disk cache stats
        let keys = await diskCache.getAllKeys()
        var totalBytes: Int64 = 0
        for key in keys {
            if let meta = await diskCache.getMetadata(forKey: key) {
                totalBytes += meta.size
            }
        }
        
        stats["disk_cached_profiles"] = keys.count
        stats["disk_cache_size_bytes"] = totalBytes
        stats["refresh_timer_active"] = refreshTimer != nil
        stats["fresh_cache_age_minutes"] = freshCacheAge / 60
        stats["stale_cache_age_hours"] = staleCacheAge / 3600
        
        return stats
    }

    // MARK: - Refetch API

    func refetchProfile() async throws -> ProfileResponse {
        let distinctId = identityService.getDistinctId()
        
        // Force refresh from network (bypasses cache)
        LogInfo("Force refreshing profile from network")
        return try await refreshProfile(distinctId: distinctId)
    }

    // MARK: - Cache Invalidation Triggers
    
    /// Invalidate cache and refresh after important events
    func invalidateAndRefresh(reason: String) async {
        LogInfo("Invalidating cache due to: \(reason)")
        
        // Clear memory cache to force refresh
        cachedProfile = nil
        
        // Fetch fresh profile
        let distinctId = identityService.getDistinctId()
        await refreshInBackground(distinctId: distinctId)
    }
    
    /// Handle app becoming active - refresh if stale
    func onAppBecameActive() async {
        guard let cached = cachedProfile else {
            // No cache, load from disk or fetch
            await loadFromDisk()
            return
        }
        
        let age = dateProvider.timeIntervalSince(cached.cachedAt)
        if age > 15 * 60 { // 15 minutes
            LogDebug("App became active with stale cache (age: \(Int(age/60))m), refreshing")
            let distinctId = identityService.getDistinctId()
            await refreshInBackground(distinctId: distinctId)
        }
    }
    
    /// Handle user change - clear old cache and load new
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
        LogInfo("User changed from \(NuxieLogger.shared.logDistinctID(oldDistinctId)) to \(NuxieLogger.shared.logDistinctID(newDistinctId))")
        
        // Clear memory cache
        cachedProfile = nil
        
        // Cancel refresh timer
        refreshTimer?.cancel()
        refreshTimer = nil
        
        // Clear old user's disk cache
        await diskCache.remove(forKey: oldDistinctId)
        
        // Try to load new user's cache from disk
        if let cached = await diskCache.retrieve(forKey: newDistinctId, allowStale: true) {
            self.cachedProfile = cached
            LogDebug("Loaded new user's profile from disk")
            
            // Refresh if stale
            let age = dateProvider.timeIntervalSince(cached.cachedAt)
            if age > freshCacheAge {
                await refreshInBackground(distinctId: newDistinctId)
            }
        } else {
            // No cache for new user, fetch fresh
            await refreshInBackground(distinctId: newDistinctId)
        }
    }
    
    private func handleProfileUpdate(_ profile: ProfileResponse) async {
        // Get the current distinct ID for explicit attribution
        let distinctId = identityService.getDistinctId()
        
        // Update user properties from server if present
        if let userProps = profile.userProperties {
            var propsDict: [String: Any] = [:]
            for (k, v) in userProps { propsDict[k] = v.value }
            identityService.setUserProperties(propsDict)
            LogInfo("Updated \(propsDict.count) user properties from server")
        }
        
        // Update segments with explicit distinctId to prevent races
        if !profile.segments.isEmpty {
            await segmentService.updateSegments(profile.segments, for: distinctId)
            LogInfo("Updated \(profile.segments.count) segment definitions for user \(NuxieLogger.shared.logDistinctID(distinctId))")
        }

        // Resume active journeys from server (cross-device resume)
        if let journeys = profile.journeys, !journeys.isEmpty {
            LogInfo("Resuming \(journeys.count) active journey(s) from server")
            // Resolve journeyService lazily to break circular dependency
            await Container.shared.journeyService().resumeFromServerState(journeys, campaigns: profile.campaigns)
        }

    }
}
}
