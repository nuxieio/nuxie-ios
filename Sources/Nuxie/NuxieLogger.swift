import Foundation
import os.log

/// Centralized logging system for the Nuxie SDK
internal final class NuxieLogger {

  // MARK: - Singleton

  static let shared = NuxieLogger()
  private init() {}

  // MARK: - Configuration

  private var logLevel: LogLevel = .debug
  private var enableConsoleLogging: Bool = true
  private var enableFileLogging: Bool = false
  private var redactSensitiveData: Bool = true

  // MARK: - OS Logger

  private lazy var osLogger = OSLog(subsystem: "io.nuxie.sdk", category: "NuxieSDK")

  // MARK: - Configuration

  func configure(
    logLevel: LogLevel,
    enableConsoleLogging: Bool,
    enableFileLogging: Bool,
    redactSensitiveData: Bool
  ) {
    self.logLevel = logLevel
    self.enableConsoleLogging = enableConsoleLogging
    self.enableFileLogging = enableFileLogging
    self.redactSensitiveData = redactSensitiveData
  }

  // MARK: - Logging Methods

  func verbose(
    _ message: String, file: String = #file, function: String = #function, line: Int = #line
  ) {
    log(level: .verbose, message: message, file: file, function: function, line: line)
  }

  func debug(
    _ message: String, file: String = #file, function: String = #function, line: Int = #line
  ) {
    log(level: .debug, message: message, file: file, function: function, line: line)
  }

  func info(
    _ message: String, file: String = #file, function: String = #function, line: Int = #line
  ) {
    log(level: .info, message: message, file: file, function: function, line: line)
  }

  func warning(
    _ message: String, file: String = #file, function: String = #function, line: Int = #line
  ) {
    log(level: .warning, message: message, file: file, function: function, line: line)
  }

  func error(
    _ message: String, file: String = #file, function: String = #function, line: Int = #line
  ) {
    log(level: .error, message: message, file: file, function: function, line: line)
  }

  // MARK: - Private Implementation

  internal func log(level: LogLevel, message: String, file: String, function: String, line: Int) {
    // Check if we should log at this level
    guard level.rawValue >= logLevel.rawValue else { return }

    let fileName = URL(fileURLWithPath: file).lastPathComponent
    let formattedMessage = "[Nuxie] [\(level.description)] [\(fileName):\(line)] \(message)"

    // Console logging
    if enableConsoleLogging {
      // os_log("%{public}@", log: osLogger, type: level.osLogType, formattedMessage)
      print(formattedMessage)
    }

    // File logging (if enabled)
    if enableFileLogging {
      writeToFile(formattedMessage)
    }
  }

  private func writeToFile(_ message: String) {
    // TODO: Implement file logging if needed
    // This would write to a log file in the app's documents directory
  }

  // MARK: - Sensitive Data Handling

  func logAPIKey(_ apiKey: String) -> String {
    guard redactSensitiveData else { return apiKey }

    if apiKey.count > 8 {
      return "\(apiKey.prefix(4))...\(apiKey.suffix(4))"
    } else {
      return "***"
    }
  }

  func logDistinctID(_ distinctId: String?) -> String {
    guard let distinctId = distinctId else { return "nil" }
    guard redactSensitiveData else { return distinctId }

    if distinctId.hasPrefix("anon_") {
      return distinctId  // Anonymous IDs are safe to log
    }

    if distinctId.count > 8 {
      return "\(distinctId.prefix(3))...\(distinctId.suffix(3))"
    } else {
      return "***"
    }
  }
}

// MARK: - LogLevel Extensions

extension LogLevel {
  fileprivate var description: String {
    switch self {
    case .verbose: return "VERBOSE"
    case .debug: return "DEBUG"
    case .info: return "INFO"
    case .warning: return "WARNING"
    case .error: return "ERROR"
    case .none: return "NONE"
    }
  }

  @available(iOS 10.0, *)
  fileprivate var osLogType: OSLogType {
    switch self {
    case .verbose: return .debug
    case .debug: return .debug
    case .info: return .info
    case .warning: return .default
    case .error: return .error
    case .none: return .fault
    }
  }
}

// MARK: - Convenience Global Functions

internal func NuxieLog(
  level: LogLevel, _ message: String, file: String = #file, function: String = #function,
  line: Int = #line
) {
  NuxieLogger.shared.log(level: level, message: message, file: file, function: function, line: line)
}

internal func LogVerbose(
  _ message: String, file: String = #file, function: String = #function, line: Int = #line
) {
  NuxieLogger.shared.verbose(message, file: file, function: function, line: line)
}

internal func LogDebug(
  _ message: String, file: String = #file, function: String = #function, line: Int = #line
) {
  NuxieLogger.shared.debug(message, file: file, function: function, line: line)
}

internal func LogInfo(
  _ message: String, file: String = #file, function: String = #function, line: Int = #line
) {
  NuxieLogger.shared.info(message, file: file, function: function, line: line)
}

internal func LogWarning(
  _ message: String, file: String = #file, function: String = #function, line: Int = #line
) {
  NuxieLogger.shared.warning(message, file: file, function: function, line: line)
}

internal func LogError(
  _ message: String, file: String = #file, function: String = #function, line: Int = #line
) {
  NuxieLogger.shared.error(message, file: file, function: function, line: line)
}
