//
//  QuoteFeed.swift
//  Quota
//
//  Feed of generated quotes.
//

import SwiftUI

struct QuoteFeed: View {
    @EnvironmentObject var quoteStore: QuoteStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Today's Quotes")
                    .font(.headline)

                Spacer()

                Text("\(quoteStore.quotes.count) generated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVStack(spacing: 12) {
                ForEach(quoteStore.quotes) { quote in
                    QuoteCard(quote: quote)
                }
            }
        }
    }
}

#Preview {
    ScrollView {
        QuoteFeed()
            .padding()
    }
    .environmentObject({
        let store = QuoteStore()
        // Add sample quotes
        return store
    }())
}
