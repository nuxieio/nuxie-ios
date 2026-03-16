//
//  PersonaHomeView.swift
//  Persona
//
//  Main view with hero card, name input, and results.
//

import SwiftUI

struct PersonaHomeView: View {
    @EnvironmentObject var personaStore: PersonaStore
    @FocusState private var isNameFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    // Hero card
                    PersonaHeroCard()

                    // Name input
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your name (optional)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TextField("Enter your name", text: $personaStore.userName)
                            .textFieldStyle(.roundedBorder)
                            .focused($isNameFocused)
                            .submitLabel(.done)
                            .onSubmit {
                                isNameFocused = false
                            }
                    }

                    // Start button
                    Button(action: startQuiz) {
                        HStack {
                            if personaStore.isQuizActive {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(personaStore.isQuizActive ? "Analyzing..." : "Take the Quiz")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(personaStore.isQuizActive)

                    // Current result
                    if let result = personaStore.currentResult {
                        PersonaResultCard(result: result, isLatest: true)
                    }

                    // Previous results
                    if !personaStore.previousResults.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Previous Results")
                                .font(.headline)

                            ForEach(personaStore.previousResults) { result in
                                PersonaResultCard(result: result, isLatest: false)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Persona")
            .toolbar {
                if personaStore.currentResult != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear") {
                            withAnimation {
                                personaStore.clearResults()
                            }
                        }
                    }
                }
            }
        }
    }

    private func startQuiz() {
        isNameFocused = false
        withAnimation(.spring()) {
            personaStore.startQuiz()
        }
    }
}

#Preview {
    PersonaHomeView()
        .environmentObject(PersonaStore())
}
