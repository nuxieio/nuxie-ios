import Foundation
import Quick
import Nimble
@testable import Nuxie

final class EventSanitizerTests: QuickSpec {
    
    override class func spec() {
        
        describe("EventSanitizer") {
            
            describe("data type sanitization") {
                
                it("should convert URLs to strings") {
                    let properties = [
                        "url": URL(string: "https://example.com")!,
                        "text": "hello"
                    ] as [String: Any]
                    
                    let sanitized = EventSanitizer.sanitizeDataTypes(properties)
                    
                    expect(sanitized["url"] as? String).to(equal("https://example.com"))
                    expect(sanitized["text"] as? String).to(equal("hello"))
                }
                
                it("should convert dates to ISO8601 strings") {
                    let date = Date(timeIntervalSince1970: 1640995200) // 2022-01-01T00:00:00Z
                    let properties = [
                        "created_at": date,
                        "name": "test"
                    ] as [String: Any]
                    
                    let sanitized = EventSanitizer.sanitizeDataTypes(properties)
                    
                    expect(sanitized["created_at"] as? String).to(equal("2022-01-01T00:00:00Z"))
                    expect(sanitized["name"] as? String).to(equal("test"))
                }
                
                it("should convert UUIDs to strings") {
                    let uuid = UUID()
                    let properties = [
                        "session_id": uuid,
                        "count": 42
                    ] as [String: Any]
                    
                    let sanitized = EventSanitizer.sanitizeDataTypes(properties)
                    
                    expect(sanitized["session_id"] as? String).to(equal(uuid.uuidString))
                    expect(sanitized["count"] as? Int).to(equal(42))
                }
                
                it("should convert data to base64 strings") {
                    let smallData = "test".data(using: .utf8)!
                    let properties = [
                        "data": smallData,
                        "value": 123
                    ] as [String: Any]
                    
                    let sanitized = EventSanitizer.sanitizeDataTypes(properties)
                    
                    expect(sanitized["data"] as? String).to(equal(smallData.base64EncodedString()))
                    expect(sanitized["value"] as? Int).to(equal(123))
                }
                
                it("should truncate large data objects") {
                    let largeData = Data(repeating: 0x42, count: 2000)
                    let properties = [
                        "large_data": largeData
                    ] as [String: Any]
                    
                    let sanitized = EventSanitizer.sanitizeDataTypes(properties)
                    let base64String = sanitized["large_data"] as? String
                    
                    expect(base64String).toNot(beNil())
                    // Check that the data was truncated to 1024 bytes
                    let decodedData = Data(base64Encoded: base64String!)
                    expect(decodedData?.count).to(equal(1024))
                }
                
                it("should preserve basic JSON types") {
                    let properties = [
                        "string": "value",
                        "int": 42,
                        "double": 3.14,
                        "bool": true,
                        "null": NSNull()
                    ] as [String: Any]
                    
                    let sanitized = EventSanitizer.sanitizeDataTypes(properties)
                    
                    expect(sanitized["string"] as? String).to(equal("value"))
                    expect(sanitized["int"] as? Int).to(equal(42))
                    expect(sanitized["double"] as? Double).to(beCloseTo(3.14))
                    expect(sanitized["bool"] as? Bool).to(beTrue())
                    expect(sanitized["null"] is NSNull).to(beTrue())
                }
                
                it("should handle NSNumber correctly") {
                    let properties = [
                        "bool_number": NSNumber(value: true),
                        "int_number": NSNumber(value: 42),
                        "double_number": NSNumber(value: 3.14)
                    ] as [String: Any]
                    
                    let sanitized = EventSanitizer.sanitizeDataTypes(properties)
                    
                    expect(sanitized["bool_number"] as? Bool).to(beTrue())
                    expect(sanitized["int_number"] as? NSNumber).to(equal(42))
                    expect(sanitized["double_number"] as? NSNumber).to(beCloseTo(3.14))
                }
                
                it("should convert nested objects recursively") {
                    let properties = [
                        "user": [
                            "profile_url": URL(string: "https://example.com/profile")!,
                            "created_at": Date(timeIntervalSince1970: 1640995200),
                            "metadata": [
                                "last_seen": Date(timeIntervalSince1970: 1640995200),
                                "device_id": UUID()
                            ] as [String: Any]
                        ],
                        "count": 42
                    ] as [String: Any]
                    
                    let sanitized = EventSanitizer.sanitizeDataTypes(properties)
                    let user = sanitized["user"] as? [String: Any]
                    let metadata = user?["metadata"] as? [String: Any]
                    
                    expect(user?["profile_url"] as? String).to(equal("https://example.com/profile"))
                    expect(user?["created_at"] as? String).to(equal("2022-01-01T00:00:00Z"))
                    expect(metadata?["last_seen"] as? String).to(equal("2022-01-01T00:00:00Z"))
                    expect(metadata?["device_id"] as? String).toNot(beNil())
                    expect(sanitized["count"] as? Int).to(equal(42))
                }
                
                it("should handle arrays with mixed types") {
                    let properties = [
                        "items": [
                            URL(string: "https://example.com")!,
                            Date(timeIntervalSince1970: 1640995200),
                            "string_item",
                            42,
                            ["nested": URL(string: "https://nested.com")!]
                        ]
                    ] as [String: Any]
                    
                    let sanitized = EventSanitizer.sanitizeDataTypes(properties)
                    let items = sanitized["items"] as? [Any]
                    
                    expect(items?[0] as? String).to(equal("https://example.com"))
                    expect(items?[1] as? String).to(equal("2022-01-01T00:00:00Z"))
                    expect(items?[2] as? String).to(equal("string_item"))
                    expect(items?[3] as? Int).to(equal(42))
                    
                    let nestedDict = items?[4] as? [String: Any]
                    expect(nestedDict?["nested"] as? String).to(equal("https://nested.com"))
                }
                
                it("should remove null characters from strings") {
                    let properties = [
                        "text_with_null": "hello\0world",
                        "normal_text": "hello world"
                    ] as [String: Any]
                    
                    let sanitized = EventSanitizer.sanitizeDataTypes(properties)
                    
                    expect(sanitized["text_with_null"] as? String).to(equal("helloworld"))
                    expect(sanitized["normal_text"] as? String).to(equal("hello world"))
                }
                
                it("should truncate long strings") {
                    let longString = String(repeating: "a", count: 2000)
                    let properties = [
                        "long_text": longString,
                        "short_text": "short"
                    ] as [String: Any]
                    
                    let sanitized = EventSanitizer.sanitizeDataTypes(properties)
                    
                    expect((sanitized["long_text"] as? String)?.count).to(equal(1000))
                    expect(sanitized["short_text"] as? String).to(equal("short"))
                }
                
                it("should handle deeply nested structures up to max depth") {
                    var nested: [String: Any] = ["level": 10]
                    for i in stride(from: 9, through: 1, by: -1) {
                        nested = ["level": i, "child": nested]
                    }
                    
                    let properties = ["root": nested] as [String: Any]
                    let sanitized = EventSanitizer.sanitizeDataTypes(properties)
                    
                    // Should preserve structure up to max depth
                    var current = sanitized["root"] as? [String: Any]
                    for i in 1...9 {
                        expect(current?["level"] as? Int).to(equal(i))
                        current = current?["child"] as? [String: Any]
                    }
                    // Level 10 should be present
                    expect(current?["level"] as? Int).to(equal(10))
                }
                
                it("should validate JSON serialization") {
                    let properties = [
                        "valid": "data",
                        "number": 42,
                        "array": [1, 2, 3]
                    ] as [String: Any]
                    
                    let sanitized = EventSanitizer.sanitizeDataTypes(properties)
                    let isValid = EventSanitizer.isValidJSONObject(sanitized)
                    
                    expect(isValid).to(beTrue())
                }
            }
            
            describe("custom properties sanitization") {
                
                it("should apply custom sanitizer if provided") {
                    class TestSanitizer: NuxiePropertiesSanitizer {
                        func sanitize(_ properties: [String: Any]) -> [String: Any] {
                            var sanitized = properties
                            sanitized["custom_field"] = "sanitized"
                            sanitized["modified"] = true
                            return sanitized
                        }
                    }
                    
                    let properties = ["original": "value", "count": 10] as [String: Any]
                    let sanitizer = TestSanitizer()
                    
                    let result = EventSanitizer.sanitizeProperties(properties, customSanitizer: sanitizer)
                    
                    expect(result["original"] as? String).to(equal("value"))
                    expect(result["count"] as? Int).to(equal(10))
                    expect(result["custom_field"] as? String).to(equal("sanitized"))
                    expect(result["modified"] as? Bool).to(beTrue())
                }
                
                it("should return original properties if no custom sanitizer") {
                    let properties = ["key": "value", "number": 42] as [String: Any]
                    
                    let result = EventSanitizer.sanitizeProperties(properties, customSanitizer: nil)
                    
                    expect(result["key"] as? String).to(equal("value"))
                    expect(result["number"] as? Int).to(equal(42))
                }
            }
            
            describe("PrivacySanitizer") {
                let sanitizer = DefaultPropertiesSanitizers.privacy
                
                it("should remove common PII fields") {
                    let properties = [
                        "email": "user@example.com",
                        "phone": "+1234567890",
                        "ssn": "123-45-6789",
                        "credit_card": "4111111111111111",
                        "password": "secret123",
                        "api_key": "sk_test_123",
                        "token": "eyJhbGc...",
                        "name": "John Doe",
                        "city": "San Francisco"
                    ] as [String: Any]
                    
                    let sanitized = sanitizer.sanitize(properties)
                    
                    expect(sanitized["email"]).to(beNil())
                    expect(sanitized["phone"]).to(beNil())
                    expect(sanitized["ssn"]).to(beNil())
                    expect(sanitized["credit_card"]).to(beNil())
                    expect(sanitized["password"]).to(beNil())
                    expect(sanitized["api_key"]).to(beNil())
                    expect(sanitized["token"]).to(beNil())
                    expect(sanitized["name"] as? String).to(equal("John Doe"))
                    expect(sanitized["city"] as? String).to(equal("San Francisco"))
                }
                
                it("should mask email-like values in other fields") {
                    let properties = [
                        "user_contact": "john@example.com",
                        "support": "support@company.com",
                        "website": "https://example.com",
                        "username": "johndoe"
                    ] as [String: Any]
                    
                    let sanitized = sanitizer.sanitize(properties)
                    
                    expect(sanitized["user_contact"] as? String).to(equal("jo***@example.com"))
                    expect(sanitized["support"] as? String).to(equal("su***@company.com"))
                    expect(sanitized["website"] as? String).to(equal("https://example.com"))
                    expect(sanitized["username"] as? String).to(equal("johndoe"))
                }
                
                it("should handle short email usernames") {
                    let properties = [
                        "short_email": "a@example.com",
                        "two_char": "ab@test.com"
                    ] as [String: Any]
                    
                    let sanitized = sanitizer.sanitize(properties)
                    
                    expect(sanitized["short_email"] as? String).to(equal("***@example.com"))
                    expect(sanitized["two_char"] as? String).to(equal("ab***@test.com"))
                }
            }
            
            describe("ComplianceSanitizer") {
                let sanitizer = DefaultPropertiesSanitizers.compliance
                
                it("should remove empty values") {
                    let properties = [
                        "empty_string": "",
                        "whitespace": "   ",
                        "valid": "data",
                        "number": 0,
                        "empty_array": []
                    ] as [String: Any]
                    
                    let sanitized = sanitizer.sanitize(properties)
                    
                    expect(sanitized["empty_string"]).to(beNil())
                    expect(sanitized["whitespace"]).to(beNil())
                    expect(sanitized["valid"] as? String).to(equal("data"))
                    expect(sanitized["number"] as? Int).to(equal(0))
                    let emptyArray = sanitized["empty_array"] as? [Any]
                    expect(emptyArray).toNot(beNil())
                    expect(emptyArray?.isEmpty).to(beTrue())
                }
                
                it("should apply privacy sanitization") {
                    let properties = [
                        "email": "user@example.com",
                        "name": "John Doe",
                        "valid_data": "keep this"
                    ] as [String: Any]
                    
                    let sanitized = sanitizer.sanitize(properties)
                    
                    expect(sanitized["email"]).to(beNil())
                    expect(sanitized["name"] as? String).to(equal("John Doe"))
                    expect(sanitized["valid_data"] as? String).to(equal("keep this"))
                }
            }
            
            describe("DebugSanitizer") {
                let sanitizer = DefaultPropertiesSanitizers.debug
                
                it("should remove null values") {
                    let properties = [
                        "null_value": NSNull(),
                        "valid": "data",
                        "number": 42
                    ] as [String: Any]
                    
                    let sanitized = sanitizer.sanitize(properties)
                    
                    expect(sanitized["null_value"]).to(beNil())
                    expect(sanitized["valid"] as? String).to(equal("data"))
                    expect(sanitized["number"] as? Int).to(equal(42))
                }
                
                it("should preserve non-null values") {
                    let properties = [
                        "string": "value",
                        "number": 0,
                        "bool": false,
                        "array": [1, 2, 3]
                    ] as [String: Any]
                    
                    let sanitized = sanitizer.sanitize(properties)
                    
                    expect(sanitized["string"] as? String).to(equal("value"))
                    expect(sanitized["number"] as? Int).to(equal(0))
                    expect(sanitized["bool"] as? Bool).to(beFalse())
                    expect(sanitized["array"] as? [Int]).to(equal([1, 2, 3]))
                }
            }
        }
    }
}