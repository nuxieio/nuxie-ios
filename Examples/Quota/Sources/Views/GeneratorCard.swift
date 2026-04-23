//
//  GeneratorCard.swift
//  Quota
//
//  Card with generate button and quota display.
//

import SwiftUI

struct GeneratorCard: View {
    @EnvironmentObject var quoteStore: QuoteStore

    private var canGenerate: Bool {
        quoteStore.quotesRemaining > 0 || quoteStore.isUnlimited
    }

    var body: some View {
        VStack(spacing: 16) {
            // Generate button
            Button(action: generateQuote) {
                HStack(spacing: 8) {
                    if quoteStore.isGenerating {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(quoteStore.isGenerating ? "Generating..." : "Generate Quote")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(canGenerate ? Color.accentColor : Color.secondary)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(quoteStore.isGenerating || (!canGenerate && !quoteStore.isUnlimited))

            // Quota display
            if quoteStore.isUnlimited {
                HStack(spacing: 4) {
                    Image(systemName: "infinity")
                    Text("Unlimited quotes")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    Text("\(quoteStore.quotesRemaining)")
                        .fontWeight(.bold)
                        .foregroundStyle(quoteStore.quotesRemaining > 0 ? .primary : .red)
                    Text("of 5 remaining today")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            // Upgrade prompt when at limit
            if quoteStore.quotesRemaining == 0 && !quoteStore.isUnlimited {
                Button("Upgrade for Unlimited") {
                    quoteStore.upgradeToUnlimited()
                }
                .font(.subheadline)
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func generateQuote() {
        Task {
            await quoteStore.generateQuote()
        }
    }
}

#Preview {
    VStack {
        GeneratorCard()
            .environmentObject(QuoteStore())
    }
    .padding()
}
