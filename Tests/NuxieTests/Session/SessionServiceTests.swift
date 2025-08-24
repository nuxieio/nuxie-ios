import Foundation
import Quick
import Nimble
@testable import Nuxie

final class SessionServiceTests: AsyncSpec {
    override class func spec() {
        describe("SessionService") {
            var sessionService: SessionService!
            
            beforeEach {
                sessionService = SessionService()
            }
            
            afterEach {
                sessionService = nil
            }
            
            describe("Session Creation") {
                it("should create a new session when none exists") {
                    let sessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    
                    expect(sessionId).toNot(beNil())
                    expect(sessionId).to(contain("-")) // UUID v7 format
                }
                
                it("should return nil when readOnly and no session exists") {
                    let sessionId = sessionService.getSessionId(at: Date(), readOnly: true)
                    
                    expect(sessionId).to(beNil())
                }
                
                it("should maintain the same session within activity threshold") {
                    let firstSessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    
                    // Get session again within threshold
                    let secondSessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    
                    expect(firstSessionId).to(equal(secondSessionId))
                }
            }
            
            describe("Session Expiration") {
                it("should expire session after 30 minutes of inactivity") {
                    let now = Date()
                    let firstSessionId = sessionService.getSessionId(at: now, readOnly: false)
                    
                    // Simulate 31 minutes later
                    let later = now.addingTimeInterval(31 * 60)
                    let secondSessionId = sessionService.getSessionId(at: later, readOnly: false)
                    
                    expect(firstSessionId).toNot(equal(secondSessionId))
                    expect(secondSessionId).toNot(beNil())
                }
                
                it("should expire session after 24 hours maximum duration") {
                    let now = Date()
                    let firstSessionId = sessionService.getSessionId(at: now, readOnly: false)
                    
                    // Keep session active but reach 24 hour limit
                    var currentTime = now
                    for _ in 0..<50 { // 50 * 29 minutes = ~24 hours
                        currentTime = currentTime.addingTimeInterval(29 * 60) // Just under inactivity threshold
                        _ = sessionService.getSessionId(at: currentTime, readOnly: false)
                    }
                    
                    // Now go over 24 hours
                    currentTime = now.addingTimeInterval(24 * 60 * 60 + 60)
                    let finalSessionId = sessionService.getSessionId(at: currentTime, readOnly: false)
                    
                    expect(firstSessionId).toNot(equal(finalSessionId))
                }
                
                it("should not expire session within 30 minutes when active") {
                    let now = Date()
                    let firstSessionId = sessionService.getSessionId(at: now, readOnly: false)
                    
                    // Touch session at 20 minutes
                    let midTime = now.addingTimeInterval(20 * 60)
                    sessionService.touchSession()
                    _ = sessionService.getSessionId(at: midTime, readOnly: false)
                    
                    // Check at 40 minutes from start (20 minutes after last activity)
                    let laterTime = now.addingTimeInterval(40 * 60)
                    let secondSessionId = sessionService.getSessionId(at: laterTime, readOnly: false)
                    
                    expect(firstSessionId).to(equal(secondSessionId))
                }
            }
            
            describe("Manual Session Management") {
                it("should start a new session on startSession") {
                    let firstSessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    sessionService.startSession()
                    let secondSessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    
                    expect(firstSessionId).toNot(equal(secondSessionId))
                    expect(secondSessionId).toNot(beNil())
                }
                
                it("should end session on endSession") {
                    _ = sessionService.getSessionId(at: Date(), readOnly: false)
                    sessionService.endSession()
                    let sessionId = sessionService.getSessionId(at: Date(), readOnly: true)
                    
                    expect(sessionId).to(beNil())
                }
                
                it("should reset session on resetSession") {
                    let firstSessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    sessionService.resetSession()
                    let secondSessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    
                    expect(firstSessionId).toNot(equal(secondSessionId))
                    expect(secondSessionId).toNot(beNil())
                }
                
                it("should set custom session ID") {
                    let customId = "custom-session-123"
                    sessionService.setSessionId(customId)
                    let sessionId = sessionService.getSessionId(at: Date(), readOnly: true)
                    
                    expect(sessionId).to(equal(customId))
                }
            }
            
            describe("Session Preview") {
                it("should preview next session ID without affecting current") {
                    let currentSessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    let nextSessionId = sessionService.getNextSessionId()
                    let stillCurrentSessionId = sessionService.getSessionId(at: Date(), readOnly: true)
                    
                    expect(nextSessionId).toNot(beNil())
                    expect(nextSessionId).toNot(equal(currentSessionId))
                    expect(stillCurrentSessionId).to(equal(currentSessionId))
                }
            }
            
            describe("Activity Tracking") {
                it("should update activity timestamp on touchSession") {
                    let now = Date()
                    _ = sessionService.getSessionId(at: now, readOnly: false)
                    
                    // Touch session after 20 minutes
                    let laterTime = now.addingTimeInterval(20 * 60)
                    sessionService.touchSession()
                    
                    // Session should still be valid 25 minutes after touch
                    let finalTime = laterTime.addingTimeInterval(25 * 60)
                    let sessionId = sessionService.getSessionId(at: finalTime, readOnly: false)
                    
                    expect(sessionId).toNot(beNil())
                }
            }
            
            describe("Thread Safety") {
                it("should handle concurrent access safely") {
                    let iterations = 100
                    let group = DispatchGroup()
                    var sessionIds: [String?] = []
                    let lock = NSLock()
                    
                    for _ in 0..<iterations {
                        group.enter()
                        DispatchQueue.global().async {
                            let sessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                            lock.lock()
                            sessionIds.append(sessionId)
                            lock.unlock()
                            group.leave()
                        }
                    }
                    
                    group.wait()
                    
                    // All concurrent calls should return the same session ID
                    let uniqueSessionIds = Set(sessionIds.compactMap { $0 })
                    expect(uniqueSessionIds.count).to(equal(1))
                }
                
                it("should handle concurrent session operations safely") {
                    let group = DispatchGroup()
                    
                    // Perform various operations concurrently
                    group.enter()
                    DispatchQueue.global().async {
                        _ = sessionService.getSessionId(at: Date(), readOnly: false)
                        group.leave()
                    }
                    
                    group.enter()
                    DispatchQueue.global().async {
                        sessionService.touchSession()
                        group.leave()
                    }
                    
                    group.enter()
                    DispatchQueue.global().async {
                        _ = sessionService.getNextSessionId()
                        group.leave()
                    }
                    
                    group.wait()
                    
                    // Should not crash and session should still be valid
                    let sessionId = sessionService.getSessionId(at: Date(), readOnly: true)
                    expect(sessionId).toNot(beNil())
                }
            }
            
            describe("Session Change Callbacks") {
                it("should trigger callback on session changes") {
                    var changeReasons: [SessionIDChangeReason] = []
                    
                    sessionService.onSessionIdChanged = { reason in
                        changeReasons.append(reason)
                    }
                    
                    // Create initial session
                    _ = sessionService.getSessionId(at: Date(), readOnly: false)
                    
                    // Start new session
                    sessionService.startSession()
                    
                    // End session
                    sessionService.endSession()
                    
                    // Reset session
                    sessionService.resetSession()
                    
                    // Set custom session
                    sessionService.setSessionId("custom")
                    
                    expect(changeReasons).to(contain(.sessionIdEmpty))
                    expect(changeReasons).to(contain(.sessionStart))
                    expect(changeReasons).to(contain(.sessionEnd))
                    expect(changeReasons).to(contain(.sessionReset))
                    expect(changeReasons).to(contain(.customSessionId))
                }
                
                it("should trigger timeout callback on session expiration") {
                    var changeReason: SessionIDChangeReason?
                    
                    sessionService.onSessionIdChanged = { reason in
                        changeReason = reason
                    }
                    
                    let now = Date()
                    _ = sessionService.getSessionId(at: now, readOnly: false)
                    
                    // Trigger timeout
                    let later = now.addingTimeInterval(31 * 60)
                    _ = sessionService.getSessionId(at: later, readOnly: false)
                    
                    expect(changeReason).to(equal(.sessionTimeout))
                }
                
                it("should trigger max length callback on 24-hour expiration") {
                    var lastChangeReason: SessionIDChangeReason?
                    
                    sessionService.onSessionIdChanged = { reason in
                        lastChangeReason = reason
                    }
                    
                    let now = Date()
                    _ = sessionService.getSessionId(at: now, readOnly: false)
                    
                    // Trigger 24-hour expiration
                    let muchLater = now.addingTimeInterval(24 * 60 * 60 + 60)
                    _ = sessionService.getSessionId(at: muchLater, readOnly: false)
                    
                    expect(lastChangeReason).to(equal(.sessionPastMaximumLength))
                }
            }
        }
    }
}