//
//  PersonaResult.swift
//  Persona
//
//  Model for a quiz result.
//

import Foundation

struct PersonaResult: Identifiable, Codable, Equatable {
    let id: UUID
    let personaType: PersonaType
    let userName: String
    let completedAt: Date

    init(
        id: UUID = UUID(),
        personaType: PersonaType,
        userName: String,
        completedAt: Date = Date()
    ) {
        self.id = id
        self.personaType = personaType
        self.userName = userName
        self.completedAt = completedAt
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: completedAt)
    }
}
