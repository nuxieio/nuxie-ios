import Foundation

/// Protocol for custom property sanitization
public protocol NuxiePropertiesSanitizer {
    /// Custom sanitization logic for event properties
    /// - Parameter properties: Properties to sanitize
    /// - Returns: Sanitized properties dictionary
    func sanitize(_ properties: [String: Any]) -> [String: Any]
}

/// Built-in sanitization utilities
public class EventSanitizer {
    
    /// Maximum string length for property values
    private static let maxStringLength = 1000
    
    /// Maximum nested depth for dictionaries/arrays
    private static let maxNestingDepth = 10
    
    /// Stage 1: Early data type sanitization
    /// Converts platform-specific types to JSON-serializable types
    /// Called before property enrichment
    /// - Parameter properties: Raw properties dictionary
    /// - Returns: Sanitized properties with valid JSON types
    public static func sanitizeDataTypes(_ properties: [String: Any]) -> [String: Any] {
        return sanitizeValue(properties, depth: 0) as? [String: Any] ?? [:]
    }
    
    /// Stage 2: Custom business logic sanitization  
    /// Applies user-defined sanitization rules
    /// Called after property enrichment
    /// - Parameters:
    ///   - properties: Enriched properties dictionary
    ///   - sanitizer: Optional custom sanitizer
    /// - Returns: Final sanitized properties
    public static func sanitizeProperties(
        _ properties: [String: Any],
        customSanitizer: NuxiePropertiesSanitizer? = nil
    ) -> [String: Any] {
        guard let sanitizer = customSanitizer else {
            return properties
        }
        
        return sanitizer.sanitize(properties)
    }
    
    // MARK: - Private Implementation
    
    /// Recursively sanitize any value to make it JSON-serializable
    private static func sanitizeValue(_ value: Any, depth: Int) -> Any? {
        // Prevent infinite recursion - allow one extra level for leaf values
        guard depth <= maxNestingDepth + 1 else {
            LogWarning("Max nesting depth reached during sanitization, truncating")
            return nil
        }
        
        switch value {
        // Basic JSON types - pass through
        case let string as String:
            return sanitizeString(string)
            
        case let number as NSNumber:
            // Handle Bool separately to preserve type
            if number === kCFBooleanTrue as NSNumber || number === kCFBooleanFalse as NSNumber {
                return number.boolValue
            }
            return number
            
        case is Int, is Int32, is Int64, is Float, is Double:
            return value
            
        case is Bool:
            return value
            
        // Platform types - convert to JSON-compatible
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
            
        case let url as URL:
            return url.absoluteString
            
        case let uuid as UUID:
            return uuid.uuidString
            
        case let data as Data:
            // Convert data to base64 string (be careful with large data)
            if data.count > 1024 {
                LogWarning("Large data object in properties, truncating")
                return data.prefix(1024).base64EncodedString()
            }
            return data.base64EncodedString()
            
        // Collections - recurse
        case let array as [Any]:
            return sanitizeArray(array, depth: depth)
            
        case let dict as [String: Any]:
            return sanitizeDictionary(dict, depth: depth)
            
        // NSNull - preserve
        case is NSNull:
            return value
            
        // nil - convert to NSNull for JSON
        case Optional<Any>.none:
            return NSNull()
            
        // Everything else - try to convert to string or drop
        default:
            if let stringValue = (value as? CustomStringConvertible)?.description {
                LogDebug("Converting non-JSON type to string: \(type(of: value))")
                return sanitizeString(stringValue)
            } else {
                LogWarning("Dropping non-serializable property value: \(type(of: value))")
                return nil
            }
        }
    }
    
    /// Sanitize string values (length limits, invalid characters)
    private static func sanitizeString(_ string: String) -> String {
        var sanitized = string
        
        // Truncate long strings
        if sanitized.count > maxStringLength {
            sanitized = String(sanitized.prefix(maxStringLength))
            LogDebug("Truncated long string property to \(maxStringLength) characters")
        }
        
        // Remove null characters that can break JSON
        sanitized = sanitized.replacingOccurrences(of: "\0", with: "")
        
        return sanitized
    }
    
    /// Sanitize array recursively
    private static func sanitizeArray(_ array: [Any], depth: Int) -> [Any] {
        return array.compactMap { sanitizeValue($0, depth: depth + 1) }
    }
    
    /// Sanitize dictionary recursively
    private static func sanitizeDictionary(_ dict: [String: Any], depth: Int) -> [String: Any] {
        var sanitized: [String: Any] = [:]
        
        for (key, value) in dict {
            // Sanitize key
            let sanitizedKey = sanitizeString(key)
            
            // Sanitize value
            if let sanitizedValue = sanitizeValue(value, depth: depth + 1) {
                sanitized[sanitizedKey] = sanitizedValue
            }
        }
        
        return sanitized
    }
    
    /// Validate that a dictionary can be JSON serialized
    public static func isValidJSONObject(_ object: Any) -> Bool {
        return JSONSerialization.isValidJSONObject(object)
    }
}

/// Default sanitizer implementations for common use cases
public class DefaultPropertiesSanitizers {
    
    /// Privacy-focused sanitizer that removes common PII fields
    public static let privacy = PrivacySanitizer()
    
    /// Compliance sanitizer for strict data regulations
    public static let compliance = ComplianceSanitizer()
    
    /// Development sanitizer that logs all transformations
    public static let debug = DebugSanitizer()
}

/// Remove common PII fields
public class PrivacySanitizer: NuxiePropertiesSanitizer {
    private let piiFields = Set([
        "email", "phone", "phone_number", "ssn", "social_security_number",
        "credit_card", "password", "api_key", "token", "secret"
    ])
    
    public func sanitize(_ properties: [String: Any]) -> [String: Any] {
        var cleaned = properties
        
        // Remove PII fields
        for field in piiFields {
            cleaned.removeValue(forKey: field)
        }
        
        // Mask email-like values in other fields
        for (key, value) in cleaned {
            if let stringValue = value as? String,
               stringValue.contains("@") && stringValue.contains(".") {
                cleaned[key] = maskEmail(stringValue)
            }
        }
        
        return cleaned
    }
    
    private func maskEmail(_ email: String) -> String {
        guard let atIndex = email.firstIndex(of: "@") else { return email }
        let username = String(email[..<atIndex])
        let domain = String(email[email.index(after: atIndex)...])
        
        if username.count >= 2 {
            let masked = String(username.prefix(2)) + "***"
            return "\(masked)@\(domain)"
        }
        
        return "***@\(domain)"
    }
}

/// Strict compliance sanitizer
public class ComplianceSanitizer: NuxiePropertiesSanitizer {
    public func sanitize(_ properties: [String: Any]) -> [String: Any] {
        var cleaned = properties
        
        // Remove empty values
        cleaned = cleaned.filter { key, value in
            if let stringValue = value as? String {
                return !stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
        
        // Ensure no personally identifiable information
        cleaned = DefaultPropertiesSanitizers.privacy.sanitize(cleaned)
        
        return cleaned
    }
}

/// Debug sanitizer that logs all operations
public class DebugSanitizer: NuxiePropertiesSanitizer {
    public func sanitize(_ properties: [String: Any]) -> [String: Any] {
        LogDebug("Input properties: \(properties.keys.joined(separator: ", "))")
        
        let cleaned = properties.filter { key, value in
            let keep = !(value is NSNull)
            if !keep {
                LogDebug("Removing null property: \(key)")
            }
            return keep
        }
        
        LogDebug("Output properties: \(cleaned.keys.joined(separator: ", "))")
        return cleaned
    }
}