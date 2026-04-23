//
//  NoteDetailView.swift
//  Lockbox
//
//  Detail view for editing a note.
//

import SwiftUI

struct NoteDetailView: View {
    @EnvironmentObject var noteStore: NoteStore
    @Environment(\.dismiss) private var dismiss

    let note: Note
    @State private var title: String
    @State private var content: String

    init(note: Note) {
        self.note = note
        _title = State(initialValue: note.title)
        _content = State(initialValue: note.content)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Title", text: $title)
                    .font(.title2.bold())
                    .padding(.horizontal)
                    .padding(.top)

                Divider()
                    .padding(.vertical, 8)
                    .padding(.horizontal)

                TextEditor(text: $content)
                    .padding(.horizontal, 12)
                    .scrollContentBackground(.hidden)
            }
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveNote()
                        dismiss()
                    }
                }
            }
        }
    }

    private func saveNote() {
        var updated = note
        updated.title = title
        updated.content = content
        noteStore.updateNote(updated)
    }
}

#Preview {
    NoteDetailView(note: Note.samples[0])
        .environmentObject(NoteStore())
}
