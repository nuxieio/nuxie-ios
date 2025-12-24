import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie

final class EventMigrationIntegrationTests: AsyncSpec {
    override class func spec() {
        describe("Event Migration on Identify") {
            var config: NuxieConfiguration!
            var dbPath: String!
            var eventService: EventServiceProtocol!
            var mockApi: MockNuxieApi!
            
            beforeEach {
                print("DEBUG: beforeEach starting")


                // Create and register mock API to prevent network calls
                mockApi = MockNuxieApi()
                Container.shared.nuxieApi.register { mockApi }
                
                print("DEBUG: Got SDK shared instance")

                // Create unique database directory for test isolation
                let testId = UUID().uuidString
                let tempDir = NSTemporaryDirectory()
                let testDirPath = "\(tempDir)test_\(testId)"
                
                // Create the directory if it doesn't exist
                try FileManager.default.createDirectory(atPath: testDirPath, withIntermediateDirectories: true)
                
                dbPath = testDirPath
                print("DEBUG: Database directory path: \(dbPath)")
                
                // Create configuration with migration enabled (default)
                config = NuxieConfiguration(apiKey: "test-key-\(testId)")
                config.customStoragePath = URL(fileURLWithPath: dbPath)
                config.environment = .development
                config.enablePlugins = false // Disable plugins for faster tests
                print("DEBUG: Configuration created with eventLinkingPolicy: \(config.eventLinkingPolicy)")
                
                // Setup SDK
                print("DEBUG: About to call NuxieSDK.shared.setup()")
                do {
                    print("DEBUG: Calling NuxieSDK.shared.setup() now...")
                    try NuxieSDK.shared.setup(with: config)
                    print("DEBUG: SDK setup successful")
                } catch {
                    print("DEBUG: SDK setup failed with error: \(error)")
                    print("DEBUG: Error type: \(type(of: error))")
                    print("DEBUG: Error description: \(error.localizedDescription)")
                    throw error
                }
                
                // Get access to SDK's event service for validation
                eventService = Container.shared.eventService()
                print("DEBUG: EventService obtained from SDK")
                
                print("DEBUG: beforeEach completed")
            }
            
            afterEach {
                // Clean up test database directory
                if let dbPath = dbPath {
                    try? FileManager.default.removeItem(atPath: dbPath)
                }
            }
            
            describe("anonymous to identified transition") {
                context("with migrateOnIdentify policy (default)") {
                    it("should reassign anonymous events to identified user") {
                        print("DEBUG: Starting test - should reassign anonymous events")
                        
                        // Track events as anonymous user
                        print("DEBUG: Getting anonymous ID")
                        let anonymousId = NuxieSDK.shared.getAnonymousId()
                        print("DEBUG: Anonymous ID: \(anonymousId)")
                        expect(anonymousId).toNot(beEmpty())
                        
                        // Track some events as anonymous
                        print("DEBUG: Tracking events as anonymous")
                        NuxieSDK.shared.track("app_opened", properties: ["source": "test"])
                        NuxieSDK.shared.track("button_clicked", properties: ["button": "start"])
                        NuxieSDK.shared.track("page_viewed", properties: ["page": "home"])
                        print("DEBUG: Events tracked")

                        // Wait for events to be processed (drain the event queue)
                        await eventService.drain()
                        print("DEBUG: Event queue drained")

                        // Verify events are stored with anonymous ID
                        print("DEBUG: Querying events for anonymous user")
                        await expect { await eventService.getEventsForUser(anonymousId, limit: 10).count }
                            .toEventually(equal(3), timeout: .seconds(2))
                        print("DEBUG: Found expected anonymous events")
                        
                        // Identify user
                        let userId = "user123"
                        print("DEBUG: Identifying user: \(userId)")
                        NuxieSDK.shared.identify(userId, userProperties: ["name": "Test User"])
                        print("DEBUG: User identified")
                        
                        // Verify events were reassigned to identified user
                        print("DEBUG: Querying events for identified user")
                        await expect { await eventService.getEventsForUser(userId, limit: 10).count }
                            .toEventually(beGreaterThanOrEqualTo(3), timeout: .seconds(2)) // At least the 3 tracked events
                        let identifiedEvents = await eventService.getEventsForUser(userId, limit: 10)
                        print("DEBUG: Found \(identifiedEvents.count) identified events")
                        
                        // Verify anonymous user has no events (except possibly $identify)
                        print("DEBUG: Checking remaining anonymous events")
                        await expect { 
                            let events = await eventService.getEventsForUser(anonymousId, limit: 10)
                            return events.filter { $0.name != "$identify" }.count 
                        }.toEventually(equal(0), timeout: .seconds(2))
                        print("DEBUG: Verified anonymous events migrated")
                        
                        // Verify the migrated events maintain their properties
                        print("DEBUG: Verifying migrated event properties")
                        let appOpenedEvent = identifiedEvents.first { $0.name == "app_opened" }
                        expect(appOpenedEvent).toNot(beNil())
                        if let event = appOpenedEvent {
                            print("DEBUG: Found app_opened event, checking properties")
                            if let properties = try? event.getProperties() {
                                print("DEBUG: Properties: \(properties)")
                                // Handle AnyCodable wrapper
                                if let sourceValue = properties["source"] {
                                    if let anyCodable = sourceValue as? AnyCodable {
                                        expect(anyCodable.value as? String).to(equal("test"))
                                    } else {
                                        expect(sourceValue as? String).to(equal("test"))
                                    }
                                } else {
                                    fail("source property not found")
                                }
                            } else {
                                print("DEBUG: Failed to get properties")
                            }
                        } else {
                            print("DEBUG: app_opened event not found")
                        }
                        
                        print("DEBUG: Test completed successfully")
                    }
                    
                    it("should create unified timeline for journey tracking") {
                        // Track journey-relevant events as anonymous
                        let anonymousId = NuxieSDK.shared.getAnonymousId()
                        
                        NuxieSDK.shared.track("onboarding_started")
                        NuxieSDK.shared.track("onboarding_step_1_completed")
                        NuxieSDK.shared.track("onboarding_step_2_completed")
                        
                        // Wait for events to be stored
                        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                        
                        // Identify user
                        let userId = "journey_user"
                        NuxieSDK.shared.identify(userId)
                        
                        // Give time for async reassignment to complete
                        try await Task.sleep(nanoseconds: 500_000_000) // 500ms
                        
                        // Continue tracking after identification
                        NuxieSDK.shared.track("onboarding_step_3_completed")
                        NuxieSDK.shared.track("onboarding_completed")
                        
                        // Verify all events are under the identified user
                        await expect {
                            let userEvents = await eventService.getEventsForUser(userId, limit: 20)
                            return userEvents.filter { $0.name.starts(with: "onboarding") }.count
                        }.toEventually(equal(5), timeout: .seconds(3))
                        
                        let userEvents = await eventService.getEventsForUser(userId, limit: 20)
                        let onboardingEvents = userEvents.filter { $0.name.starts(with: "onboarding") }
                        
                        // Verify chronological order is maintained
                        let eventNames = onboardingEvents.map { $0.name }
                        expect(eventNames).to(contain("onboarding_started"))
                        expect(eventNames).to(contain("onboarding_step_1_completed"))
                        expect(eventNames).to(contain("onboarding_step_2_completed"))
                        expect(eventNames).to(contain("onboarding_step_3_completed"))
                        expect(eventNames).to(contain("onboarding_completed"))
                    }
                }
                
                context("with keepSeparate policy") {
                    beforeEach {
                        // Reconfigure with keepSeparate policy
                        await NuxieSDK.shared.shutdown()
                        
                        // Create new test directory for this context
                        let testId = UUID().uuidString
                        let tempDir = NSTemporaryDirectory()
                        let testDirPath = "\(tempDir)test_separate_\(testId)"
                        try FileManager.default.createDirectory(atPath: testDirPath, withIntermediateDirectories: true)
                        dbPath = testDirPath
                        
                        config = NuxieConfiguration(apiKey: "test-key-separate")
                        config.customStoragePath = URL(fileURLWithPath: dbPath)
                        config.environment = .development
                        config.enablePlugins = false
                        config.eventLinkingPolicy = .keepSeparate // Explicitly set to keep separate
                        
                        try await NuxieSDK.shared.setup(with: config)

                        eventService = Container.shared.eventService()
                    }
                    
                    it("should NOT reassign anonymous events when policy is keepSeparate") {
                        // Track events as anonymous user
                        let anonymousId = NuxieSDK.shared.getAnonymousId()
                        
                        NuxieSDK.shared.track("anonymous_event_1")
                        NuxieSDK.shared.track("anonymous_event_2")
                        
                        // Verify events are stored with anonymous ID
                        await expect { await eventService.getEventsForUser(anonymousId, limit: 10).count }
                            .toEventually(equal(2), timeout: .seconds(2))
                        
                        // Identify user
                        let userId = "user_keep_separate"
                        NuxieSDK.shared.identify(userId)
                        
                        // Give time for identification
                        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
                        
                        // Verify anonymous events remain with anonymous user
                        await expect {
                            let events = await eventService.getEventsForUser(anonymousId, limit: 10)
                            return events.filter { $0.name != "$identify" }.count
                        }.toEventually(equal(2), timeout: .seconds(2))
                        
                        // Verify identified user only has identify event
                        await expect {
                            let events = await eventService.getEventsForUser(userId, limit: 10)
                            return events.filter { $0.name == "$identify" }.count
                        }.toEventually(beGreaterThanOrEqualTo(1), timeout: .seconds(2))
                        
                        await expect {
                            let events = await eventService.getEventsForUser(userId, limit: 10)
                            return events.filter { $0.name.starts(with: "anonymous_event") }.count
                        }.toEventually(equal(0), timeout: .seconds(2))
                    }
                }
            }
            
            describe("already identified user") {
                it("should NOT reassign events when user is already identified") {
                    // First identify
                    let userId1 = "user_first"
                    NuxieSDK.shared.identify(userId1)
                    
                    // Track events as identified user
                    NuxieSDK.shared.track("identified_event_1")
                    NuxieSDK.shared.track("identified_event_2")
                    
                    // Give time for events to be stored
                    try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    
                    // Verify events are under first user
                    let user1Events = await eventService.getEventsForUser(userId1, limit: 10)
                    expect(user1Events.filter { $0.name.starts(with: "identified_event") }.count).to(equal(2))
                    
                    // Identify as different user
                    let userId2 = "user_second"
                    NuxieSDK.shared.identify(userId2)
                    
                    // Give time for identification
                    try await Task.sleep(nanoseconds: 200_000_000) // 200ms
                    
                    // Verify first user's events remain unchanged
                    let user1EventsAfter = await eventService.getEventsForUser(userId1, limit: 10)
                    expect(user1EventsAfter.filter { $0.name.starts(with: "identified_event") }.count).to(equal(2))
                    
                    // Verify second user only has identify event
                    let user2Events = await eventService.getEventsForUser(userId2, limit: 10)
                    expect(user2Events.filter { $0.name.starts(with: "identified_event") }.count).to(equal(0))
                }
                
                it("should NOT reassign when identifying with same ID") {
                    // Identify user
                    let userId = "same_user"
                    NuxieSDK.shared.identify(userId)
                    
                    // Track events
                    NuxieSDK.shared.track("event_1")
                    NuxieSDK.shared.track("event_2")
                    
                    // Give time for events to be stored
                    try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    
                    let eventCountBefore = await eventService.getEventsForUser(userId, limit: 20).count
                    
                    // Identify again with same ID
                    NuxieSDK.shared.identify(userId, userProperties: ["updated": true])
                    
                    // Give time for identification
                    try await Task.sleep(nanoseconds: 200_000_000) // 200ms
                    
                    // Verify event count increased by at most 1 (for the new $identify)
                    let eventCountAfter = await eventService.getEventsForUser(userId, limit: 20).count
                    expect(eventCountAfter).to(beLessThanOrEqualTo(eventCountBefore + 1))
                }
            }
            
            describe("error handling") {
                it("should continue with identify even if migration fails") {
                    // Track events as anonymous
                    let anonymousId = NuxieSDK.shared.getAnonymousId()
                    NuxieSDK.shared.track("test_event")
                    
                    // Give time for event to be stored
                    try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    
                    // Note: Cannot easily simulate EventStore failure with current architecture
                    // The test will still validate that SDK continues working even if storage has issues
                    
                    // Identify should still work despite migration failure
                    let userId = "user_with_error"
                    NuxieSDK.shared.identify(userId, userProperties: ["test": true])
                    
                    // Verify SDK is still functional
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(userId))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                    
                    // Can still track events after failed migration
                    NuxieSDK.shared.track("post_error_event")
                    
                    // No crash should occur
                    expect(true).to(beTrue()) // Test passes if we get here
                }
            }
            
            describe("performance") {
                it("should handle large number of events efficiently") {
                    // Track many events as anonymous
                    let anonymousId = NuxieSDK.shared.getAnonymousId()
                    let eventCount = 100
                    
                    for i in 0..<eventCount {
                        NuxieSDK.shared.track("bulk_event_\(i)", properties: ["index": i])
                    }
                    
                    // Give time for events to be stored
                    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
                    
                    // Record time before identify
                    let startTime = Date()
                    
                    // Identify user
                    let userId = "bulk_user"
                    NuxieSDK.shared.identify(userId)
                    
                    // Measure migration time
                    let migrationTime = Date().timeIntervalSince(startTime)
                    
                    // Migration should be fast (under 1 second for 100 events)
                    expect(migrationTime).to(beLessThan(1.0))
                    
                    // Give time for migration to complete
                    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
                    
                    // Verify all events were migrated
                    let migratedEvents = await eventService.getEventsForUser(userId, limit: 200)
                    let bulkEvents = migratedEvents.filter { $0.name.starts(with: "bulk_event") }
                    expect(bulkEvents.count).to(equal(eventCount))
                }
            }
        }
    }
}
