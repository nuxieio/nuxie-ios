import Foundation

// MARK: - Batch Request

struct BatchRequest: Codable {
    let historicalMigration: Bool?
    let batch: [BatchEventItem]
    
    init(events: [BatchEventItem], historicalMigration: Bool = false) {
        self.batch = events
        self.historicalMigration = historicalMigration ? historicalMigration : nil
    }
    
    enum CodingKeys: String, CodingKey {
        case historicalMigration = "historical_migration"
        case batch
    }
    
    func asDictionary() throws -> [String: Any]? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        return json as? [String: Any]
    }
}

public struct BatchEventItem: Codable {
    public let event: String
    public let distinctId: String
    public let anonDistinctId: String?
    public let timestamp: String?
    public let properties: [String: AnyCodable]?
    public let idempotencyKey: String?
    public let value: Double?
    public let entityId: String?
    
    public init(
        event: String,
        distinctId: String,
        anonDistinctId: String? = nil,
        timestamp: Date? = nil,
        properties: [String: Any]? = nil,
        idempotencyKey: String? = nil,
        value: Double? = nil,
        entityId: String? = nil
    ) {
        self.event = event
        self.distinctId = distinctId
        self.anonDistinctId = anonDistinctId
        
        // Convert Date to ISO8601 string
        if let timestamp = timestamp {
            let formatter = ISO8601DateFormatter()
            self.timestamp = formatter.string(from: timestamp)
        } else {
            self.timestamp = nil
        }
        
        self.properties = properties?.mapValues { AnyCodable($0) }
        self.idempotencyKey = idempotencyKey
        self.value = value
        self.entityId = entityId
    }
    
    enum CodingKeys: String, CodingKey {
        case event
        case distinctId = "distinct_id"
        case anonDistinctId = "$anon_distinct_id"
        case timestamp
        case properties
        case idempotencyKey = "idempotency_key"
        case value
        case entityId
    }
}

// MARK: - Profile Request

struct ProfileRequest: Codable {
    let distinctId: String
    let groups: [String: AnyCodable]?
    let version: Int?
    
    init(distinctId: String, groups: [String: Any]? = nil, version: Int = 1) {
        self.distinctId = distinctId
        self.groups = groups?.mapValues { AnyCodable($0) }
        self.version = version
    }
    
    enum CodingKeys: String, CodingKey {
        case distinctId = "distinct_id"
        case groups
        case version
    }
}

// MARK: - Event Tracking Request

struct EventRequest: Codable {
    let event: String
    let distinctId: String
    let anonDistinctId: String?
    let timestamp: Date?
    let properties: [String: AnyCodable]?
    let idempotencyKey: String?
    let value: Double?
    let entityId: String?
    
    init(
        event: String,
        distinctId: String,
        anonDistinctId: String? = nil,
        timestamp: Date? = nil,
        properties: [String: Any]? = nil,
        idempotencyKey: String? = nil,
        value: Double? = nil,
        entityId: String? = nil
    ) {
        self.event = event
        self.distinctId = distinctId
        self.anonDistinctId = anonDistinctId
        self.timestamp = timestamp
        self.properties = properties?.mapValues { AnyCodable($0) }
        self.idempotencyKey = idempotencyKey
        self.value = value
        self.entityId = entityId
    }
    
    enum CodingKeys: String, CodingKey {
        case event
        case distinctId = "distinct_id"
        case anonDistinctId = "$anon_distinct_id"
        case timestamp
        case properties
        case idempotencyKey = "idempotency_key"
        case value
        case entityId
    }
}
