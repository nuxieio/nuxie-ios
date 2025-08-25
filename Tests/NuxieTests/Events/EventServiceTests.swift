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
    var mockOutcomeBroker: MockOutcomeBroker!

    beforeEach {
      mockFactory = MockFactory.shared

      // Create and register mock outcome broker FIRST (before EventService creation)
      mockOutcomeBroker = await MockOutcomeBroker()
      Container.shared.outcomeBroker.register { mockOutcomeBroker }

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

      // Create event service with mock event store (AFTER registering mocks)
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
      await mockOutcomeBroker?.reset()
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

          // Configuration is internal, so we test its effects by tracking an event
          var trackResult: EventResult?
          eventService.track(
            "test_event",
            properties: ["key": "value"],
            userProperties: nil,
            userPropertiesSetOnce: nil
          ) { result in
            trackResult = result
          }
          
          await eventService.drain()
          expect(trackResult).to(equal(.noInteraction))
        }

        it("should work without network queue or journey service") {
          try await eventService.configure(networkQueue: nil, journeyService: nil)

          var trackResult: EventResult?
          eventService.track(
            "test_event",
            properties: ["key": "value"],
            userProperties: nil,
            userPropertiesSetOnce: nil
          ) { result in
            trackResult = result
          }
          
          await eventService.drain()
          expect(trackResult).to(equal(.noInteraction))
        }
      }

      describe("track") {

        it("should track event to local storage") {
          // Configure the service to open the ready latch
          try await eventService.configure(networkQueue: nil, journeyService: nil)

          var trackResult: EventResult?
          eventService.track(
            "test_event",
            properties: ["key": "value", "$session_id": "session1"],
            userProperties: nil,
            userPropertiesSetOnce: nil
          ) { result in
            trackResult = result
          }
          
          await eventService.drain()
          
          expect(trackResult).to(equal(.noInteraction))

          // Verify event was stored
          expect(mockEventStore.storeEventCallCount).to(equal(1))
          expect(mockEventStore.storedEvents.count).to(equal(1))
          expect(mockEventStore.storedEvents.first?.name).to(equal("test_event"))
        }

        it("should track event to network queue when configured") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          var trackResult: EventResult?
          eventService.track(
            "network_test",
            properties: ["test": "value"],
            userProperties: nil,
            userPropertiesSetOnce: nil
          ) { result in
            trackResult = result
          }
          
          await eventService.drain()
          
          expect(trackResult).to(equal(.noInteraction))

          // Give network queue time to process
          await expect { await mockNetworkQueue.getQueueSize() }
            .toEventually(equal(1), timeout: .seconds(1))
        }

        it("should extract and update user properties from $set") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          mockIdentityService.setDistinctId("user123")

          var trackResult: EventResult?
          eventService.track(
            "user_update",
            properties: [
              "$set": ["name": "John Doe", "email": "john@example.com"],
              "other": "value",
            ],
            userProperties: nil,
            userPropertiesSetOnce: nil
          ) { result in
            trackResult = result
          }
          
          await eventService.drain()
          
          expect(trackResult).to(equal(.noInteraction))

          // Verify identity service received the properties
          let userProps = mockIdentityService.getUserProperties()
          expect(userProps["name"] as? String).to(equal("John Doe"))
          expect(userProps["email"] as? String).to(equal("john@example.com"))
        }

        it("should extract and update user properties from $set_once") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          mockIdentityService.setDistinctId("user123")

          var trackResult: EventResult?
          eventService.track(
            "user_update",
            properties: [
              "$set_once": ["first_seen": "2024-01-01", "source": "organic"],
              "other": "value",
            ],
            userProperties: nil,
            userPropertiesSetOnce: nil
          ) { result in
            trackResult = result
          }
          
          await eventService.drain()
          
          expect(trackResult).to(equal(.noInteraction))

          // Verify identity service received the properties
          let userProps = mockIdentityService.getUserProperties()
          expect(userProps["first_seen"] as? String).to(equal("2024-01-01"))
          expect(userProps["source"] as? String).to(equal("organic"))
        }

        it("should handle storage failures gracefully") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          mockEventStore.shouldFailStore = true

          var trackResult: EventResult?
          eventService.track(
            "fail_test",
            properties: ["key": "value"],
            userProperties: nil,
            userPropertiesSetOnce: nil
          ) { result in
            trackResult = result
          }
          
          await eventService.drain()
          
          // Should not throw, just continues with noInteraction
          expect(trackResult).to(equal(.noInteraction))
          expect(mockEventStore.storeEventCallCount).to(equal(1))
          expect(mockEventStore.storedEvents.count).to(equal(0))
        }

        it("should store event with correct properties") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          var trackResult: EventResult?
          eventService.track(
            "return_test",
            properties: ["unique": "identifier"],
            userProperties: nil,
            userPropertiesSetOnce: nil
          ) { result in
            trackResult = result
          }
          
          await eventService.drain()
          
          expect(trackResult).to(equal(.noInteraction))
          
          // Verify stored event has correct properties
          let storedEvent = mockEventStore.storedEvents.first
          expect(storedEvent?.name).to(equal("return_test"))
          let props = storedEvent?.getPropertiesDict()
          expect(props?["unique"] as? String).to(equal("identifier"))
        }
      }

      describe("track multiple events") {

        it("should track multiple events") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          // Track multiple events
          var results: [EventResult?] = []
          
          eventService.track("event1", properties: nil, userProperties: nil, userPropertiesSetOnce: nil) { result in
            results.append(result)
          }
          eventService.track("event2", properties: nil, userProperties: nil, userPropertiesSetOnce: nil) { result in
            results.append(result)
          }
          eventService.track("event3", properties: nil, userProperties: nil, userPropertiesSetOnce: nil) { result in
            results.append(result)
          }
          
          await eventService.drain()

          expect(results.count).to(equal(3))
          expect(results.allSatisfy { $0 == .noInteraction }).to(beTrue())
          expect(mockEventStore.storedEvents.count).to(equal(3))
          expect(mockEventStore.storeEventCallCount).to(equal(3))
        }

        it("should handle partial failures in batch") {
          try await eventService.configure(networkQueue: mockNetworkQueue, journeyService: nil)

          var results: [EventResult?] = []
          
          // First event succeeds
          mockEventStore.shouldFailStore = false
          eventService.track("event1", properties: nil, userProperties: nil, userPropertiesSetOnce: nil) { result in
            results.append(result)
          }
          await eventService.drain()

          // Second event fails
          mockEventStore.shouldFailStore = true
          eventService.track("event2", properties: nil, userProperties: nil, userPropertiesSetOnce: nil) { result in
            results.append(result)
          }
          await eventService.drain()

          // Third event succeeds again
          mockEventStore.shouldFailStore = false
          eventService.track("event3", properties: nil, userProperties: nil, userPropertiesSetOnce: nil) { result in
            results.append(result)
          }
          await eventService.drain()

          // Check that events 1 and 3 were stored despite event 2 failing
          expect(mockEventStore.storedEvents.count).to(equal(2))
          expect(mockEventStore.storeEventCallCount).to(equal(3))
          expect(results.count).to(equal(3))
          expect(results.allSatisfy { $0 == .noInteraction }).to(beTrue())
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
      }

    }
  }
}
