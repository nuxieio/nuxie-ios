import Foundation
import Quick
import Nimble
@testable import Nuxie

final class JourneyCodableTests: AsyncSpec {
    override class func spec() {
        describe("Journey Codable") {
            it("should encode and decode with ConversionAnchor enum") {
                // Create a campaign with conversion anchor
                let campaign = TestCampaignBuilder(id: "test-campaign")
                    .withName("Test Campaign")
                    .withConversionAnchor(ConversionAnchor.lastFlowShown.rawValue)
                    .build()
                
                // Create journey
                let journey = Journey(campaign: campaign, distinctId: "test-user")
                
                // Verify the conversion anchor was set correctly
                expect(journey.conversionAnchor).to(equal(.lastFlowShown))
                
                // Encode journey
                let encoder = JSONEncoder()
                let data = try encoder.encode(journey)
                
                // Decode journey
                let decoder = JSONDecoder()
                let decodedJourney = try decoder.decode(Journey.self, from: data)
                
                // Verify all properties match
                expect(decodedJourney.id).to(equal(journey.id))
                expect(decodedJourney.conversionAnchor).to(equal(.lastFlowShown))
                expect(decodedJourney.campaignId).to(equal(journey.campaignId))
                expect(decodedJourney.distinctId).to(equal(journey.distinctId))
            }
            
            it("should handle default conversion anchor") {
                // Create a campaign without conversion anchor
                let campaign = TestCampaignBuilder(id: "test-campaign")
                    .withName("Test Campaign")
                    .build()
                
                // Create journey
                let journey = Journey(campaign: campaign, distinctId: "test-user")
                
                // Should default to workflowEntry
                expect(journey.conversionAnchor).to(equal(.workflowEntry))
                
                // Encode and decode
                let encoder = JSONEncoder()
                let data = try encoder.encode(journey)
                let decoder = JSONDecoder()
                let decodedJourney = try decoder.decode(Journey.self, from: data)
                
                expect(decodedJourney.conversionAnchor).to(equal(.workflowEntry))
            }
            
            it("should handle invalid conversion anchor string") {
                // Create a campaign with invalid conversion anchor
                let campaign = TestCampaignBuilder(id: "test-campaign")
                    .withName("Test Campaign")
                    .withConversionAnchor("invalid_anchor")
                    .build()
                
                // Create journey
                let journey = Journey(campaign: campaign, distinctId: "test-user")
                
                // Should default to workflowEntry for invalid values
                expect(journey.conversionAnchor).to(equal(.workflowEntry))
            }
        }
    }
}