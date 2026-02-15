//
//  ContentView.swift
//  Bridge
//
//  Root view for the Bridge demo app.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        BridgeView()
    }
}

#Preview {
    ContentView()
        .environmentObject(ActionHandler())
}
