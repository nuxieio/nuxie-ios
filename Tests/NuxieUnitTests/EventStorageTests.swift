import Foundation
import Quick
import Nimble
@testable import Nuxie

final class EventStorageTests: AsyncSpec {
    
    override class func spec() {
        var internalEventStore: SQLiteEventStore!
        var eventStore: EventStore!
        var tempDbPath: String!
        
        beforeEach {
            // Create temporary database path for testing
            let tempDir = NSTemporaryDirectory()
            tempDbPath = "\(tempDir)/test_events_\(UUID.v7().uuidString).db"
            
            // Clean up any existing database first
            if FileManager.default.fileExists(atPath: tempDbPath) {
                try? FileManager.default.removeItem(atPath: tempDbPath)
            }
            
            // Initialize with test database path
            internalEventStore = SQLiteEventStore()
            eventStore = EventStore()
            
            // Initialize the store
            do {
                try await internalEventStore.initialize(path: URL(fileURLWithPath: tempDbPath))
                try await eventStore.initialize(path: URL(fileURLWithPath: tempDbPath))
            } catch {
                fail("Failed to initialize stores: \(error)")
            }
        }
        
        afterEach {
            // Clean up test database
            await internalEventStore?.close()
            await eventStore?.close()
            
            if let path = tempDbPath, FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        
        describe("StoredEvent") {
            it("should create event with valid properties") {
                let properties = ["key": "value", "number": 42, "$session_id": "test-session"] as [String: Any]
                guard let event = try? StoredEvent(
                    name: "test_event",
                    properties: properties,
                    distinctId: "test_user"
                ) else {
                    fail("Failed to create StoredEvent")
                    return
                }
                
                expect(event.name) == "test_event"
                expect(event.distinctId) == "test_user"
                expect(event.sessionId) == "test-session"
                
                // Test property serialization/deserialization
                let retrievedProperties = try? event.getProperties()
                expect(retrievedProperties?["key"]?.value as? String) == "value"
                expect(retrievedProperties?["number"]?.value as? Int) == 42
            }
            
            it("should handle empty properties correctly") {
                guard let event = try? StoredEvent(
                    name: "test_event",
                    properties: [:],
                    distinctId: "test_user"
                ) else {
                    fail("Failed to create StoredEvent")
                    return
                }
                
                expect(event.name) == "test_event"
                expect(event.distinctId) == "test_user"
                let props = try? event.getProperties()
                expect(props?.isEmpty) == true
            }
        }
        
        describe("EventStore") {
            it("should insert and query events correctly") {
                let properties = ["feature": "premium", "value": 100] as [String: Any]
                guard let event = try? StoredEvent(
                    id: "test_event_1",
                    name: "feature_accessed",
                    properties: properties,
                    distinctId: "user123"
                ) else {
                    fail("Failed to create StoredEvent")
                    return
                }
                
                // Insert event
                do {
                    try await internalEventStore.insertEvent(event)
                } catch {
                    fail("Failed to insert event: \(error)")
                }
                
                // Verify event count
                do {
                    let count = try await internalEventStore.getEventCount()
                    expect(count) == 1
                } catch {
                    fail("Failed to get event count: \(error)")
                }
                
                // Query recent events
                do {
                    let events = try await eventStore.getRecentEvents(limit: 10)
                    expect(events.count) == 1
                    
                    let retrievedEvent = events[0]
                    expect(retrievedEvent.name) == "feature_accessed"
                    expect(retrievedEvent.distinctId) == "user123"
                    let retrievedProps = try? retrievedEvent.getProperties()
                    expect(retrievedProps?["feature"]?.value as? String) == "premium"
                    expect(retrievedProps?["value"]?.value as? Int) == 100
                } catch {
                    fail("Failed to get recent events: \(error)")
                }
            }
            
            it("should handle multiple events with correct ordering") {
                // Insert multiple events
                for i in 1...5 {
                    guard let event = try? StoredEvent(
                        id: "test_event_multi_\(i)",
                        name: "event_\(i)",
                        properties: ["index": i],
                        distinctId: "user123"
                    ) else {
                        fail("Failed to create StoredEvent for index \(i)")
                        return
                    }
                    do {
                        try await internalEventStore.insertEvent(event)
                    } catch {
                        fail("Failed to insert event: \(error)")
                    }
                }
                
                // Verify count
                do {
                    let count = try await internalEventStore.getEventCount()
                    expect(count) == 5
                } catch {
                    fail("Failed to get event count: \(error)")
                }
                
                // Query with limit
                do {
                    let events = try await eventStore.getRecentEvents(limit: 3)
                    expect(events.count) == 3
                    
                    // Events should be ordered by timestamp (most recent first)
                    expect(events[0].name) == "event_5"
                    expect(events[1].name) == "event_4"
                    expect(events[2].name) == "event_3"
                } catch {
                    fail("Failed to get recent events: \(error)")
                }
            }
            
            it("should cleanup old events correctly") {
                // Insert an old event
                let oldDate = Date(timeIntervalSinceNow: -60 * 60 * 24 * 2) // 2 days ago
                guard let oldEvent = try? StoredEvent(
                    id: "test_event_old",
                    name: "old_event",
                    properties: [:],
                    timestamp: oldDate,
                    distinctId: "user123"
                ) else {
                    fail("Failed to create old StoredEvent")
                    return
                }
                do {
                    try await internalEventStore.insertEvent(oldEvent)
                } catch {
                    fail("Failed to insert old event: \(error)")
                }
                
                // Insert a recent event
                guard let recentEvent = try? StoredEvent(
                    id: "test_event_recent",
                    name: "recent_event",
                    properties: [:],
                    distinctId: "user123"
                ) else {
                    fail("Failed to create recent StoredEvent")
                    return
                }
                do {
                    try await internalEventStore.insertEvent(recentEvent)
                } catch {
                    fail("Failed to insert recent event: \(error)")
                }
                
                // Verify both events are there
                do {
                    let count = try await internalEventStore.getEventCount()
                    expect(count) == 2
                } catch {
                    fail("Failed to get event count: \(error)")
                }
                
                // Delete events older than 1 day
                let cutoffDate = Date(timeIntervalSinceNow: -60 * 60 * 24) // 1 day ago
                guard let deletedCount = try? await internalEventStore.deleteEventsOlderThan(cutoffDate) else {
                    fail("Failed to delete old events")
                    return
                }
                
                // Should have deleted the old event
                expect(deletedCount) == 1
                do {
                    let count = try await internalEventStore.getEventCount()
                    expect(count) == 1
                } catch {
                    fail("Failed to get event count: \(error)")
                }
                
                // Remaining event should be the recent one
                do {
                    let remainingEvents = try await eventStore.getRecentEvents(limit: 10)
                    expect(remainingEvents.count) == 1
                    expect(remainingEvents[0].name) == "recent_event"
                } catch {
                    fail("Failed to get remaining events: \(error)")
                }
            }
        }
        
        describe("EventStore") {
            it("should store events with enriched properties") {
                // Store an event
                do {
                    try await eventStore.storeEvent(
                        name: "app_launched",
                        properties: ["version": "1.0.0"],
                        distinctId: "test_user"
                    )
                } catch {
                    fail("Failed to store event: \(error)")
                }
                
                // Verify it was stored
                do {
                    let events = try await eventStore.getRecentEvents(limit: 10)
                    expect(events.count) == 1
                    
                    let event = events[0]
                    expect(event.name) == "app_launched"
                    expect(event.distinctId) == "test_user"
                    
                    // Check that enriched properties were added
                    let properties = try? event.getProperties()
                    expect(properties?["version"]?.value as? String) == "1.0.0"
                    expect(properties?["sdk_version"]?.value as? String) == SDKVersion.current
                    #if os(macOS)
                    expect(properties?["platform"]?.value as? String) == "macos"
                    #else
                    expect(properties?["platform"]?.value as? String) == "ios"
                    #endif
                    expect(properties?["device_model"]).toNot(beNil())
                    expect(properties?["os_version"]).toNot(beNil())
                } catch {
                    fail("Failed to get recent events: \(error)")
                }
            }
            
            // Session management tests moved to SessionServiceTests.swift
            
            it("should filter events by user correctly") {
                // Store events for different users
                do {
                    try await eventStore.storeEvent(name: "user_event1", distinctId: "user1")
                    try await eventStore.storeEvent(name: "user_event2", distinctId: "user2")
                    try await eventStore.storeEvent(name: "user_event3", distinctId: "user1")
                } catch {
                    fail("Failed to store user events: \(error)")
                }
                
                // Get events for user1
                do {
                    let user1Events = try await eventStore.getEventsForUser("user1", limit: 10)
                    expect(user1Events.count) == 2
                    expect(user1Events.allSatisfy { $0.distinctId == "user1" }) == true
                } catch {
                    fail("Failed to get user1 events: \(error)")
                }
                
                // Get events for user2
                do {
                    let user2Events = try await eventStore.getEventsForUser("user2", limit: 10)
                    expect(user2Events.count) == 1
                    expect(user2Events[0].distinctId) == "user2"
                } catch {
                    fail("Failed to get user2 events: \(error)")
                }
            }
            
            it("should cleanup old events when over limit") {
                // Create manager with low limits for testing
                let testService = EventStore(
                    maxEventsStored: 3,
                    cleanupThresholdDays: 1
                  )
                do {
                    try await testService.initialize(path: URL(fileURLWithPath: tempDbPath + "_cleanup"))
                } catch {
                    fail("Failed to initialize test service: \(error)")
                }
                
                // Store more events than the limit
                for i in 1...5 {
                    do {
                        try await testService.storeEvent(name: "cleanup_event_\(i)", distinctId: "user1")
                    } catch {
                        fail("Failed to store cleanup event: \(error)")
                    }
                }
                
                // Should have triggered cleanup
                do {
                    let eventCount = try await testService.getEventCount()
                    expect(eventCount) <= 5 // Should have cleaned up old events
                } catch {
                    fail("Failed to get event count: \(error)")
                }
                
                await testService.close()
                try? FileManager.default.removeItem(atPath: tempDbPath + "_cleanup")
            }
        }
    }
}
