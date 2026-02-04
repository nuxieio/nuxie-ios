import Foundation
@testable import Nuxie

/// Mock implementation of IdentityService for testing
public class MockIdentityService: IdentityServiceProtocol {
    private var distinctId = "test-user"
    private var anonymousId = "test-anonymous-id"
    private var userProperties: [String: Any] = [:]
    private var isUserIdentified = true
    
    public func getDistinctId() -> String {
        return distinctId
    }
    
    public func getRawDistinctId() -> String? {
        return isUserIdentified ? distinctId : nil
    }
    
    public func getAnonymousId() -> String {
        return anonymousId
    }
    
    public var isIdentified: Bool {
        return isUserIdentified
    }
    
    public func setDistinctId(_ distinctId: String) {
        self.distinctId = distinctId
        self.isUserIdentified = true
    }
    
    public func reset(keepAnonymousId: Bool) {
        if !keepAnonymousId {
            anonymousId = UUID.v7().uuidString
        }
        distinctId = anonymousId
        userProperties.removeAll()
        isUserIdentified = false
    }
    
    public func clearUserCache(distinctId: String?) {
        // No-op for tests
    }
    
    public func getUserProperties() -> [String: Any] {
        return userProperties
    }
    
    public func setUserProperties(_ properties: [String: Any]) {
        for (key, value) in properties {
            userProperties[key] = value
        }
    }
    
    public func setOnceUserProperties(_ properties: [String: Any]) {
        for (key, value) in properties {
            if userProperties[key] == nil {
                userProperties[key] = value
            }
        }
    }
    
    public func userProperty(for key: String) async -> Any? {
        return userProperties[key]
    }
    
    // Test helpers
    public func reset() {
        reset(keepAnonymousId: false)
        userProperties.removeAll()
    }
    
    public func setUserProperty(_ key: String, value: Any) {
        userProperties[key] = value
    }
    
    public func setIsIdentified(_ identified: Bool) {
        isUserIdentified = identified
    }
    
    public func setAnonymousId(_ id: String) {
        anonymousId = id
        // If user is not identified, update distinctId to match anonymous ID
        if !isUserIdentified {
            distinctId = id
        }
    }
}
