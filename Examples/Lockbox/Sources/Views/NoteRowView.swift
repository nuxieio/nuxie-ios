//
//  NoteRowView.swift
//  Lockbox
//
//  Row view for a note in the list.
//

import SwiftUI

struct NoteRowView: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.title.isEmpty ? "Untitled" : note.title)
                .font(.headline)
                .lineLimit(1)

            Text(note.preview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if !note.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(note.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(.accentColor)
                            .clipShape(Capsule())
                    }
                    if note.tags.count > 3 {
                        Text("+\(note.tags.count - 3)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    List {
        NoteRowView(note: Note.samples[0])
        NoteRowView(note: Note(title: "Tagged Note", content: "Some content", tags: ["work", "urgent", "review", "follow-up"]))
    }
}
