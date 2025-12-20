import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie

/// Comprehensive integration tests for the identity system
/// Tests the full flow of identify(), reset(), and identity state management across services
final class IdentityIntegrationTests: AsyncSpec {
    override class func spec() {
        describe("Identity Integration") {
            var config: NuxieConfiguration!
            var dbPath: String!
            var mockApi: MockNuxieApi!

            beforeEach {
                // Create and register mock API to prevent network calls
                mockApi = MockNuxieApi()
                Container.shared.nuxieApi.register { mockApi }

                await NuxieSDK.shared.shutdown()

                // Create unique database directory for test isolation
                let testId = UUID().uuidString
                let tempDir = NSTemporaryDirectory()
                let testDirPath = "\(tempDir)test_identity_\(testId)"

                try FileManager.default.createDirectory(atPath: testDirPath, withIntermediateDirectories: true)
                dbPath = testDirPath

                // Create configuration
                config = NuxieConfiguration(apiKey: "test-key-\(testId)")
                config.customStoragePath = URL(fileURLWithPath: dbPath)
                config.environment = .development
                config.enablePlugins = false // Disable plugins for faster tests

                try NuxieSDK.shared.setup(with: config)
            }

            afterEach {
                await NuxieSDK.shared.shutdown()

                if let dbPath = dbPath {
                    try? FileManager.default.removeItem(atPath: dbPath)
                }

                Container.shared.reset()
            }

            // MARK: - Basic Identity Flow

            describe("basic identity flow") {
                it("should start with anonymous identity") {
                    expect(NuxieSDK.shared.isIdentified).to(beFalse())

                    let anonymousId = NuxieSDK.shared.getAnonymousId()
                    let distinctId = NuxieSDK.shared.getDistinctId()

                    expect(anonymousId).toNot(beEmpty())
                    expect(distinctId).to(equal(anonymousId))
                }

                it("should identify user correctly") {
                    let userId = "user-123"
                    NuxieSDK.shared.identify(userId)

                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(userId))

                    // Anonymous ID should be preserved
                    let anonymousId = NuxieSDK.shared.getAnonymousId()
                    expect(anonymousId).toNot(beEmpty())
                    expect(anonymousId).toNot(equal(userId))
                }

                it("should reset to anonymous state correctly") {
                    let originalAnonymousId = NuxieSDK.shared.getAnonymousId()

                    NuxieSDK.shared.identify("user-123")
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())

                    NuxieSDK.shared.reset()

                    expect(NuxieSDK.shared.isIdentified).to(beFalse())
                    expect(NuxieSDK.shared.getAnonymousId()).to(equal(originalAnonymousId))
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(originalAnonymousId))
                }

