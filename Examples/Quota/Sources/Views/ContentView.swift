//
//  ContentView.swift
//  Quota
//
//  Root view for the Quota app.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        QuotaHomeView()
    }
}

#Preview {
    ContentView()
        .environmentObject(QuoteStore())
}
