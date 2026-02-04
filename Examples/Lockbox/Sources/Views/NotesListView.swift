//
//  NotesListView.swift
//  Lockbox
//
//  List of all notes with add/delete functionality.
//

import SwiftUI

struct NotesListView: View {
    @EnvironmentObject var noteStore: NoteStore
    @State private var selectedNote: Note?

    var body: some View {
        NavigationStack {
            List {
                ForEach(noteStore.notes) { note in
                    NoteRowView(note: note)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedNote = note
                        }
                }
                .onDelete(perform: deleteNotes)
            }
            .listStyle(.plain)
            .navigationTitle("Lockbox")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: addNote) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $selectedNote) { note in
                NoteDetailView(note: note)
            }
            .overlay {
                if noteStore.notes.isEmpty {
                    ContentUnavailableView(
                        "No Notes",
                        systemImage: "note.text",
                        description: Text("Tap + to create your first note")
                    )
                }
            }
        }
    }

    private func addNote() {
        let note = noteStore.addNote()
        selectedNote = note
    }

    private func deleteNotes(at offsets: IndexSet) {
        for index in offsets {
            noteStore.deleteNote(noteStore.notes[index])
        }
    }
}

#Preview {
    NotesListView()
        .environmentObject(NoteStore())
}
