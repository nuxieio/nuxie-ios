//
//  Quote.swift
//  Quota
//
//  Model for a generated quote.
//

import Foundation

struct Quote: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let author: String
    let generatedAt: Date

    init(id: UUID = UUID(), text: String, author: String, generatedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.author = author
        self.generatedAt = generatedAt
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: generatedAt)
    }
}
