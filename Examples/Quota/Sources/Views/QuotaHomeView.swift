//
//  QuotaHomeView.swift
//  Quota
//
//  Main view with generator and quote feed.
//

import SwiftUI

struct QuotaHomeView: View {
    @EnvironmentObject var quoteStore: QuoteStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Generator card
                    GeneratorCard()

                    // Quote feed
                    if !quoteStore.quotes.isEmpty {
                        QuoteFeed()
                    }
                }
                .padding()
            }
            .navigationTitle("Quota")
        }
    }
}

#Preview {
    QuotaHomeView()
        .environmentObject(QuoteStore())
}
