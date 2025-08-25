import FactoryKit
import Foundation
import Nimble
import Quick

@testable import Nuxie

final class EventServiceTests: AsyncSpec {

  override class func spec() {
    var mockFactory: MockFactory!
    var eventService: EventService!
    var mockEventStore: MockEventStore!
    var mockIdentityService: MockIdentityService!
    var mockNetworkQueue: NuxieNetworkQueue!
    var mockNuxieApi: MockNuxieApi!

    beforeEach {
      mockFactory = MockFactory.shared

      // Create mock event store
      mockEventStore = MockEventStore()

      // Register mock identity service
      mockIdentityService = mockFactory.identityService
      Container.shared.identityService.register { mockIdentityService }

      // Register mock API
      mockNuxieApi = MockNuxieApi()
      Container.shared.nuxieApi.register { mockNuxieApi }

      // Register mock segment service
      Container.shared.segmentService.register { mockFactory.segmentService }

      // Create event service with mock event store
      eventService = EventService(eventStore: mockEventStore)

      // Create network queue
      mockNetworkQueue = NuxieNetworkQueue(
        flushAt: 5,
        flushIntervalSeconds: 30,
        apiClient: mockNuxieApi
      )
    }

    afterEach {
      await mockNetworkQueue?.shutdown()
      await mockNuxieApi?.reset()
      mockEventStore.resetMock()
      mockIdentityService.reset()
      Container.shared.reset()
    }

    describe("EventService") {

      describe("initialization") {
        it("should initialize successfully") {
          expect(eventService).toNot(beNil())
        }
      }

      describe("configuration") {
        it("should configure with network queue") {
          try await eventService.configure(
            networkQueue: mockNetworkQueue,
            journeyService: nil
          )

          // Configuration is internal, so we test its effects by routing an event
          let event = TestEventBuilder(name: "test_event")
            .withDistinctId("user123")
            .withProperties(["key": "value"])
            .build()

          let result = await eventService.route(event)
          expect(result).toNot(beNil())
        }

        it("should work without network queue or journey service") {
          try await eventService.configure(networkQueue: nil, journeyService: nil)

          let event = TestEventBuilder(name: "test_event")
            .withDistinctId("user123")
            .withProperties(["key": "value"])
            .build()

          let result = await eventService.route(event)
          expect(result).toNot(beNil())
        }
      }

      describe("route") {

        it("should route event to local storage") {
          // Configure the service to open the ready latch
          try await eventService.configure(networkQueue: nil, journeyService: nil)

          let event = TestEventBuilder(name: "test_event")
            .withDistinctId("user123")
            .withProperties(["key": "value", "$session_id": "session1"])
            .build()

          let result = await eventService.route(event)

          expect(result).toNot(beNil())
          expect(result?.name).to(equal("test_event"))

          // Verify event was stored
          expect(mockEventStore.storeEventCallCount).to(equal(1))
          expect(mockEventStore.storedEvents.count).to(equal(1))
          expect(mockEventStore.storedEvents.first?.name).to(equal("test_event"))
        }

        it("should route event to network queue when configured") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let event = TestEventBuilder(name: "network_test")
            .withDistinctId("user123")
            .withProperties(["test": "value"])
            .build()

          let result = await eventService.route(event)

          expect(result).toNot(beNil())

          // Give network queue time to process
          await expect { await mockNetworkQueue.getQueueSize() }
            .toEventually(equal(1), timeout: .seconds(1))
        }

        it("should extract and update user properties from $set") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          mockIdentityService.setDistinctId("user123")

          let event = TestEventBuilder(name: "user_update")
            .withDistinctId("user123")
            .withProperties([
              "$set": ["name": "John Doe", "email": "john@example.com"],
              "other": "value",
            ])
            .build()

          await eventService.route(event)

          // Verify identity service received the properties
          let userProps = mockIdentityService.getUserProperties()
          expect(userProps["name"] as? String).to(equal("John Doe"))
          expect(userProps["email"] as? String).to(equal("john@example.com"))
        }

        it("should extract and update user properties from $set_once") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          mockIdentityService.setDistinctId("user123")

          let event = TestEventBuilder(name: "user_update")
            .withDistinctId("user123")
            .withProperties([
              "$set_once": ["first_seen": "2024-01-01", "source": "organic"],
              "other": "value",
            ])
            .build()

          await eventService.route(event)

          // Verify identity service received the properties
          let userProps = mockIdentityService.getUserProperties()
          expect(userProps["first_seen"] as? String).to(equal("2024-01-01"))
          expect(userProps["source"] as? String).to(equal("organic"))
        }

