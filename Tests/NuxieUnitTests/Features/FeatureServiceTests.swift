import FactoryKit
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

@MainActor
private final class FeatureChangeSpy {
    var changedFeatureIds: [String] = []
}

final class FeatureServiceTests: AsyncSpec {
    override class func spec() {
        describe("FeatureService") {
            var featureService: FeatureService!
            var mockFactory: MockFactory!
            var mockProfileService: MockProfileService!
            var mockIdentityService: MockIdentityService!
            var mockApi: MockNuxieApi!
            var mockDateProvider: MockDateProvider!

            beforeEach {
                mockFactory = MockFactory.shared
                mockFactory.registerAll()

                featureService = FeatureService()
                mockProfileService = mockFactory.profileService
                mockIdentityService = mockFactory.identityService
                mockApi = mockFactory.nuxieApi
                mockDateProvider = mockFactory.dateProvider
                mockIdentityService.setDistinctId("customer-123")

                _ = await MainActor.run {
                    let info = Container.shared.featureInfo()
                    info.clear()
                    info.onFeatureChange = nil
                }
            }

            it("prefers purchase-synced access over stale profile cache") {
                let featureId = "premium_export"

                mockProfileService.setProfileResponse(
                    Self.makeProfileResponse(features: [
                        Self.makeFeature(
                            id: featureId,
                            type: .metered,
                            balance: 0,
                            unlimited: false
                        )
                    ])
                )

                _ = try await mockProfileService.fetchProfile(distinctId: "customer-123")

                await featureService.updateFromPurchase([
                    PurchaseFeature(
                        id: featureId,
                        extId: nil,
                        type: .metered,
                        allowed: true,
                        balance: 5,
                        unlimited: false
                    )
                ])

                let cached = await featureService.getCached(featureId: featureId, entityId: nil)
                let allCached = await featureService.getAllCached()

                expect(cached?.allowed).to(beTrue())
                expect(cached?.balance).to(equal(5))
                expect(allCached[featureId]?.allowed).to(beTrue())
                expect(allCached[featureId]?.balance).to(equal(5))
            }

            it("exposes purchase-synced access even when no profile is cached") {
                let featureId = "plan:team_members"

                await featureService.updateFromPurchase([
                    PurchaseFeature(
                        id: featureId,
                        extId: nil,
                        type: .boolean,
                        allowed: true,
                        balance: nil,
                        unlimited: true
                    )
                ])

                let cached = await featureService.getCached(featureId: featureId, entityId: nil)
                let allCached = await featureService.getAllCached()

                expect(cached?.allowed).to(beTrue())
                expect(cached?.unlimited).to(beTrue())
                expect(allCached[featureId]?.allowed).to(beTrue())
                expect(allCached[featureId]?.unlimited).to(beTrue())
            }

            it("recomputes metered cache overrides for lower required balances") {
                let featureId = "ai_generations"

                await mockApi.setCheckFeatureResponse(
                    FeatureCheckResult(
                        customerId: "customer-123",
                        featureId: featureId,
                        requiredBalance: 10,
                        code: "insufficient_balance",
                        allowed: false,
                        unlimited: false,
                        balance: 5,
                        type: .metered,
                        preview: nil
                    )
                )

                let first = try await featureService.checkWithCache(
                    featureId: featureId,
                    requiredBalance: 10,
                    entityId: nil,
                    forceRefresh: true
                )

                let second = try await featureService.checkWithCache(
                    featureId: featureId,
                    requiredBalance: 1,
                    entityId: nil,
                    forceRefresh: false
                )

                expect(first.allowed).to(beFalse())
                expect(first.balance).to(equal(5))
                expect(second.allowed).to(beTrue())
                expect(second.balance).to(equal(5))
            }

            it("falls back to the profile snapshot after a real-time override expires") {
                let featureId = "credits"

                mockProfileService.setProfileResponse(
                    Self.makeProfileResponse(features: [
                        Self.makeFeature(
                            id: featureId,
                            type: .metered,
                            balance: 2,
                            unlimited: false
                        )
                    ])
                )
                _ = try await mockProfileService.fetchProfile(distinctId: "customer-123")
                await featureService.syncFeatureInfo()

                await mockApi.setCheckFeatureResponse(
                    FeatureCheckResult(
                        customerId: "customer-123",
                        featureId: featureId,
                        requiredBalance: 1,
                        code: "allowed",
                        allowed: true,
                        unlimited: false,
                        balance: 5,
                        type: .metered,
                        preview: nil
                    )
                )

                let fresh = try await featureService.checkWithCache(
                    featureId: featureId,
                    requiredBalance: 1,
                    entityId: nil,
                    forceRefresh: true
                )
                expect(fresh.balance).to(equal(5))

                mockDateProvider.advance(by: 301)

                let cached = await featureService.getCached(featureId: featureId, entityId: nil)
                expect(cached?.balance).to(equal(2))
                expect(cached?.allowed).to(beTrue())
            }

            it("keeps the public projection in sync with optimistic and confirmed usage updates") {
                let featureId = "ai_generations"

                mockProfileService.setProfileResponse(
                    Self.makeProfileResponse(features: [
                        Self.makeFeature(
                            id: featureId,
                            type: .metered,
                            balance: 10,
                            unlimited: false
                        )
                    ])
                )
                _ = try await mockProfileService.fetchProfile(distinctId: "customer-123")
                await featureService.syncFeatureInfo()

                await featureService.applyOptimisticUsage(
                    featureId: featureId,
                    amount: 3,
                    entityId: nil
                )

                let optimisticCached = await featureService.getCached(featureId: featureId, entityId: nil)
                let optimisticProjected = await MainActor.run { Container.shared.featureInfo().balance(featureId) }
                expect(optimisticCached?.balance).to(equal(7))
                expect(optimisticProjected).to(equal(7))

                await featureService.applyConfirmedUsage(
                    featureId: featureId,
                    remainingBalance: 4,
                    entityId: nil
                )

                let confirmedCached = await featureService.getCached(featureId: featureId, entityId: nil)
                let confirmedProjected = await MainActor.run { Container.shared.featureInfo().balance(featureId) }
                expect(confirmedCached?.balance).to(equal(4))
                expect(confirmedProjected).to(equal(4))
            }

            it("replaces local usage overrides when a fresh profile snapshot is applied") {
                let featureId = "ai_generations"

                mockProfileService.setProfileResponse(
                    Self.makeProfileResponse(features: [
                        Self.makeFeature(
                            id: featureId,
                            type: .metered,
                            balance: 10,
                            unlimited: false
                        )
                    ])
                )
                _ = try await mockProfileService.fetchProfile(distinctId: "customer-123")
                await featureService.syncFeatureInfo()

                await featureService.applyOptimisticUsage(
                    featureId: featureId,
                    amount: 3,
                    entityId: nil
                )
                let optimisticCached = await featureService.getCached(featureId: featureId, entityId: nil)
                expect(optimisticCached?.balance).to(equal(7))

                mockProfileService.setProfileResponse(
                    Self.makeProfileResponse(features: [
                        Self.makeFeature(
                            id: featureId,
                            type: .metered,
                            balance: 6,
                            unlimited: false
                        )
                    ])
                )
                _ = try await mockProfileService.fetchProfile(distinctId: "customer-123")
                await featureService.syncFeatureInfo()

                let refreshedCached = await featureService.getCached(featureId: featureId, entityId: nil)
                let refreshedProjected = await MainActor.run { Container.shared.featureInfo().balance(featureId) }
                expect(refreshedCached?.balance).to(equal(6))
                expect(refreshedProjected).to(equal(6))
            }

            it("preserves the public non-entity view for entity-scoped usage updates") {
                let featureId = "api_calls"

                mockProfileService.setProfileResponse(
                    Self.makeProfileResponse(features: [
                        Self.makeFeature(
                            id: featureId,
                            type: .metered,
                            balance: 10,
                            unlimited: false
                        )
                    ])
                )
                _ = try await mockProfileService.fetchProfile(distinctId: "customer-123")
                await featureService.syncFeatureInfo()

                await featureService.applyOptimisticUsage(
                    featureId: featureId,
                    amount: 2,
                    entityId: "project-123"
                )

                let cached = await featureService.getCached(featureId: featureId, entityId: nil)
                let projected = await MainActor.run { Container.shared.featureInfo().balance(featureId) }
                expect(cached?.balance).to(equal(8))
                expect(projected).to(equal(8))
            }

            it("publishes projection changes only when the effective feature state changes") {
                let featureId = "premium_export"
                let spy = await MainActor.run { FeatureChangeSpy() }

                mockProfileService.setProfileResponse(
                    Self.makeProfileResponse(features: [
                        Self.makeFeature(
                            id: featureId,
                            type: .boolean,
                            balance: nil,
                            unlimited: true
                        )
                    ])
                )
                _ = try await mockProfileService.fetchProfile(distinctId: "customer-123")

                await MainActor.run {
                    Container.shared.featureInfo().onFeatureChange = { featureId, _, _ in
                        spy.changedFeatureIds.append(featureId)
                    }
                }

                await featureService.syncFeatureInfo()
                await featureService.syncFeatureInfo()

                let projected = await MainActor.run { Container.shared.featureInfo().feature(featureId) }
                let changes = await MainActor.run { spy.changedFeatureIds }

                expect(projected?.allowed).to(beTrue())
                expect(changes).to(equal([featureId]))
            }

            it("rebuilds feature state for the new user without leaking the old user") {
                let oldFeatureId = "legacy_export"
                let newFeatureId = "premium_sync"

                mockProfileService.setProfileResponse(
                    Self.makeProfileResponse(features: [
                        Self.makeFeature(
                            id: oldFeatureId,
                            type: .boolean,
                            balance: nil,
                            unlimited: true
                        )
                    ])
                )
                _ = try await mockProfileService.fetchProfile(distinctId: "customer-123")
                await featureService.syncFeatureInfo()

                mockIdentityService.setDistinctId("customer-456")
                mockProfileService.setProfileResponse(
                    Self.makeProfileResponse(features: [
                        Self.makeFeature(
                            id: newFeatureId,
                            type: .boolean,
                            balance: nil,
                            unlimited: true
                        )
                    ])
                )
                _ = try await mockProfileService.fetchProfile(distinctId: "customer-456")

                await featureService.handleUserChange(
                    from: "customer-123",
                    to: "customer-456"
                )

                let oldFeature = await featureService.getCached(featureId: oldFeatureId, entityId: nil)
                let newFeature = await featureService.getCached(featureId: newFeatureId, entityId: nil)
                let projected = await MainActor.run { Container.shared.featureInfo().all }

                expect(oldFeature).to(beNil())
                expect(newFeature?.allowed).to(beTrue())
                expect(projected[oldFeatureId]).to(beNil())
                expect(projected[newFeatureId]?.allowed).to(beTrue())
            }

            it("keeps entity-specific real-time checks out of the public non-entity projection") {
                let featureId = "project_credits"
                let entityId = "project-123"

                await mockApi.setCheckFeatureResponse(
                    FeatureCheckResult(
                        customerId: "customer-123",
                        featureId: featureId,
                        requiredBalance: 1,
                        code: "allowed",
                        allowed: true,
                        unlimited: false,
                        balance: 3,
                        type: .metered,
                        preview: nil
                    )
                )

                let result = try await featureService.check(
                    featureId: featureId,
                    requiredBalance: 1,
                    entityId: entityId
                )
                let entityCached = await featureService.getCached(featureId: featureId, entityId: entityId)
                let rootCached = await featureService.getCached(featureId: featureId, entityId: nil)
                let projected = await MainActor.run { Container.shared.featureInfo().feature(featureId) }

                expect(result.balance).to(equal(3))
                expect(entityCached?.balance).to(equal(3))
                expect(rootCached).to(beNil())
                expect(projected).to(beNil())
            }
        }
    }

    private static func makeProfileResponse(features: [Feature]) -> ProfileResponse {
        ProfileResponse(
            campaigns: [],
            segments: [],
            flows: [],
            userProperties: nil,
            experiments: nil,
            features: features,
            journeys: nil
        )
    }

    private static func makeFeature(
        id: String,
        type: FeatureType,
        balance: Int?,
        unlimited: Bool,
        entities: [String: EntityBalance]? = nil
    ) -> Feature {
        Feature(
            id: id,
            type: type,
            balance: balance,
            unlimited: unlimited,
            nextResetAt: nil,
            interval: nil,
            entities: entities
        )
    }
}
