//
//  LogEntry.swift
//  Bridge
//
//  Model for a delegate call log entry.
//

import Foundation

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let payload: [String: Any]?

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }

    var payloadDescription: String? {
        guard let payload = payload else { return nil }
        let pairs = payload.map { "\($0.key): \($0.value)" }
        return "{ \(pairs.joined(separator: ", ")) }"
    }
}
