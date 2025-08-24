import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie

final class GoalEvaluatorTests: AsyncSpec {
    override class func spec() {
        describe("GoalEvaluator") {
            var evaluator: GoalEvaluator!
            var mockEventService: MockEventService!
            var mockSegmentService: MockSegmentService!
            var mockIdentityService: MockIdentityService!
            var mockDateProvider: MockDateProvider!
            var journey: Journey!
            var campaign: Campaign!
            
            beforeEach {
                // Reset container and singletons to ensure clean slate
                Container.shared.reset()
                
                // Set up mocks
                mockEventService = MockEventService()
                mockSegmentService = MockSegmentService()
                mockIdentityService = MockIdentityService()
                mockDateProvider = MockDateProvider()
                
                // Register mocks
                Container.shared.eventService.register { mockEventService }
                Container.shared.segmentService.register { mockSegmentService }
                Container.shared.identityService.register { mockIdentityService }
                Container.shared.dateProvider.register { mockDateProvider }
                
                // Create evaluator
                evaluator = GoalEvaluator()
                
                // Create test campaign with default goal
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
                            "eventName": "app_opened"
                        }
                    },
                    "entryNodeId": "node1",
                    "workflow": {
                        "nodes": []
                    },
                    "goal": {
                        "kind": "event",
                        "eventName": "purchase",
                        "window": 86400
                    },
                    "exitPolicy": {
                        "mode": "on_goal"
                    }
                }
                """.data(using: .utf8)!
                
                let decoder = JSONDecoder()
                campaign = try! decoder.decode(Campaign.self, from: campaignJSON)
                journey = Journey(campaign: campaign, distinctId: "test-user")
            }
            
            describe("Event Goals") {
                context("when event goal is configured") {
                    it("should detect goal met when event exists after anchor") {
                        // Set up event in the future
                        let eventTime = mockDateProvider.now().addingTimeInterval(60)
                        mockEventService.setLastEventTime(
                            name: "purchase",
                            distinctId: "test-user",
                            time: eventTime
                        )
                        
                        let result = await evaluator.isGoalMet(journey: journey, campaign: campaign)
                        
                        await expect(result.met).to(beTrue())
                        await expect(result.at).to(equal(eventTime))
                    }
                    
                    it("should not detect goal when event is before anchor") {
                        // Set up event in the past
                        let eventTime = journey.conversionAnchorAt.addingTimeInterval(-60)
                        mockEventService.setLastEventTime(
                            name: "purchase",
                            distinctId: "test-user",
                            time: eventTime
                        )
                        
                        let result = await evaluator.isGoalMet(journey: journey, campaign: campaign)
                        
                        await expect(result.met).to(beFalse())
                        await expect(result.at).to(beNil())
                    }
                    
                    it("should respect conversion window") {
                        // Move 'now' beyond window (late evaluation)
                        mockDateProvider.advance(by: 86401) // 1 day + 1 second
                        
                        // The event happened inside the window (event-time semantics should count it)
                        let eventTime = journey.conversionAnchorAt.addingTimeInterval(60)
                        mockEventService.setLastEventTime(
                            name: "purchase",
                            distinctId: "test-user",
                            time: eventTime
                        )
                        
                        let result = await evaluator.isGoalMet(journey: journey, campaign: campaign)
                        
                        await expect(result.met).to(beTrue())
                        await expect(result.at).to(equal(eventTime))
                    }
                    
                    it("should NOT count event if event timestamp is outside the window") {
                        // Window = 1 day (already in campaign JSON)
                        // Event happened AFTER the window ended
                        let lateEventTime = journey.conversionAnchorAt.addingTimeInterval(86400 + 10)
                        mockEventService.setLastEventTime(
                            name: "purchase",
                            distinctId: "test-user",
                            time: lateEventTime
                        )
                        
                        let result = await evaluator.isGoalMet(journey: journey, campaign: campaign)
                        
                        await expect(result.met).to(beFalse())
                        await expect(result.at).to(beNil())
                    }
                    
                    it("should handle missing event name") {
                        // Create goal without event name
                        journey.goalSnapshot = GoalConfig(kind: .event)
                        
                        let result = await evaluator.isGoalMet(journey: journey, campaign: campaign)
                        
                        await expect(result.met).to(beFalse())
                        await expect(result.at).to(beNil())
                    }
                }
            }
            
            describe("Segment Goals") {
                context("segment enter goal") {
                    beforeEach {
                        journey.goalSnapshot = GoalConfig(
                            kind: .segmentEnter,
                            segmentId: "premium-users"
                        )
                    }
                    
                    it("should detect goal when user is in segment") {
                        await mockSegmentService.setMembership("premium-users", isMember: true)
                        
                        let result = await evaluator.isGoalMet(journey: journey, campaign: campaign)
                        
                        await expect(result.met).to(beTrue())
                        await expect(result.at).toNot(beNil())
                    }
                    
                    it("should not detect goal when user is not in segment") {
                        await mockSegmentService.setMembership("premium-users", isMember: false)
                        
                        let result = await evaluator.isGoalMet(journey: journey, campaign: campaign)
                        
                        await expect(result.met).to(beFalse())
                    }
                }
                
                context("segment leave goal") {
                    beforeEach {
                        journey.goalSnapshot = GoalConfig(
                            kind: .segmentLeave,
                            segmentId: "trial-users"
                        )
                    }
                    
                    it("should detect goal when user left segment") {
                        await mockSegmentService.setMembership("trial-users", isMember: false)
                        
                        let result = await evaluator.isGoalMet(journey: journey, campaign: campaign)
                        
                        await expect(result.met).to(beTrue())
                        await expect(result.at).toNot(beNil())
                    }
                    
                    it("should not detect goal when user is still in segment") {
                        await mockSegmentService.setMembership("trial-users", isMember: true)
                        
                        let result = await evaluator.isGoalMet(journey: journey, campaign: campaign)
                        
                        await expect(result.met).to(beFalse())
                    }
                }
            }
            
            describe("Attribute Goals") {
                beforeEach {
                    // Create IR expression for testing
                    // Note: the value parameter in IRExpr.user expects an IRExpr, not IRValue
                    // Use "eq" operator instead of "==" as that's what IRInterpreter expects
                    let expr = IRExpr.user(op: "eq", key: "subscription_status", value: IRExpr.string("premium"))
                    journey.goalSnapshot = GoalConfig(
                        kind: .attribute,
                        attributeExpr: IREnvelope(
                            ir_version: 1,
                            engine_min: nil,
                            compiled_at: nil,
                            expr: expr
                        )
                    )
                }
                
                it("should detect goal when attribute condition is met") {
                    mockIdentityService.setUserProperty("subscription_status", value: "premium")
                    
                    let result = await evaluator.isGoalMet(journey: journey, campaign: campaign)
                    
                    await expect(result.met).to(beTrue())
                    await expect(result.at).toNot(beNil())
                }
                
                it("should not detect goal when attribute condition is not met") {
                    mockIdentityService.setUserProperty("subscription_status", value: "free")
                    
                    let result = await evaluator.isGoalMet(journey: journey, campaign: campaign)
                    
                    await expect(result.met).to(beFalse())
                }
            }
            
            describe("Conversion Window") {
                it("should allow conversion within window") {
                    // Set window to 1 hour
                    journey.conversionWindow = 3600
                    
                    // Advance time by 30 minutes
                    mockDateProvider.advance(by: 1800)
                    
                    // Set up event
                    let eventTime = mockDateProvider.now()
                    mockEventService.setLastEventTime(
                        name: "purchase",
                        distinctId: "test-user",
                        time: eventTime
                    )
                    
                    let result = await evaluator.isGoalMet(journey: journey, campaign: campaign)
                    
                    await expect(result.met).to(beTrue())
                }
                
                it("should block conversion outside window") {
                    // Set window to 1 hour
                    journey.conversionWindow = 3600
                    
                    // Advance time beyond window
                    mockDateProvider.advance(by: 3601)
                    
                    // Set up event
                    let eventTime = mockDateProvider.now()
                    mockEventService.setLastEventTime(
                        name: "purchase",
                        distinctId: "test-user",
                        time: eventTime
                    )
                    
                    let result = await evaluator.isGoalMet(journey: journey, campaign: campaign)
                    
                    await expect(result.met).to(beFalse())
                }
                
                it("should handle zero window (no limit)") {
                    journey.conversionWindow = 0
                    
                    // Advance time far into future
                    mockDateProvider.advance(by: 86400 * 30) // 30 days
                    
                    // Set up event
                    let eventTime = mockDateProvider.now()
                    mockEventService.setLastEventTime(
                        name: "purchase",
                        distinctId: "test-user",
                        time: eventTime
                    )
                    
                    let result = await evaluator.isGoalMet(journey: journey, campaign: campaign)
                    
                    await expect(result.met).to(beTrue())
                }
            }
            
            describe("No Goal Configuration") {
                it("should return false when no goal is configured") {
                    journey.goalSnapshot = nil
                    
                    let result = await evaluator.isGoalMet(journey: journey, campaign: campaign)
                    
                    await expect(result.met).to(beFalse())
                    await expect(result.at).to(beNil())
                }
            }
        }
    }
}