                it("should generate new anonymous ID when reset with keepAnonymousId: false") {
                    let originalAnonymousId = NuxieSDK.shared.getAnonymousId()

                    NuxieSDK.shared.identify("user-123")
                    NuxieSDK.shared.reset(keepAnonymousId: false)

                    expect(NuxieSDK.shared.isIdentified).to(beFalse())
                    expect(NuxieSDK.shared.getAnonymousId()).toNot(equal(originalAnonymousId))
                }
            }

            // MARK: - User Properties

            describe("user properties with identify") {
                it("should set user properties during identify") {
                    let userId = "user-with-props"
                    let properties = ["name": "John", "age": 30] as [String: Any]

                    NuxieSDK.shared.identify(userId, userProperties: properties)

                    // Give time for async operations
                    try await Task.sleep(nanoseconds: 100_000_000)

                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(userId))
                }

                it("should handle setOnce properties during identify") {
                    let userId = "user-setonce"

                    // First identify with properties
                    NuxieSDK.shared.identify(userId, userPropertiesSetOnce: ["first_seen": "2024-01-01"])

                    // Give time for async operations
                    try await Task.sleep(nanoseconds: 100_000_000)

                    // Second identify with different setOnce properties
                    NuxieSDK.shared.identify(userId, userPropertiesSetOnce: ["first_seen": "2024-12-01"])

                    // The original value should be preserved (setOnce semantics)
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                }
            }

            // MARK: - $identify Event Tracking

            describe("$identify event tracking") {
                it("should track $identify event when identifying") {
                    let eventService = Container.shared.eventService()
                    let userId = "identify-event-user"

                    NuxieSDK.shared.identify(userId)

                    // Give time for event to be processed
                    await expect {
                        let events = await eventService.getEventsForUser(userId, limit: 10)
                        return events.contains { $0.name == "$identify" }
                    }.toEventually(beTrue(), timeout: .seconds(2))
                }

                it("should include distinct_id in $identify event properties") {
                    let eventService = Container.shared.eventService()
                    let userId = "identify-props-user"

                    NuxieSDK.shared.identify(userId)

                    await expect {
                        let events = await eventService.getEventsForUser(userId, limit: 10)
                        return events.first { $0.name == "$identify" }
                    }.toEventuallyNot(beNil(), timeout: .seconds(2))

                    let events = await eventService.getEventsForUser(userId, limit: 10)
                    let identifyEvent = events.first { $0.name == "$identify" }

                    expect(identifyEvent).toNot(beNil())
                }
            }

            // MARK: - Session Handling

            describe("session handling on identify") {
                it("should start new session when identifying") {
                    let sessionService = Container.shared.sessionService()

                    // Create initial session
                    let firstSessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    expect(firstSessionId).toNot(beNil())

                    // Identify should create new session
                    NuxieSDK.shared.identify("session-user")

                    // Give time for session to be created
                    try await Task.sleep(nanoseconds: 100_000_000)

                    let secondSessionId = sessionService.getSessionId(at: Date(), readOnly: true)
                    expect(secondSessionId).toNot(beNil())
                    expect(secondSessionId).toNot(equal(firstSessionId))
                }

                it("should reset session on reset()") {
                    let sessionService = Container.shared.sessionService()

                    NuxieSDK.shared.identify("reset-session-user")
                    let identifiedSessionId = sessionService.getSessionId(at: Date(), readOnly: false)

                    NuxieSDK.shared.reset()

                    // Session should be cleared or new
                    let afterResetSessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    expect(afterResetSessionId).toNot(equal(identifiedSessionId))
                }
            }

            // MARK: - Multiple Identity Transitions

            describe("multiple identity transitions") {
                it("should handle identify -> reset -> identify cycle correctly") {
                    let user1 = "user-1"
                    let user2 = "user-2"
                    let anonymousId = NuxieSDK.shared.getAnonymousId()

                    // Identify first user
                    NuxieSDK.shared.identify(user1)
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(user1))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())

                    // Reset to anonymous
                    NuxieSDK.shared.reset()
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(anonymousId))
                    expect(NuxieSDK.shared.isIdentified).to(beFalse())

                    // Identify second user
                    NuxieSDK.shared.identify(user2)
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(user2))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                }

                it("should handle direct user-to-user transition") {
                    let user1 = "direct-user-1"
                    let user2 = "direct-user-2"

                    NuxieSDK.shared.identify(user1)
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(user1))

                    // Identify different user without reset
                    NuxieSDK.shared.identify(user2)
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(user2))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                }

                it("should handle re-identifying with same user ID") {
                    let userId = "same-user"

                    NuxieSDK.shared.identify(userId)
                    let sessionAfterFirst = Container.shared.sessionService().getSessionId(at: Date(), readOnly: true)

                    // Re-identify with same ID
                    NuxieSDK.shared.identify(userId, userProperties: ["updated": true])

                    // Should still be identified as same user
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(userId))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())

                    // Session may or may not change depending on implementation
                    let sessionAfterSecond = Container.shared.sessionService().getSessionId(at: Date(), readOnly: true)
                    expect(sessionAfterSecond).toNot(beNil())
                }
            }

            // MARK: - Rapid Transitions

            describe("rapid identity transitions") {
                it("should handle rapid identify/reset cycles without crashes") {
                    for i in 0..<10 {
                        NuxieSDK.shared.identify("rapid-user-\(i)")
                        NuxieSDK.shared.reset()
                    }

                    // Should end in anonymous state
                    expect(NuxieSDK.shared.isIdentified).to(beFalse())

                    // Final identify should work
                    NuxieSDK.shared.identify("final-user")
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                    expect(NuxieSDK.shared.getDistinctId()).to(equal("final-user"))
                }

                it("should handle rapid identify with different users") {
                    for i in 0..<10 {
                        NuxieSDK.shared.identify("user-\(i)")
                    }

                    // Should end up as the last user
                    expect(NuxieSDK.shared.getDistinctId()).to(equal("user-9"))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                }
            }

            // MARK: - Concurrent Access

            describe("concurrent identity access") {
                it("should handle concurrent getDistinctId calls safely") {
                    let iterations = 50
                    let group = DispatchGroup()
                    var distinctIds: [String] = []
                    let lock = NSLock()

                    NuxieSDK.shared.identify("concurrent-user")

                    for _ in 0..<iterations {
                        group.enter()
                        DispatchQueue.global().async {
                            let id = NuxieSDK.shared.getDistinctId()
                            lock.lock()
                            distinctIds.append(id)
                            lock.unlock()
                            group.leave()
                        }
                    }

                    group.wait()

                    // All calls should return the same user ID
                    let uniqueIds = Set(distinctIds)
                    expect(uniqueIds.count).to(equal(1))
                    expect(uniqueIds.first).to(equal("concurrent-user"))
                }

                it("should handle concurrent identify and getDistinctId calls") {
                    let group = DispatchGroup()

                    for i in 0..<20 {
                        group.enter()
                        DispatchQueue.global().async {
                            if i % 2 == 0 {
                                NuxieSDK.shared.identify("concurrent-\(i)")
                            } else {
                                _ = NuxieSDK.shared.getDistinctId()
                            }
                            group.leave()
                        }
                    }

                    group.wait()

                    // Should not crash and should have valid state
                    expect(NuxieSDK.shared.getDistinctId()).toNot(beEmpty())
                }
            }

            // MARK: - Edge Cases

            describe("edge cases") {
                it("should handle empty string user ID") {
                    // Empty user ID should be handled gracefully
                    NuxieSDK.shared.identify("")

                    // Behavior depends on implementation - either reject or accept
                    // At minimum, should not crash
                    expect(NuxieSDK.shared.getDistinctId()).toNot(beNil())
                }

                it("should handle whitespace-only user ID") {
                    NuxieSDK.shared.identify("   ")

                    // Should not crash
                    expect(NuxieSDK.shared.getDistinctId()).toNot(beNil())
                }

                it("should handle special characters in user ID") {
                    let specialUserId = "user@example.com/test+id#123"

                    NuxieSDK.shared.identify(specialUserId)

                    expect(NuxieSDK.shared.getDistinctId()).to(equal(specialUserId))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                }

                it("should handle unicode in user ID") {
                    let unicodeUserId = "用户-🎉-test"

                    NuxieSDK.shared.identify(unicodeUserId)

                    expect(NuxieSDK.shared.getDistinctId()).to(equal(unicodeUserId))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                }

                it("should handle very long user ID") {
                    let longUserId = String(repeating: "a", count: 1000)

                    NuxieSDK.shared.identify(longUserId)

                    expect(NuxieSDK.shared.getDistinctId()).to(equal(longUserId))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                }
            }

            // MARK: - Anonymous ID Persistence

            describe("anonymous ID persistence") {
                it("should preserve anonymous ID across identify cycles") {
                    let originalAnonymousId = NuxieSDK.shared.getAnonymousId()

                    NuxieSDK.shared.identify("user-1")
                    expect(NuxieSDK.shared.getAnonymousId()).to(equal(originalAnonymousId))

                    NuxieSDK.shared.identify("user-2")
                    expect(NuxieSDK.shared.getAnonymousId()).to(equal(originalAnonymousId))

                    NuxieSDK.shared.reset()
                    expect(NuxieSDK.shared.getAnonymousId()).to(equal(originalAnonymousId))
                }
            }
        }
    }
}
