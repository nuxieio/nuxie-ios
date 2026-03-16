//
//  QuoteCard.swift
//  Quota
//
//  Card displaying a single quote.
//

import SwiftUI

struct QuoteCard: View {
    let quote: Quote

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\"\(quote.text)\"")
                .font(.body)
                .italic()

            HStack {
                Text("— \(quote.author)")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                ShareLink(item: "\"\(quote.text)\" — \(quote.author)") {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Text(quote.formattedDate)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    QuoteCard(quote: Quote(
        text: "The only way to do great work is to love what you do.",
        author: "Steve Jobs"
    ))
    .padding()
}
