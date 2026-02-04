//
//  Note.swift
//  Lockbox
//
//  Model for a note entry.
//

import Foundation

struct Note: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var content: String
    var folderId: UUID?
    var tags: [String]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        folderId: UUID? = nil,
        tags: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.folderId = folderId
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var preview: String {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return "No content"
        }
        return String(text.prefix(100))
    }

    static let samples: [Note] = [
        Note(
            title: "Meeting Notes",
            content: "Discussed Q4 goals and team expansion plans. Key points:\n\n1. Revenue target: $1M ARR\n2. Hiring 3 engineers\n3. Launch by November"
        ),
        Note(
            title: "Shopping List",
            content: "Milk, eggs, bread, cheese, apples, coffee, olive oil"
        ),
        Note(
            title: "Ideas",
            content: "App concept for habit tracking with social accountability features. Users can form groups and challenge each other."
        ),
        Note(
            title: "Book Recommendations",
            content: "- Atomic Habits\n- Deep Work\n- The Mom Test\n- Zero to One"
        )
    ]
}

struct Folder: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var color: String

    init(id: UUID = UUID(), name: String, color: String = "blue") {
        self.id = id
        self.name = name
        self.color = color
    }

    static let samples: [Folder] = [
        Folder(name: "Work", color: "blue"),
        Folder(name: "Personal", color: "green"),
        Folder(name: "Ideas", color: "purple")
    ]
}
