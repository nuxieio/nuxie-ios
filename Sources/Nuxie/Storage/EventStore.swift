import Foundation
import SQLite3

// SQLite constants for Swift
private let SQLITE_STATIC = unsafeBitCast(0, to: sqlite3_destructor_type.self)
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-based event storage implementation
/// Thread safety: Guaranteed by actor isolation
actor SQLiteEventStore {

  // MARK: - Properties

  private var db: OpaquePointer?
  private(set) var dbPath: String?

  // MARK: - SQL Statements

  private let createTableSQL = """
    CREATE TABLE IF NOT EXISTS events (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        properties BLOB NOT NULL,
        timestamp INTEGER NOT NULL,
        user_id TEXT,
        session_id TEXT
    );
    """

  private let createIndexSQL = [
    "CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp);",
    "CREATE INDEX IF NOT EXISTS idx_events_user_id ON events(user_id);",
    "CREATE INDEX IF NOT EXISTS idx_events_name ON events(name);",
    "CREATE INDEX IF NOT EXISTS idx_events_session_id ON events(session_id);",
    "CREATE INDEX IF NOT EXISTS idx_events_user_name_time ON events(user_id, name, timestamp DESC);",
    "CREATE INDEX IF NOT EXISTS idx_events_user_time ON events(user_id, timestamp DESC);",
    "CREATE INDEX IF NOT EXISTS idx_events_session_time ON events(session_id, timestamp DESC);",
  ]

  private let insertEventSQL = """
    INSERT INTO events (id, name, properties, timestamp, user_id, session_id)
    VALUES (?, ?, ?, ?, ?, ?);
    """

  private let queryEventsSQL = """
    SELECT id, name, properties, timestamp, user_id, session_id
    FROM events
    ORDER BY timestamp DESC
    LIMIT ?;
    """

  private let deleteOldEventsSQL = """
    DELETE FROM events
    WHERE timestamp < ?;
    """

  private let countEventsSQL = "SELECT COUNT(*) FROM events;"

  // MARK: - Initialization

  init() {
  }

  deinit {
    close()
  }

  // MARK: - Database Management

  /// Initialize the database and create tables
  /// - Parameter path: Path to SQLite database file
  /// - Throws: EventStorageError if initialization fails
  func initialize(path: URL?) throws {
    // Determine the base directory
    let baseDir: URL
    if let customPath = path {
      // Use custom path with nuxie subdirectory
      baseDir = customPath.appendingPathComponent("nuxie", isDirectory: true)
    } else {
      // Use default Application Support/nuxie directory
      let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!
      baseDir = appSupport.appendingPathComponent("nuxie", isDirectory: true)
    }
    
    // Create directory if needed
    try? FileManager.default.createDirectory(
      at: baseDir, withIntermediateDirectories: true, attributes: nil)
    
    // Set database path
    let dbPath = baseDir.appendingPathComponent("events.db")
    self.dbPath = dbPath.path

    // Open database
    if sqlite3_open(dbPath.path, &db) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      sqlite3_close(db)
      db = nil
      throw EventStorageError.insertFailed(
        NSError(domain: "SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Set PRAGMAs for proper concurrency handling
    // WAL mode for better concurrent access
    _ = sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
    // Wait up to 5 seconds if database is locked
    _ = sqlite3_exec(db, "PRAGMA busy_timeout=5000;", nil, nil, nil)
    // Balance between safety and performance
    _ = sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
    // Ensure referential integrity
    _ = sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)

    // Create table
    if sqlite3_exec(db, createTableSQL, nil, nil, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.insertFailed(
        NSError(domain: "SQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Create indexes
    for indexSQL in createIndexSQL {
      if sqlite3_exec(db, indexSQL, nil, nil, nil) != SQLITE_OK {
        let errorMessage = String(cString: sqlite3_errmsg(db))
        LogWarning("Failed to create index: \(errorMessage)")
      }
    }

    LogInfo("Event database initialized at: \(dbPath)")
  }

  /// Close the database connection
  func close() {
    if let db = db {
      sqlite3_close(db)
      self.db = nil
    }
  }

  /// Reset the database (close and delete database)
  func reset() {
    close()
    if let dbPath = dbPath {
      try? FileManager.default.removeItem(atPath: dbPath)
      self.dbPath = nil
    }
  }

  // MARK: - Event Operations

  /// Insert a new event into the database
  /// - Parameter event: Event to store
  /// - Throws: EventStorageError if insert fails
  func insertEvent(_ event: StoredEvent) throws {
    LogDebug("SQLiteEventStore.insertEvent - id: \(event.id), name: \(event.name)")
    
    guard let db = db else {
      LogError("Database not initialized!")
      throw EventStorageError.databaseNotInitialized
    }

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, insertEventSQL, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      LogError("Failed to prepare insert statement: \(errorMessage)")
      throw EventStorageError.insertFailed(
        NSError(domain: "SQLite", code: 3, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Bind parameters
    sqlite3_bind_text(statement, 1, event.id, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, event.name, -1, SQLITE_TRANSIENT)

    // Properties are already Data, bind directly
    _ = event.properties.withUnsafeBytes { bytes in
      sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
    }

    sqlite3_bind_int64(statement, 4, Int64(event.timestamp.timeIntervalSince1970 * 1000))  // Store as milliseconds

    if let distinctId = event.distinctId {
      sqlite3_bind_text(statement, 5, distinctId, -1, SQLITE_TRANSIENT)
    } else {
      sqlite3_bind_null(statement, 5)
    }

    // Use sessionId field directly for database storage
    if let sessionId = event.sessionId {
      sqlite3_bind_text(statement, 6, sessionId, -1, SQLITE_TRANSIENT)
    } else {
      sqlite3_bind_null(statement, 6)
    }

    // Execute
    if sqlite3_step(statement) != SQLITE_DONE {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      LogError("Failed to execute insert statement: \(errorMessage)")
      throw EventStorageError.insertFailed(
        NSError(domain: "SQLite", code: 4, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }
    
    LogDebug("Successfully inserted event into database: \(event.name)")
  }

  /// Query recent events from the database
  /// - Parameter limit: Maximum number of events to return (default: 100)
  /// - Returns: Array of stored events
  /// - Throws: EventStorageError if query fails
  func queryRecentEvents(limit: Int = 100) throws -> [StoredEvent] {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, queryEventsSQL, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 5, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Bind limit
    sqlite3_bind_int(statement, 1, Int32(limit))

    // Execute and collect results
    var events: [StoredEvent] = []

    while sqlite3_step(statement) == SQLITE_ROW {
      let id: String = {
        if let text = sqlite3_column_text(statement, 0) {
          return String(cString: text)
        }
        return ""
      }()

      let name: String = {
        if let text = sqlite3_column_text(statement, 1) {
          return String(cString: text)
        }
        return ""
      }()

      let propertiesBlob = sqlite3_column_blob(statement, 2)
      let propertiesSize = sqlite3_column_bytes(statement, 2)
      let propertiesData = Data(bytes: propertiesBlob!, count: Int(propertiesSize))

      let timestampMs = sqlite3_column_int64(statement, 3)
      let timestamp = Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)

      let distinctId: String? = {
        if sqlite3_column_type(statement, 4) == SQLITE_NULL {
          return nil
        }
        if let text = sqlite3_column_text(statement, 4) {
          return String(cString: text)
        }
        return nil
      }()

      let sessionId: String? = {
        if sqlite3_column_type(statement, 5) == SQLITE_NULL {
          return nil
        }
        if let text = sqlite3_column_text(statement, 5) {
          return String(cString: text)
        }
        return nil
      }()

      // Don't decode properties - keep as Data for lazy decoding
      let event = StoredEvent(
        id: id,
        name: name,
        properties: propertiesData,
        timestamp: timestamp,
        distinctId: distinctId,
        sessionId: sessionId
      )

      events.append(event)
    }

    return events
  }

  /// Delete events older than the specified date
  /// - Parameter olderThan: Delete events older than this date
  /// - Returns: Number of events deleted
  /// - Throws: EventStorageError if deletion fails
  func deleteEventsOlderThan(_ olderThan: Date) throws -> Int {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, deleteOldEventsSQL, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.deleteFailed(
        NSError(domain: "SQLite", code: 6, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Bind timestamp (in milliseconds)
    let timestampMs = Int64(olderThan.timeIntervalSince1970 * 1000)
    sqlite3_bind_int64(statement, 1, timestampMs)

    // Execute
    if sqlite3_step(statement) != SQLITE_DONE {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.deleteFailed(
        NSError(domain: "SQLite", code: 7, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    return Int(sqlite3_changes(db))
  }

  /// Get total count of events in database
  /// - Returns: Number of events stored
  /// - Throws: EventStorageError if query fails
  func getEventCount() throws -> Int {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, countEventsSQL, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 8, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Execute
    if sqlite3_step(statement) == SQLITE_ROW {
      return Int(sqlite3_column_int(statement, 0))
    }

    return 0
  }

  // MARK: - Event Query Methods

  /// Check if a specific event exists for a user
  /// - Parameters:
  ///   - name: Event name to search for
  ///   - distinctId: User ID to filter by
  ///   - since: Optional date to filter events after
  /// - Returns: True if event exists, false otherwise
  /// - Throws: EventStorageError if query fails
  func hasEvent(name: String, distinctId: String, since: Date? = nil) throws -> Bool {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    let sql: String
    if let since = since {
      sql = """
        SELECT EXISTS(
            SELECT 1 FROM events 
            WHERE user_id = ? AND name = ? AND timestamp >= ?
            LIMIT 1
        );
        """
    } else {
      sql = """
        SELECT EXISTS(
            SELECT 1 FROM events 
            WHERE user_id = ? AND name = ?
            LIMIT 1
        );
        """
    }

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 9, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Bind parameters
    sqlite3_bind_text(statement, 1, distinctId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, name, -1, SQLITE_TRANSIENT)

    if let since = since {
      let timestampMs = Int64(since.timeIntervalSince1970 * 1000)
      sqlite3_bind_int64(statement, 3, timestampMs)
    }

    // Execute
    if sqlite3_step(statement) == SQLITE_ROW {
      return sqlite3_column_int(statement, 0) != 0
    }

    return false
  }

  /// Count events of a specific type for a user
  /// - Parameters:
  ///   - name: Event name to count
  ///   - distinctId: User ID to filter by
  ///   - since: Optional start date (inclusive)
  ///   - until: Optional end date (inclusive)
  /// - Returns: Number of matching events
  /// - Throws: EventStorageError if query fails
  func countEvents(name: String, distinctId: String, since: Date? = nil, until: Date? = nil) throws
    -> Int
  {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    var sql = "SELECT COUNT(*) FROM events WHERE user_id = ? AND name = ?"
    var bindIndex: Int32 = 3

    if since != nil {
      sql += " AND timestamp >= ?"
    }
    if until != nil {
      sql += " AND timestamp <= ?"
    }
    sql += ";"

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 10, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Bind parameters
    sqlite3_bind_text(statement, 1, distinctId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, name, -1, SQLITE_TRANSIENT)

    if let since = since {
      let timestampMs = Int64(since.timeIntervalSince1970 * 1000)
      sqlite3_bind_int64(statement, bindIndex, timestampMs)
      bindIndex += 1
    }
    if let until = until {
      let timestampMs = Int64(until.timeIntervalSince1970 * 1000)
      sqlite3_bind_int64(statement, bindIndex, timestampMs)
    }

    // Execute
    if sqlite3_step(statement) == SQLITE_ROW {
      return Int(sqlite3_column_int(statement, 0))
    }

    return 0
  }

  /// Get the timestamp of the most recent event of a specific type for a user
  /// - Parameters:
  ///   - name: Event name to search for
  ///   - distinctId: User ID to filter by
  ///   - since: Optional start date (inclusive)
  ///   - until: Optional end date (inclusive)
  /// - Returns: Date of most recent event, or nil if no events found
  /// - Throws: EventStorageError if query fails
  func getLastEventTime(name: String, distinctId: String, since: Date? = nil, until: Date? = nil)
    throws -> Date?
  {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    var sql = "SELECT MAX(timestamp) FROM events WHERE user_id = ? AND name = ?"
    var bindIndex: Int32 = 3

    if since != nil {
      sql += " AND timestamp >= ?"
    }
    if until != nil {
      sql += " AND timestamp <= ?"
    }
    sql += ";"

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 11, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Bind parameters
    sqlite3_bind_text(statement, 1, distinctId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, name, -1, SQLITE_TRANSIENT)

    if let since = since {
      let timestampMs = Int64(since.timeIntervalSince1970 * 1000)
      sqlite3_bind_int64(statement, bindIndex, timestampMs)
      bindIndex += 1
    }
    if let until = until {
      let timestampMs = Int64(until.timeIntervalSince1970 * 1000)
      sqlite3_bind_int64(statement, bindIndex, timestampMs)
    }

    // Execute
    if sqlite3_step(statement) == SQLITE_ROW {
      if sqlite3_column_type(statement, 0) == SQLITE_NULL {
        return nil
      }
      let timestampMs = sqlite3_column_int64(statement, 0)
      return Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)
    }

    return nil
  }

  /// Query events for a specific user with efficient database filtering
  /// - Parameters:
  ///   - distinctId: User ID to filter by
  ///   - limit: Maximum number of events to return
  /// - Returns: Array of events for the user
  /// - Throws: EventStorageError if query fails
  func queryEventsForUser(_ distinctId: String, limit: Int = 100) throws -> [StoredEvent] {
    LogDebug("SQLiteEventStore.queryEventsForUser - distinctId: \(distinctId), limit: \(limit)")
    
    guard let db = db else {
      LogError("Database not initialized for query!")
      throw EventStorageError.databaseNotInitialized
    }

    let sql = """
      SELECT id, name, properties, timestamp, user_id, session_id
      FROM events
      WHERE user_id = ?
      ORDER BY timestamp DESC
      LIMIT ?;
      """

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 13, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Bind parameters
    sqlite3_bind_text(statement, 1, distinctId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int(statement, 2, Int32(limit))

    // Execute and collect results
    var events: [StoredEvent] = []

    while sqlite3_step(statement) == SQLITE_ROW {
      let id: String = {
        if let text = sqlite3_column_text(statement, 0) {
          return String(cString: text)
        }
        return ""
      }()

      let name: String = {
        if let text = sqlite3_column_text(statement, 1) {
          return String(cString: text)
        }
        return ""
      }()

      let propertiesBlob = sqlite3_column_blob(statement, 2)
      let propertiesSize = sqlite3_column_bytes(statement, 2)
      let propertiesData = Data(bytes: propertiesBlob!, count: Int(propertiesSize))

      let timestampMs = sqlite3_column_int64(statement, 3)
      let timestamp = Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)

      // user_id is already known (we're filtering by it)

      let sessionId: String? = {
        if sqlite3_column_type(statement, 5) == SQLITE_NULL {
          return nil
        }
        if let text = sqlite3_column_text(statement, 5) {
          return String(cString: text)
        }
        return nil
      }()

      // Don't decode properties - keep as Data for lazy decoding
      let event = StoredEvent(
        id: id,
        name: name,
        properties: propertiesData,
        timestamp: timestamp,
        distinctId: distinctId,
        sessionId: sessionId
      )

      events.append(event)
    }

    LogDebug("SQLiteEventStore.queryEventsForUser returning \(events.count) events")
    return events
  }

  /// Reassign events from one user to another (for anonymous → identified transitions)
  /// - Parameters:
  ///   - fromUserId: Old user ID (typically anonymous)
  ///   - toUserId: New user ID (typically identified)
  /// - Returns: Number of events reassigned
  /// - Throws: EventStorageError if update fails
  func reassignEvents(from fromUserId: String, to toUserId: String) throws -> Int {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    let sql = """
      UPDATE events
      SET user_id = ?
      WHERE user_id = ?;
      """

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.insertFailed(
        NSError(domain: "SQLite", code: 14, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Bind parameters
    sqlite3_bind_text(statement, 1, toUserId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, fromUserId, -1, SQLITE_TRANSIENT)

    // Execute
    if sqlite3_step(statement) != SQLITE_DONE {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.insertFailed(
        NSError(domain: "SQLite", code: 15, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    return Int(sqlite3_changes(db))
  }

  /// Query events for a specific session
  /// - Parameter sessionId: Session ID to filter by
  /// - Returns: Array of events from the session
  /// - Throws: EventStorageError if query fails
  func querySessionEvents(_ sessionId: String) throws -> [StoredEvent] {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    let sql = """
      SELECT id, name, properties, timestamp, user_id, session_id
      FROM events
      WHERE session_id = ?
      ORDER BY timestamp DESC;
      """

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 12, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Bind session ID
    sqlite3_bind_text(statement, 1, sessionId, -1, SQLITE_TRANSIENT)

    // Execute and collect results
    var events: [StoredEvent] = []

    while sqlite3_step(statement) == SQLITE_ROW {
      let id: String = {
        if let text = sqlite3_column_text(statement, 0) {
          return String(cString: text)
        }
        return ""
      }()

      let name: String = {
        if let text = sqlite3_column_text(statement, 1) {
          return String(cString: text)
        }
        return ""
      }()

      let propertiesBlob = sqlite3_column_blob(statement, 2)
      let propertiesSize = sqlite3_column_bytes(statement, 2)
      let propertiesData = Data(bytes: propertiesBlob!, count: Int(propertiesSize))

      let timestampMs = sqlite3_column_int64(statement, 3)
      let timestamp = Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)

      let distinctId: String? = {
        if sqlite3_column_type(statement, 4) == SQLITE_NULL {
          return nil
        }
        if let text = sqlite3_column_text(statement, 4) {
          return String(cString: text)
        }
        return nil
      }()

      // Session ID is already known (we're filtering by it)

      // Don't decode properties - keep as Data for lazy decoding
      let event = StoredEvent(
        id: id,
        name: name,
        properties: propertiesData,
        timestamp: timestamp,
        distinctId: distinctId,
        sessionId: sessionId
      )

      events.append(event)
    }

    return events
  }
}
