//
//  ContentView.swift
//  Lockbox
//
//  Root view with tab bar navigation.
//

import SwiftUI
import Nuxie

struct ContentView: View {
    @EnvironmentObject var noteStore: NoteStore
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NotesListView()
                .tabItem {
                    Label("Notes", systemImage: "note.text")
                }
                .tag(0)

            Group {
                if noteStore.hasPro {
                    FoldersView()
                } else {
                    LockedFeatureView(feature: "folders", description: "Organize your notes into folders")
                }
            }
            .tabItem {
                Label("Folders", systemImage: noteStore.hasPro ? "folder" : "folder.badge.questionmark")
            }
            .tag(1)

            Group {
                if noteStore.hasPro {
                    TagsView()
                } else {
                    LockedFeatureView(feature: "tags", description: "Tag notes for quick filtering")
                }
            }
            .tabItem {
                Label("Tags", systemImage: noteStore.hasPro ? "tag" : "tag.slash")
            }
            .tag(2)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(3)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(NoteStore())
}