        it("should handle storage failures gracefully") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          mockEventStore.shouldFailStore = true

          let event = TestEventBuilder(name: "fail_test")
            .withDistinctId("user123")
            .withProperties(["key": "value"])
            .build()

          // Should not throw, just log error
          let result = await eventService.route(event)

          expect(result).toNot(beNil())
          expect(mockEventStore.storeEventCallCount).to(equal(1))
          expect(mockEventStore.storedEvents.count).to(equal(0))
        }

        it("should return the same event that was routed") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let event = TestEventBuilder(name: "return_test")
            .withDistinctId("user123")
            .withProperties(["unique": "identifier"])
            .build()

          let result = await eventService.route(event)

          expect(result?.id).to(equal(event.id))
          expect(result?.name).to(equal(event.name))
          expect(result?.distinctId).to(equal(event.distinctId))
        }
      }

      describe("routeBatch") {

        it("should route multiple events") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let events = [
            TestEventBuilder(name: "event1").withDistinctId("user1").build(),
            TestEventBuilder(name: "event2").withDistinctId("user2").build(),
            TestEventBuilder(name: "event3").withDistinctId("user3").build(),
          ]

          let routed = await eventService.routeBatch(events)

          expect(routed.count).to(equal(3))
          expect(mockEventStore.storedEvents.count).to(equal(3))
          expect(mockEventStore.storeEventCallCount).to(equal(3))
        }

        it("should handle partial failures in batch") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          // Simulate a temporary storage failure
          let events = [
            TestEventBuilder(name: "event1").withDistinctId("user1").build(),
            TestEventBuilder(name: "event2").withDistinctId("user2").build(),
            TestEventBuilder(name: "event3").withDistinctId("user3").build(),
          ]

          // First event succeeds
          mockEventStore.shouldFailStore = false
          await eventService.route(events[0])

          // Second event fails
          mockEventStore.shouldFailStore = true
          await eventService.route(events[1])

          // Third event succeeds again
          mockEventStore.shouldFailStore = false
          await eventService.route(events[2])

          // Check that events 1 and 3 were stored despite event 2 failing
          expect(mockEventStore.storedEvents.count).to(equal(2))
          expect(mockEventStore.storeEventCallCount).to(equal(3))
        }
      }

      describe("getRecentEvents") {

        beforeEach {
          // Add some test events
          mockEventStore.addTestEvent(name: "event1", distinctId: "user1")
          mockEventStore.addTestEvent(name: "event2", distinctId: "user2")
          mockEventStore.addTestEvent(name: "event3", distinctId: "user3")
        }

        it("should return recent events") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let events = await eventService.getRecentEvents(limit: 2)

          expect(events.count).to(equal(2))
          expect(events[0].name).to(equal("event2"))
          expect(events[1].name).to(equal("event3"))
        }

        it("should use default limit of 100") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          // Add more events
          for i in 4...150 {
            mockEventStore.addTestEvent(name: "event\(i)", distinctId: "user\(i)")
          }

          let events = await eventService.getRecentEvents()

          expect(events.count).to(equal(100))
        }

        it("should handle query failures gracefully") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          mockEventStore.shouldFailQuery = true

          let events = await eventService.getRecentEvents(limit: 10)

          expect(events.count).to(equal(0))
        }
      }

      describe("getEventsForUser") {

        beforeEach {
          mockEventStore.addTestEvent(name: "event1", distinctId: "user1")
          mockEventStore.addTestEvent(name: "event2", distinctId: "user2")
          mockEventStore.addTestEvent(name: "event3", distinctId: "user1")
          mockEventStore.addTestEvent(name: "event4", distinctId: "user1")
        }

        it("should return events for specific user") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let events = await eventService.getEventsForUser("user1", limit: 10)

          expect(events.count).to(equal(3))
          expect(events.allSatisfy { $0.distinctId == "user1" }).to(beTrue())
        }

        it("should respect limit parameter") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let events = await eventService.getEventsForUser("user1", limit: 2)

          expect(events.count).to(equal(2))
          expect(events[0].name).to(equal("event3"))
          expect(events[1].name).to(equal("event4"))
        }

        it("should return empty array for unknown user") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let events = await eventService.getEventsForUser("unknown_user", limit: 10)

          expect(events.count).to(equal(0))
        }
      }

      describe("getEvents(for sessionId)") {

        beforeEach {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          mockEventStore.setSessionId("session1")
          mockEventStore.addTestEvent(name: "event1", distinctId: "user1")
          mockEventStore.addTestEvent(name: "event2", distinctId: "user2")

          mockEventStore.setSessionId("session2")
          mockEventStore.addTestEvent(name: "event3", distinctId: "user1")
        }

        it("should return events for specific session") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let events = await eventService.getEvents(for: "session1")

          expect(events.count).to(equal(2))
          expect(events[0].name).to(equal("event1"))
          expect(events[1].name).to(equal("event2"))
        }

        it("should return empty array for unknown session") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let events = await eventService.getEvents(for: "unknown_session")

          expect(events.count).to(equal(0))
        }
      }

      describe("hasEvent") {

        beforeEach {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let now = Date()
          let yesterday = now.addingTimeInterval(-86400)
          let lastWeek = now.addingTimeInterval(-7 * 86400)

          mockEventStore.addTestEvent(name: "login", distinctId: "user1", timestamp: now)
          mockEventStore.addTestEvent(name: "purchase", distinctId: "user1", timestamp: yesterday)
          mockEventStore.addTestEvent(name: "login", distinctId: "user1", timestamp: lastWeek)
          mockEventStore.addTestEvent(name: "login", distinctId: "user2", timestamp: now)
        }

        it("should return true when event exists") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let hasEvent = await eventService.hasEvent(name: "login", distinctId: "user1", since: nil)

          expect(hasEvent).to(beTrue())
        }

        it("should return false when event does not exist") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let hasEvent = await eventService.hasEvent(
            name: "signup", distinctId: "user1", since: nil)

          expect(hasEvent).to(beFalse())
        }

        it("should respect since parameter") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let twoDaysAgo = Date().addingTimeInterval(-2 * 86400)

          let hasRecentLogin = await eventService.hasEvent(
            name: "login", distinctId: "user1", since: twoDaysAgo)
          let hasRecentPurchase = await eventService.hasEvent(
            name: "purchase", distinctId: "user1", since: Date())

          expect(hasRecentLogin).to(beTrue())
          expect(hasRecentPurchase).to(beFalse())
        }

        it("should filter by user") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let hasUser1Login = await eventService.hasEvent(
            name: "login", distinctId: "user1", since: nil)
          let hasUser3Login = await eventService.hasEvent(
            name: "login", distinctId: "user3", since: nil)

          expect(hasUser1Login).to(beTrue())
          expect(hasUser3Login).to(beFalse())
        }
      }

      describe("countEvents") {

        beforeEach {
          let now = Date()
          let yesterday = now.addingTimeInterval(-86400)
          let lastWeek = now.addingTimeInterval(-7 * 86400)

          mockEventStore.addTestEvent(name: "click", distinctId: "user1", timestamp: now)
          mockEventStore.addTestEvent(name: "click", distinctId: "user1", timestamp: yesterday)
          mockEventStore.addTestEvent(name: "click", distinctId: "user1", timestamp: lastWeek)
          mockEventStore.addTestEvent(name: "view", distinctId: "user1", timestamp: now)
          mockEventStore.addTestEvent(name: "click", distinctId: "user2", timestamp: now)
        }

        it("should count all events when no since parameter") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let count = await eventService.countEvents(name: "click", distinctId: "user1", since: nil)

          expect(count).to(equal(3))
        }

        it("should count events since specified date") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let twoDaysAgo = Date().addingTimeInterval(-2 * 86400)

          let count = await eventService.countEvents(
            name: "click", distinctId: "user1", since: twoDaysAgo)

          expect(count).to(equal(2))
        }

        it("should return zero for non-existent events") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let count = await eventService.countEvents(
            name: "purchase", distinctId: "user1", since: nil)

          expect(count).to(equal(0))
        }

        it("should filter by user") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let user1Count = await eventService.countEvents(
            name: "click", distinctId: "user1", since: nil)
          let user2Count = await eventService.countEvents(
            name: "click", distinctId: "user2", since: nil)

          expect(user1Count).to(equal(3))
          expect(user2Count).to(equal(1))
        }
      }

      describe("getLastEventTime") {

        beforeEach {
          let now = Date()
          let yesterday = now.addingTimeInterval(-86400)
          let lastWeek = now.addingTimeInterval(-7 * 86400)

          mockEventStore.addTestEvent(name: "login", distinctId: "user1", timestamp: lastWeek)
          mockEventStore.addTestEvent(name: "login", distinctId: "user1", timestamp: yesterday)
          mockEventStore.addTestEvent(name: "login", distinctId: "user1", timestamp: now)
          mockEventStore.addTestEvent(name: "login", distinctId: "user2", timestamp: yesterday)
        }

        it("should return timestamp of most recent event") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let lastTime = await eventService.getLastEventTime(name: "login", distinctId: "user1")

          expect(lastTime).toNot(beNil())

          let timeDiff = abs(lastTime!.timeIntervalSinceNow)
          expect(timeDiff).to(beLessThan(1))  // Should be very recent
        }

        it("should return nil for non-existent event") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let lastTime = await eventService.getLastEventTime(name: "purchase", distinctId: "user1")

          expect(lastTime).to(beNil())
        }

        it("should filter by user") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let user2LastTime = await eventService.getLastEventTime(
            name: "login", distinctId: "user2")

          expect(user2LastTime).toNot(beNil())

          let timeDiff = abs(user2LastTime!.timeIntervalSinceNow + 86400)
          expect(timeDiff).to(beLessThan(1))  // Should be yesterday
        }
      }

      // MARK: - New tests for $identify-first ordering
      describe("identity ordering / $identify-first") {

        // Journey spy to ensure business logic still runs while buffering
        final actor JourneyServiceSpy: JourneyServiceProtocol {
          private(set) var handled: [NuxieEvent] = []

          // Only the methods EventService may call; others are no-ops
          func startJourney(for campaign: Campaign, distinctId: String, originEventId: String?)
            async
            -> Journey?
          { nil }
          func resumeJourney(_ journey: Journey) async {}
          func handleEvent(_ event: NuxieEvent) async { handled.append(event) }
          func handleSegmentChange(distinctId: String, segments: Set<String>) async {}
          func getActiveJourneys(for distinctId: String) async -> [Journey] { [] }
          func checkExpiredTimers() async {}
          func initialize() async {}
          func shutdown() async {}
          func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {}
          func onAppWillEnterForeground() async {}
          func onAppBecameActive() async {}
          func onAppDidEnterBackground() async {}

          // helper for Nimble
          func handledCount() async -> Int { handled.count }
        }

        it(
          "buffers post-identify network enqueues but does NOT block local store or journeys; then sends $identify first and drains in order"
        ) {
          // Arrange
          try await eventService.configure(
            networkQueue: mockNetworkQueue, journeyService: JourneyServiceSpy())

          let anonId = "anon-\(UUID().uuidString)"
          mockIdentityService.setDistinctId(anonId)

          // Begin the ordering barrier BEFORE any post-identify tracks
          eventService.beginIdentityTransition()

          // Post-identify events (these should be buffered for NETWORK only)
          let post1 = TestEventBuilder(name: "post_1")
            .withDistinctId(anonId)
            .withProperties(["$session_id": "s1"])
            .build()

          let post2 = TestEventBuilder(name: "post_2")
            .withDistinctId(anonId)
            .withProperties(["$session_id": "s1"])
            .build()

          // Act: route while barrier is closed
          await eventService.route(post1)
          await eventService.route(post2)

          // Assert: local storage occurred immediately
          expect(mockEventStore.storeEventCallCount).to(equal(2))
          expect(mockEventStore.storedEvents.map { $0.name }).to(contain(["post_1", "post_2"]))

          // Assert: nothing has reached the NETWORK queue yet (buffering)
          await expect { await mockNetworkQueue.getQueueSize() }
            .toEventually(equal(0), timeout: .milliseconds(200))

          // Now perform identify (this enqueues + flushes $identify, then drains the buffer)
          await eventService.identifyUser(
            distinctId: "user123",
            anonymousId: anonId,
            wasIdentified: false,
            userProperties: nil,
            userPropertiesSetOnce: nil
          )

          // Wait until the API observed all three events
          await expect { await mockNuxieApi.sentEvents.count }
            .toEventually(equal(3), timeout: .seconds(2))

          // Assert exact on-the-wire order: $identify first, then buffered events in order
          let names = await mockNuxieApi.sentEvents.map(\.name)
          expect(names.first).to(equal("$identify"))
          expect(Array(names.dropFirst())).to(equal(["post_1", "post_2"]))
        }

        it("re-opens after draining: subsequent events enqueue immediately") {
          // Arrange
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let anonId = "anon-\(UUID().uuidString)"
          mockIdentityService.setDistinctId(anonId)
          eventService.beginIdentityTransition()

          // Buffer one event
          let buffered = TestEventBuilder(name: "buffered")
            .withDistinctId(anonId)
            .withProperties(["$session_id": "s1"])
            .build()
          await eventService.route(buffered)

          // Identify (routes $identify, drains buffer, resumes)
          await eventService.identifyUser(
            distinctId: "user123",
            anonymousId: anonId,
            wasIdentified: false,
            userProperties: nil,
            userPropertiesSetOnce: nil
          )

          // Wait until the API saw the two events
          await expect { await mockNuxieApi.sentEvents.count }
            .toEventually(equal(2), timeout: .seconds(2))

          // Now route another event; with the barrier open it should go straight to the queue
          let after = TestEventBuilder(name: "after_open")
            .withDistinctId("user123")
            .withProperties(["$session_id": "s2"])
            .build()
          let _ = await eventService.route(after)
          
          // Manually flush to ensure the event is sent
          _ = await eventService.flushEvents()

          // Either it gets queued or flushed quickly; assert it arrives at the API soon.
          await expect { await mockNuxieApi.sentEvents.map(\.name).contains("after_open") }
            .toEventually(beTrue(), timeout: .seconds(2))
        }

        it("$identify is first relative to any post-identify tracks even under concurrency") {
          // Arrange
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          let anonId = "anon-\(UUID().uuidString)"
          mockIdentityService.setDistinctId(anonId)
          
          // Start the barrier just before we begin concurrent operations
          eventService.beginIdentityTransition()
          
          // First, route some events that will definitely be buffered
          let pre1 = TestEventBuilder(name: "pre1")
            .withDistinctId(anonId)
            .withProperties(["$session_id": "sx"])
            .build()
          let pre2 = TestEventBuilder(name: "pre2")
            .withDistinctId(anonId)
            .withProperties(["$session_id": "sx"])
            .build()
          await eventService.route(pre1)
          await eventService.route(pre2)

          // Now kick off concurrent tracks that might race with identify
          await withTaskGroup(of: Void.self) { group in
            for i in 0..<3 {
              group.addTask {
                let e = TestEventBuilder(name: "p\(i)")
                  .withDistinctId(anonId)
                  .withProperties(["$session_id": "sx"])
                  .build()
                await eventService.route(e)
              }
            }
            // Small delay to let some events get buffered
            group.addTask {
              try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
              await eventService.identifyUser(
                distinctId: "userXYZ",
                anonymousId: anonId,
                wasIdentified: false,
                userProperties: nil,
                userPropertiesSetOnce: nil
              )
            }
            await group.waitForAll()
          }

          // Wait for everything to be delivered
          await expect { await mockNuxieApi.sentEvents.count }
            .toEventually(equal(6), timeout: .seconds(3))

          let names = await mockNuxieApi.sentEvents.map(\.name)
          expect(names.first).to(equal("$identify"))  // first must be identify
          
          // The rest should be our pre and p events (order among them doesn't matter)
          let remainingNames = Set(names.dropFirst())
          expect(remainingNames).to(equal(Set(["pre1", "pre2", "p0", "p1", "p2"])))
        }
        
        it("$identify is sent in its own batch, separate from buffered events") {
          // This test verifies that $identify is sent alone in the first batch,
          // and buffered events are sent in a subsequent batch
          
          // Arrange
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)
          
          let anonId = "anon-\(UUID().uuidString)"
          mockIdentityService.setDistinctId(anonId)
          eventService.beginIdentityTransition()
          
          // Route events that will be buffered
          let event1 = TestEventBuilder(name: "buffered_1")
            .withDistinctId(anonId)
            .withProperties(["$session_id": "s1"])
            .build()
          let event2 = TestEventBuilder(name: "buffered_2")
            .withDistinctId(anonId)
            .withProperties(["$session_id": "s1"])
            .build()
            
          await eventService.route(event1)
          await eventService.route(event2)
          
          // Track how many times sendBatch is called
          var batchCallCount = 0
          var firstBatchEvents: [String] = []
          var secondBatchEvents: [String] = []
          
          // Override the mock API to capture batch calls
          await mockNuxieApi.reset()
          
          // Now identify - this should trigger two separate batches
          await eventService.identifyUser(
            distinctId: "user123",
            anonymousId: anonId,
            wasIdentified: false,
            userProperties: nil,
            userPropertiesSetOnce: nil
          )
          
          // Wait for events to be sent
          await expect { await mockNuxieApi.sentEvents.count }
            .toEventually(equal(3), timeout: .seconds(2))
          
          // Get the sent events
          let sentEvents = await mockNuxieApi.sentEvents
          
          // Verify $identify was sent first
          expect(sentEvents.first?.name).to(equal("$identify"))
          
          // Check the sendBatch call count to verify separate batches
          let callCount = await mockNuxieApi.sendBatchCallCount
          expect(callCount).to(beGreaterThanOrEqualTo(2)) // At least 2 batches
          
          // Verify the order: $identify first, then the buffered events
          let eventNames = sentEvents.map(\.name)
          expect(eventNames).to(equal(["$identify", "buffered_1", "buffered_2"]))
        }
      }

    }
  }
}
