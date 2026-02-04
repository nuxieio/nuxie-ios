//
//  PersonaHeroCard.swift
//  Persona
//
//  Hero card for the quiz introduction.
//

import SwiftUI

struct PersonaHeroCard: View {
    var body: some View {
        VStack(spacing: 16) {
            // Icon grid
            HStack(spacing: 8) {
                ForEach(PersonaType.allCases.prefix(3), id: \.self) { type in
                    Text(type.emoji)
                        .font(.title)
                }
            }
            HStack(spacing: 8) {
                ForEach(PersonaType.allCases.suffix(3), id: \.self) { type in
                    Text(type.emoji)
                        .font(.title)
                }
            }

            VStack(spacing: 8) {
                Text("Discover Your")
                    .font(.title2)

                Text("Persona")
                    .font(.largeTitle.bold())
            }

            Text("Answer a few questions to find out who you really are")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.1),
                    Color.accentColor.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

#Preview {
    PersonaHeroCard()
        .padding()
}
