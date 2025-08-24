import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie

final class JourneyTests: AsyncSpec {
    override class func spec() {
        describe("Journey System") {
            var journey: Journey!
            var mockDateProvider: MockDateProvider!
            
            beforeEach {
                // Set up DateProvider
                mockDateProvider = MockDateProvider()
                Container.shared.dateProvider.register { mockDateProvider }
                // Create test campaign JSON with proper structure
                let campaignJSON = """
                {
                    "id": "test-campaign",
                    "name": "Test Campaign",
                    "versionId": "v1",
                    "versionNumber": 1,
                    "frequencyPolicy": "every_rematch",
                    "publishedAt": "2024-01-01",
                    "trigger": {
                        "type": "event",
                        "config": {
                            "eventName": "test_event"
                        }
                    },
                    "entryNodeId": "node1",
                    "workflow": {
                        "nodes": []
                    }
                }
                """.data(using: .utf8)!
                
                // Decode campaign
                let decoder = JSONDecoder()
                let campaign = try! decoder.decode(Campaign.self, from: campaignJSON)
                
                // Create a test journey
                journey = Journey(campaign: campaign, distinctId: "test-user")
            }
            
            afterEach {
                Container.shared.reset()
            }
            
            describe("Journey Creation") {
                it("should create journey with correct initial state") {
                    expect(journey.id).toNot(beEmpty())
                    expect(journey.campaignId).to(equal("test-campaign"))
                    expect(journey.distinctId).to(equal("test-user"))
                    expect(journey.status).to(equal(.pending))
                    expect(journey.currentNodeId).to(equal("node1"))
                    expect(journey.context).to(beEmpty())
                }
                
                it("should have valid timestamps") {
                    expect(journey.startedAt).toNot(beNil())
                    expect(journey.updatedAt).toNot(beNil())
                    expect(journey.completedAt).to(beNil())
                }
            }
            
            describe("Journey Status Management") {
                it("should transition to active state") {
                    journey.status = .active
                    expect(journey.status.isActive).to(beTrue())
                    expect(journey.status.isTerminal).to(beFalse())
                }
                
                it("should complete with reason") {
                    journey.complete(reason: .completed)
                    expect(journey.status).to(equal(.completed))
                    expect(journey.exitReason).to(equal(.completed))
                    expect(journey.completedAt).toNot(beNil())
                    expect(journey.currentNodeId).to(beNil())
                }
                
                it("should pause with resume time") {
                    let resumeAt = mockDateProvider.now().addingTimeInterval(3600)
                    journey.pause(until: resumeAt)
                    expect(journey.status).to(equal(.paused))
                    expect(journey.resumeAt).to(equal(resumeAt))
                }
                
                it("should resume from pause") {
                    journey.pause(until: mockDateProvider.now())
                    journey.resume()
                    expect(journey.status).to(equal(.active))
                    expect(journey.resumeAt).to(beNil())
                }
            }
            
            describe("Journey Context") {
                it("should store and retrieve context values") {
                    journey.setContext("key1", value: "value1")
                    journey.setContext("key2", value: 42)
                    
                    expect(journey.getContext("key1") as? String).to(equal("value1"))
                    expect(journey.getContext("key2") as? Int).to(equal(42))
                }
                
                it("should update timestamps when context changes") {
                    let originalTime = journey.updatedAt
                    
                    // Advance mock time by 1 second
                    mockDateProvider.advance(by: 1.0)
                    
                    journey.setContext("test", value: true)
                    expect(journey.updatedAt).to(beGreaterThan(originalTime))
                }
            }
            
            describe("Journey Expiration") {
                it("should detect expired journeys") {
                    journey.expiresAt = mockDateProvider.now().addingTimeInterval(-1)
                    expect(journey.hasExpired()).to(beTrue())
                }
                
                it("should not be expired without expiration date") {
                    journey.expiresAt = nil
                    expect(journey.hasExpired()).to(beFalse())
                }
            }
        }
        
        describe("JourneyStore") {
            var store: JourneyStore!
            var testJourney: Journey!
            
            beforeEach {
                store = JourneyStore()
                
                // Create minimal test campaign
                let campaignJSON = """
                {
                    "id": "test-campaign",
                    "name": "Test",
                    "versionId": "v1",
                    "versionNumber": 1,
                    "frequencyPolicy": "once",
                    "publishedAt": "2024-01-01",
                    "trigger": {
                        "type": "event",
                        "config": {
                            "eventName": "test"
                        }
                    },
                    "entryNodeId": "node1",
                    "workflow": {
                        "nodes": []
                    }
                }
                """.data(using: .utf8)!
                
                let decoder = JSONDecoder()
                let campaign = try! decoder.decode(Campaign.self, from: campaignJSON)
                testJourney = Journey(campaign: campaign, distinctId: "test-user")
            }
            
            afterEach {
                // Clean up test files
                store.deleteJourney(id: testJourney.id)
                store.clearCache()
            }
            
            describe("Journey Persistence") {
                it("should save and load journey") {
                    do {
                        try store.saveJourney(testJourney)
                        let loaded = store.loadJourney(id: testJourney.id)
                        
                        expect(loaded).toNot(beNil())
                        expect(loaded?.id).to(equal(testJourney.id))
                        expect(loaded?.campaignId).to(equal(testJourney.campaignId))
                        expect(loaded?.distinctId).to(equal(testJourney.distinctId))
                    } catch {
                        fail("Failed to save journey: \(error)")
                    }
                }
                
                it("should load all active journeys") {
                    do {
                        try store.saveJourney(testJourney)
                        let journeys = store.loadActiveJourneys()
                        expect(journeys.contains { $0.id == testJourney.id }).to(beTrue())
                    } catch {
                        fail("Failed to save journey: \(error)")
                    }
                }
                
                it("should delete journey") {
                    do {
                        try store.saveJourney(testJourney)
                        store.deleteJourney(id: testJourney.id)
                        let loaded = store.loadJourney(id: testJourney.id)
                        expect(loaded).to(beNil())
                    } catch {
                        fail("Failed to save journey: \(error)")
                    }
                }
            }
            
            describe("Completion Tracking") {
                it("should record and check completion") {
                    testJourney.complete(reason: .completed)
                    let record = JourneyCompletionRecord(journey: testJourney)
                    
                    do {
                        try store.recordCompletion(record)
                        let hasCompleted = store.hasCompletedCampaign(
                            distinctId: testJourney.distinctId,
                            campaignId: testJourney.campaignId
                        )
                        expect(hasCompleted).to(beTrue())
                    } catch {
                        fail("Failed to record completion: \(error)")
                    }
                }
                
                it("should track last completion time") {
                    testJourney.complete(reason: .completed)
                    let record = JourneyCompletionRecord(journey: testJourney)
                    
                    do {
                        try store.recordCompletion(record)
                        let lastTime = store.lastCompletionTime(
                            distinctId: testJourney.distinctId,
                            campaignId: testJourney.campaignId
                        )
                        expect(lastTime).toNot(beNil())
                    } catch {
                        fail("Failed to record completion: \(error)")
                    }
                }
            }
        }

        describe("FrequencyPolicy") {
            it("should parse frequency policies") {
                expect(FrequencyPolicy(rawValue: "once")).to(equal(.once))
                expect(FrequencyPolicy(rawValue: "every_rematch")).to(equal(.everyRematch))
                expect(FrequencyPolicy(rawValue: "fixed_interval")).to(equal(.fixedInterval))
                expect(FrequencyPolicy(rawValue: "invalid")).to(beNil())
            }
        }
    }
}
