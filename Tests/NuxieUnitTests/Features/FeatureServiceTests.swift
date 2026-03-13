import Quick
import Nimble
@testable import Nuxie
@testable import NuxieTestSupport

final class FeatureServiceTests: AsyncSpec {
    override class func spec() {
        describe("FeatureService") {
            var featureService: FeatureService!
            var mockFactory: MockFactory!
            var mockProfileService: MockProfileService!
            var mockIdentityService: MockIdentityService!

            beforeEach {
                mockFactory = MockFactory.shared
                mockFactory.registerAll()

                featureService = FeatureService()
                mockProfileService = mockFactory.profileService
                mockIdentityService = mockFactory.identityService
                mockIdentityService.setDistinctId("customer-123")
            }

            it("prefers purchase-synced access over stale profile cache") {
                let featureId = "premium_export"

                mockProfileService.setProfileResponse(
                    Self.makeProfileResponse(
                        feature: Feature(
                            id: featureId,
                            type: .metered,
                            balance: 0,
                            unlimited: false,
                            nextResetAt: nil,
                            interval: nil,
                            entities: nil
                        )
                    )
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
                let featureId = "team_members"

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
        }
    }

    private static func makeProfileResponse(feature: Feature) -> ProfileResponse {
        ProfileResponse(
            campaigns: [],
            segments: [],
            flows: [],
            userProperties: nil,
            experiments: nil,
            features: [feature],
            journeys: nil
        )
    }
}
