//
//  ContentView.swift
//  MoodLog
//
//  Main container view with tab navigation.
//

import SwiftUI

/// Root content view with tab navigation
struct ContentView: View {

    var body: some View {
        TabView {
            TodayView()
                .tabItem {
                    Label("Today", systemImage: "calendar.circle.fill")
                }

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "list.bullet")
                }
        }
        .accentColor(.moodPrimary)
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(MoodStore.shared)
            .environmentObject(EntitlementManager.shared)
    }
}
