//
//  ContentView.swift
//  Persona
//
//  Root view for the Persona app.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        PersonaHomeView()
    }
}

#Preview {
    ContentView()
        .environmentObject(PersonaStore())
}
