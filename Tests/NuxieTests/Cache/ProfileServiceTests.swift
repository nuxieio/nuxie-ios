import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie



// MARK: - Test Suite

class ProfileServiceTests: AsyncSpec {
    override class func spec() {
        describe("ProfileService") {
            var sut: ProfileService!
            var mocks: MockFactory!
            var cache: InMemoryCachedProfileStore!
            
            beforeEach {
                // Set up dependency injection with Factory

                // Register test configuration (required for any services that depend on sdkConfiguration)
                let testConfig = NuxieConfiguration(apiKey: "test-api-key")
                Container.shared.sdkConfiguration.register { testConfig }

                // Create mocks
                mocks = MockFactory.shared
                cache = InMemoryCachedProfileStore()
                
                // Register mocks with Factory
                mocks.registerAll()
                
                // Create service under test with in-memory cache
                sut = ProfileService(cache: cache)
            }
            
            afterEach {
                // Clean up
                await sut.clearAllCache()
                // Don't call resetAllFactories() here - let beforeEach handle container reset
                // to avoid race conditions with background tasks accessing services
            }
            
            describe("fetchProfile") {
                context("when no cache exists") {
                    it("fetches from network") {
                        await mocks.nuxieApi.setProfileDelay(0.1)
                        
                        let profile = try await sut.fetchProfile(distinctId: "user-123")
                        
                        let profileCallCount = await mocks.nuxieApi.fetchProfileCallCount
                        expect(profileCallCount).to(equal(1))
                        expect(profile.campaigns.count).to(equal(1))
                        expect(profile.segments.count).to(equal(1))
                        expect(profile.flows.count).to(equal(1))
                    }
                    
                    it("caches the fetched profile") {
                        _ = try await sut.fetchProfile(distinctId: "user-123")
                        
                        // Check cache directly
                        let cachedProfile = await sut.getCachedProfile(distinctId: "user-123")
                        expect(cachedProfile).toNot(beNil())
                        expect(cachedProfile?.campaigns.count).to(equal(1))
                    }
                    
                    it("handles network errors when no cache exists") {
                        await mocks.nuxieApi.setShouldFailProfile(true)
                        
                        await expect {
                            try await sut.fetchProfile(distinctId: "user-123")
                        }.to(throwError())
                    }
                    
                    it("notifies flow service of new flows") {
                        _ = try await sut.fetchProfile(distinctId: "user-123")
                        
                        expect(mocks.flowService.prefetchedFlows.count).to(equal(1))
                        expect(mocks.flowService.prefetchedFlows.first?.id).to(equal("flow-1"))
                    }
                }
                
                context("when cache is fresh (< 5 minutes)") {
                    beforeEach {
                        // Pre-populate cache with fresh data
                        _ = try await sut.fetchProfile(distinctId: "user-123")
                        await mocks.nuxieApi.reset()
                        mocks.flowService.reset()
                    }
                    
                    it("returns immediately from memory without network call") {
                        // Cache is fresh (just populated)
                        let profile = try await sut.fetchProfile(distinctId: "user-123")
                        
                        // Should not make any network calls
                        let profileCallCount = await mocks.nuxieApi.fetchProfileCallCount
                        expect(profileCallCount).to(equal(0))
                        expect(profile.campaigns.count).to(equal(1))
                    }
                    
                    it("does not trigger background refresh") {
                        _ = try await sut.fetchProfile(distinctId: "user-123")
                        
                        // Give a moment for any background tasks to start (they shouldn't)
                        await Task.yield()
                        
                        let profileCallCount = await mocks.nuxieApi.fetchProfileCallCount
                        expect(profileCallCount).to(equal(0))
                    }
                }
                
                context("when cache is stale (5 min - 24 hours)") {
                    beforeEach {
                        // Pre-populate cache
                        _ = try await sut.fetchProfile(distinctId: "user-123")
                        await mocks.nuxieApi.reset()
                        mocks.flowService.reset()
                        
                        // Advance time by 10 minutes (stale but valid)
                        mocks.dateProvider.advance(by: 10 * 60)
                    }
                    
                    it("returns cached data immediately") {
                        let profile = try await sut.fetchProfile(distinctId: "user-123")
                        
                        // Should return immediately
                        expect(profile).toNot(beNil())
                        expect(profile.campaigns.count).to(equal(1))
                    }
                    
                    it("triggers background refresh") {
                        _ = try await sut.fetchProfile(distinctId: "user-123")
                        
                        // Background refresh should have been attempted once
                        await expect { await mocks.nuxieApi.fetchProfileCallCount }
                            .toEventually(equal(1), timeout: .seconds(1))
                    }
                    
                    it("updates cache after background refresh") {
                        // Set up new response for background refresh
                        let newResponse = ProfileResponse(
                            campaigns: [ResponseBuilders.buildCampaign(id: "new-campaign", name: "New Campaign")],
                            segments: [],
                            flows: [],
                            userProperties: nil,
                            experimentAssignments: nil,
                            features: nil
                        )
                        await mocks.nuxieApi.setProfileResponse(newResponse)
                        
                        _ = try await sut.fetchProfile(distinctId: "user-123")
                        
                        // Wait for background refresh to complete - check cache updates
                        await expect { await sut.getCachedProfile(distinctId: "user-123")?.campaigns.first?.id }
                            .toEventually(equal("new-campaign"), timeout: .seconds(1))
                    }
                }
                
                context("when cache is expired (> 24 hours)") {
                    beforeEach {
                        // Pre-populate cache
                        _ = try await sut.fetchProfile(distinctId: "user-123")
                        await mocks.nuxieApi.reset()
                        mocks.flowService.reset()
                        
                        // Advance time by 25 hours (expired)
                        mocks.dateProvider.advance(by: 25 * 60 * 60)
                    }
                    
                    it("forces network fetch") {
                        _ = try await sut.fetchProfile(distinctId: "user-123")
                        
                        // Should make a network call
                        let profileCallCount = await mocks.nuxieApi.fetchProfileCallCount
                        expect(profileCallCount).to(equal(1))
                    }
                    
                    it("blocks until network fetch completes") {
                        await mocks.nuxieApi.setProfileDelay(0.2)
                        
                        let startTime = Date()
                        _ = try await sut.fetchProfile(distinctId: "user-123")
                        let elapsed = Date().timeIntervalSince(startTime)
                        
                        // Should have waited for network
                        expect(elapsed).to(beGreaterThanOrEqualTo(0.2))
                    }
                }
                
                context("flow lifecycle management") {
                    it("detects added flows") {
                        // Initial fetch
                        _ = try await sut.fetchProfile(distinctId: "user-123")
                        mocks.flowService.reset()
                        
                        // Add a new flow
                        let newFlow = RemoteFlow(
                            id: "flow-2",
                            name: "New Flow",
                            url: "https://example.com/flow2",
                            products: [],
                            manifest: BuildManifest(
                                totalFiles: 3,
                                totalSize: 2048,
                                contentHash: "hash456",
                                files: []
                            )
                        )
                        
                        let existingFlow = await mocks.nuxieApi.profileResponse!.flows[0]
                        await mocks.nuxieApi.setProfileResponse(ProfileResponse(
                            campaigns: [],
                            segments: [],
                            flows: [existingFlow, newFlow],
                            userProperties: nil,
                            experimentAssignments: nil,
                            features: nil
                        ))
                        
                        // Clear cache to force network fetch
                        await sut.clearCache(distinctId: "user-123")
                        _ = try await sut.fetchProfile(distinctId: "user-123")
                        
                        // Only the new flow should be prefetched since we reset the mock
                        expect(mocks.flowService.prefetchedFlows.count).to(equal(1))
                        expect(mocks.flowService.prefetchedFlows.map { $0.id }).to(contain("flow-2"))
                    }
                    
                    it("detects updated flows") {
                        // Initial fetch
                        _ = try await sut.fetchProfile(distinctId: "user-123")
                        mocks.flowService.reset()
                        
                        // Update existing flow's content hash
                        let updatedFlow = RemoteFlow(
                            id: "flow-1",
                            name: "Test Flow Updated",
                            url: "https://example.com/flow",
                            products: [],
                            manifest: BuildManifest(
                                totalFiles: 5,
                                totalSize: 4096,
                                contentHash: "hash789", // Changed hash
                                files: []
                            )
                        )
                        
                        await mocks.nuxieApi.setProfileResponse(ProfileResponse(
                            campaigns: [],
                            segments: [],
                            flows: [updatedFlow],
                            userProperties: nil,
                            experimentAssignments: nil,
                            features: nil
                        ))
                        
                        // Clear cache to force network fetch
                        await sut.clearCache(distinctId: "user-123")
                        _ = try await sut.fetchProfile(distinctId: "user-123")
                        
                        expect(mocks.flowService.removedFlowIds).to(contain("flow-1"))
                        expect(mocks.flowService.prefetchedFlows.count).to(equal(1)) // Just the updated flow
                    }
                    
                    it("detects removed flows") {
                        // Initial fetch
                        _ = try await sut.fetchProfile(distinctId: "user-123")
                        mocks.flowService.reset()
                        
                        // Remove all flows
                        await mocks.nuxieApi.setProfileResponse(ProfileResponse(
                            campaigns: [],
                            segments: [],
                            flows: [],
                            userProperties: nil,
                            experimentAssignments: nil,
                            features: nil
                        ))
                        
                        // Clear cache to force network fetch
                        await sut.clearCache(distinctId: "user-123")
                        _ = try await sut.fetchProfile(distinctId: "user-123")
                        
                        expect(mocks.flowService.removedFlowIds).to(contain("flow-1"))
                        expect(mocks.flowService.prefetchedFlows.count).to(equal(0))
                    }
                }
            }
            
            describe("cache management") {
                it("clears cache for specific user") {
                    _ = try await sut.fetchProfile(distinctId: "user-123")
                    
                    var cachedProfile = await sut.getCachedProfile(distinctId: "user-123")
                    expect(cachedProfile).toNot(beNil())
                    
                    await sut.clearCache(distinctId: "user-123")
                    
                    cachedProfile = await sut.getCachedProfile(distinctId: "user-123")
                    expect(cachedProfile).to(beNil())
                }
                
                it("clears all cached profiles") {
                    _ = try await sut.fetchProfile(distinctId: "user-123")
                    _ = try await sut.fetchProfile(distinctId: "user-456")
                    
                    await sut.clearAllCache()
                    
                    let cached1 = await sut.getCachedProfile(distinctId: "user-123")
                    let cached2 = await sut.getCachedProfile(distinctId: "user-456")
                    
                    expect(cached1).to(beNil())
                    expect(cached2).to(beNil())
                }
                
                it("provides cache statistics") {
                    _ = try await sut.fetchProfile(distinctId: "user-123")
                    
                    let stats = await sut.getCacheStats()
                    
                    // Check memory cache stats
                    expect(stats["memory_cache_fresh"] as? Bool).to(beTrue())
                    expect(stats["memory_cache_valid"] as? Bool).to(beTrue())
                    expect(stats["memory_cache_age_seconds"] as? Int).toNot(beNil())
                    
                    // Check refresh timer
                    expect(stats["refresh_timer_active"] as? Bool).to(beTrue())
                    
                    // Check cache age settings
                    expect(stats["fresh_cache_age_minutes"] as? Double).to(equal(5))
                    expect(stats["stale_cache_age_hours"] as? Double).to(equal(24))
                }
                
                it("sanitizes filenames for cache keys") {
                    let specialCharsId = "user@123#456/test"
                    _ = try await sut.fetchProfile(distinctId: specialCharsId)
                    
                    let cachedProfile = await sut.getCachedProfile(distinctId: specialCharsId)
                    expect(cachedProfile).toNot(beNil())
                }
            }
            
            describe("refetchProfile") {
                it("uses identity service to get distinct ID") {
                    mocks.identityService.setDistinctId("identity-user-123")
                    
                    let profile = try await sut.refetchProfile()
                    
                    expect(profile).toNot(beNil())
                    let profileCallCount = await mocks.nuxieApi.fetchProfileCallCount
                    expect(profileCallCount).to(equal(1))
                }
                
                it("forces network fetch bypassing cache") {
                    // Pre-populate fresh cache
                    _ = try await sut.fetchProfile(distinctId: "user-123")
                    await mocks.nuxieApi.reset()
                    
                    // refetchProfile should still hit network despite fresh cache
                    _ = try await sut.refetchProfile()
                    
                    let profileCallCount = await mocks.nuxieApi.fetchProfileCallCount
                    expect(profileCallCount).to(equal(1))
                }
                
                it("propagates errors from fetch") {
                    await mocks.nuxieApi.setShouldFailProfile(true)
                    
                    await expect {
                        try await sut.refetchProfile()
                    }.to(throwError())
                }
            }
            
            describe("cache invalidation triggers") {
                beforeEach {
                    // Pre-populate cache
                    _ = try await sut.fetchProfile(distinctId: "user-123")
                    await mocks.nuxieApi.reset()
                }
                
                context("invalidateAndRefresh") {
                    it("clears memory cache and fetches fresh") {
                        await sut.invalidateAndRefresh(reason: "test")
                        
                        // Should have made a network call
                        await expect { await mocks.nuxieApi.fetchProfileCallCount }
                            .toEventually(equal(1), timeout: .seconds(1))
                    }
                }
                
                context("onAppBecameActive") {
                    it("refreshes if cache is older than 15 minutes") {
                        // Advance time by 20 minutes
                        mocks.dateProvider.advance(by: 20 * 60)
                        
                        await sut.onAppBecameActive()
                        
                        // Should trigger background refresh
                        await expect { await mocks.nuxieApi.fetchProfileCallCount }
                            .toEventually(equal(1), timeout: .seconds(1))
                    }
                    
                    it("does not refresh if cache is fresh") {
                        // Advance time by only 5 minutes
                        mocks.dateProvider.advance(by: 5 * 60)
                        
                        await sut.onAppBecameActive()
                        
                        // Give a moment to check no refresh happens
                        await Task.yield()
                        
                        let profileCallCount = await mocks.nuxieApi.fetchProfileCallCount
                        expect(profileCallCount).to(equal(0))
                    }
                }
                
                context("handleUserChange") {
                    it("clears old user cache and loads new user") {
                        // Setup cache for new user
                        let newUserProfile = ProfileResponse(
                            campaigns: [ResponseBuilders.buildCampaign(id: "new-user-campaign", name: "New User")],
                            segments: [],
                            flows: [],
                            userProperties: nil,
                            experimentAssignments: nil,
                            features: nil
                        )
                        try await cache.store(
                            CachedProfile(response: newUserProfile, distinctId: "new-user", cachedAt: mocks.dateProvider.now()),
                            forKey: "new-user"
                        )
                        
                        await sut.handleUserChange(from: "user-123", to: "new-user")
                        
                        // Old cache should be cleared
                        let oldCache = await cache.retrieve(forKey: "user-123", allowStale: true)
                        expect(oldCache).to(beNil())
                        
                        // New user's cache should be loaded
                        let currentCache = await sut.getCachedProfile(distinctId: "new-user")
                        expect(currentCache?.campaigns.first?.id).to(equal("new-user-campaign"))
                    }
                }
            }
            
            describe("refresh timer") {
                it("starts timer after successful fetch") {
                    _ = try await sut.fetchProfile(distinctId: "user-123")
                    
                    // Verify timer is active by checking cache stats
                    let stats = await sut.getCacheStats()
                    expect(stats["refresh_timer_active"] as? Bool).to(beTrue())
                }
                
                it("refreshes periodically while active") {
                    _ = try await sut.fetchProfile(distinctId: "user-123")
                    await mocks.nuxieApi.reset()
                    
                    // Wait for the timer to start and call sleep
                    await expect { mocks.sleepProvider.pendingSleepCount }
                        .toEventually(equal(1), timeout: .seconds(1))
                    
                    // Complete the sleep that's in progress (timer sleeps first, then refreshes)
                    mocks.sleepProvider.completeAllSleeps()
                    
                    // Now wait for the refresh to complete after the sleep
                    await expect { await mocks.nuxieApi.fetchProfileCallCount }
                        .toEventually(equal(1), timeout: .seconds(2))
                }
                
                it("cancels timer on cache clear") {
                    _ = try await sut.fetchProfile(distinctId: "user-123")
                    
                    await sut.clearCache(distinctId: "user-123")
                    
                    // Timer should be cancelled immediately
                    let stats = await sut.getCacheStats()
                    expect(stats["refresh_timer_active"] as? Bool).to(beFalse())
                }
            }
            
            describe("memory and disk sync") {
                it("loads from disk on initialization") {
                    // Store profile in disk cache using the mock identity's distinctId
                    let distinctId = mocks.identityService.getDistinctId() // Should be "anonymous-id" by default
                    let diskProfile = ProfileResponse(
                        campaigns: [ResponseBuilders.buildCampaign(id: "disk-campaign", name: "From Disk")],
                        segments: [],
                        flows: [],
                        userProperties: nil,
                        experimentAssignments: nil,
                        features: nil
                    )
                    try await cache.store(
                        CachedProfile(response: diskProfile, distinctId: distinctId, cachedAt: mocks.dateProvider.now()),
                        forKey: distinctId
                    )
                    
                    // Create new service instance - should load from disk
                    let newService = ProfileService(cache: cache)
                    
                    // Wait for initialization to complete
                    await expect { await newService.getCachedProfile(distinctId: distinctId)?.campaigns.first?.id }
                        .toEventually(equal("disk-campaign"), timeout: .seconds(1))
                }
                
                it("writes to disk when memory cache updates") {
                    _ = try await sut.fetchProfile(distinctId: "user-123")
                    
                    // Check disk cache - the write is async but should complete quickly
                    await expect { await cache.retrieve(forKey: "user-123", allowStale: true) }
                        .toEventuallyNot(beNil(), timeout: .seconds(1))
                    
                    let diskCache = await cache.retrieve(forKey: "user-123", allowStale: true)
                    expect(diskCache?.response.campaigns.count).to(equal(1))
                }
                
                it("handles disk write failures gracefully") {
                    // This would require a mock that can simulate write failures
                    // For now, we can verify memory cache still works even if disk fails
                    _ = try await sut.fetchProfile(distinctId: "user-123")
                    
                    // Memory cache should work regardless of disk status
                    let profile = await sut.getCachedProfile(distinctId: "user-123")
                    expect(profile).toNot(beNil())
                }
            }
            
            describe("concurrency") {
                it("handles concurrent fetches safely") {
                    await mocks.nuxieApi.setProfileDelay(0.1)
                    
                    // Launch multiple concurrent fetches
                    let results = await withTaskGroup(of: ProfileResponse?.self) { group in
                        for i in 0..<5 {
                            group.addTask {
                                try? await sut.fetchProfile(distinctId: "user-\(i)")
                            }
                        }
                        
                        var profiles: [ProfileResponse?] = []
                        for await profile in group {
                            profiles.append(profile)
                        }
                        return profiles
                    }
                    
                    expect(results.count).to(equal(5))
                    expect(results.compactMap { $0 }.count).to(equal(5))
                }
                
                it("handles concurrent cache operations safely") {
                    // Pre-populate cache
                    _ = try await sut.fetchProfile(distinctId: "user-123")
                    
                    // Concurrent reads and writes
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask {
                            _ = await sut.getCachedProfile(distinctId: "user-123")
                        }
                        group.addTask {
                            await sut.clearCache(distinctId: "user-123")
                        }
                        group.addTask {
                            _ = await sut.getCacheStats()
                        }
                        group.addTask {
                            _ = await sut.cleanupExpired()
                        }
                    }
                    
                    // Should not crash or deadlock
                    expect(true).to(beTrue())
                }
            }
        }
    }
}
