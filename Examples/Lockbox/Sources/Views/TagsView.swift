//
//  TagsView.swift
//  Lockbox
//
//  Pro feature: View and manage tags across all notes.
//

import SwiftUI

struct TagsView: View {
    @EnvironmentObject var noteStore: NoteStore

    private var sortedTags: [String] {
        Array(noteStore.tags).sorted()
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedTags, id: \.self) { tag in
                    HStack(spacing: 12) {
                        Image(systemName: "tag.fill")
                            .foregroundStyle(.accentColor)

                        Text(tag)

                        Spacer()

                        Text("\(notesWithTag(tag)) notes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Tags")
            .overlay {
                if noteStore.tags.isEmpty {
                    ContentUnavailableView(
                        "No Tags",
                        systemImage: "tag",
                        description: Text("Add tags to your notes to see them here")
                    )
                }
            }
        }
    }

    private func notesWithTag(_ tag: String) -> Int {
        noteStore.notes.filter { $0.tags.contains(tag) }.count
    }
}

#Preview {
    TagsView()
        .environmentObject({
            let store = NoteStore()
            store.unlockPro()
            return store
        }())
}
