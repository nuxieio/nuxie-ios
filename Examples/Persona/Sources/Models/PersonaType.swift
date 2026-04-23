//
//  PersonaType.swift
//  Persona
//
//  Defines the available persona types from the quiz.
//

import SwiftUI

enum PersonaType: String, Codable, CaseIterable {
    case visionary = "The Visionary"
    case analyst = "The Analyst"
    case creator = "The Creator"
    case connector = "The Connector"
    case achiever = "The Achiever"
    case explorer = "The Explorer"

    var emoji: String {
        switch self {
        case .visionary: return "🔮"
        case .analyst: return "🔬"
        case .creator: return "🎨"
        case .connector: return "🤝"
        case .achiever: return "🏆"
        case .explorer: return "🧭"
        }
    }

    var color: Color {
        switch self {
        case .visionary: return .purple
        case .analyst: return .blue
        case .creator: return .orange
        case .connector: return .green
        case .achiever: return .yellow
        case .explorer: return .cyan
        }
    }

    var description: String {
        switch self {
        case .visionary:
            return "You see possibilities where others see obstacles. Your ability to envision the future and inspire others is your superpower."
        case .analyst:
            return "You thrive on understanding the details. Your methodical approach and attention to data helps you solve complex problems."
        case .creator:
            return "You bring ideas to life. Your creativity and artistic vision allow you to craft unique solutions and experiences."
        case .connector:
            return "You build bridges between people. Your empathy and communication skills create meaningful relationships."
        case .achiever:
            return "You set goals and crush them. Your drive and determination push you to accomplish great things."
        case .explorer:
            return "You seek new experiences. Your curiosity and adaptability lead you to discover new paths."
        }
    }

    var traits: [String] {
        switch self {
        case .visionary:
            return ["Imaginative", "Inspirational", "Future-focused", "Strategic"]
        case .analyst:
            return ["Logical", "Detail-oriented", "Systematic", "Objective"]
        case .creator:
            return ["Innovative", "Expressive", "Original", "Artistic"]
        case .connector:
            return ["Empathetic", "Collaborative", "Communicative", "Supportive"]
        case .achiever:
            return ["Driven", "Goal-oriented", "Competitive", "Persistent"]
        case .explorer:
            return ["Curious", "Adaptable", "Adventurous", "Open-minded"]
        }
    }

    static func random() -> PersonaType {
        allCases.randomElement() ?? .visionary
    }
}
