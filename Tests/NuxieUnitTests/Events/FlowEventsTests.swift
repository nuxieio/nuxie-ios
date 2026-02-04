import Foundation
import Quick
import Nimble
@testable import Nuxie

final class FlowEventsTests: AsyncSpec {
    override class func spec() {
        describe("Flow events") {
            var journey: Journey!

            beforeEach {
                journey = TestJourneyBuilder(id: "test-journey-123")
                    .withCampaignId("test-campaign-456")
                    .build()
            }

            it("flowShownProperties includes ids") {
                let properties = JourneyEvents.flowShownProperties(
                    flowId: "flow-abc",
                    journey: journey
                )

                expect(properties["journey_id"] as? String).to(equal(journey.id))
                expect(properties["campaign_id"] as? String).to(equal(journey.campaignId))
                expect(properties["flow_id"] as? String).to(equal("flow-abc"))
            }

            it("flowPurchasedProperties includes product id when provided") {
                let properties = JourneyEvents.flowPurchasedProperties(
                    flowId: "flow-abc",
                    journey: journey,
                    productId: "product-123"
                )

                expect(properties["product_id"] as? String).to(equal("product-123"))
            }

            it("flowErroredProperties includes error message when provided") {
                let properties = JourneyEvents.flowErroredProperties(
                    flowId: "flow-abc",
                    journey: journey,
                    errorMessage: "oops"
                )

                expect(properties["error_message"] as? String).to(equal("oops"))
            }
        }
    }
}
