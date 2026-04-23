//
//  FoldersView.swift
//  Lockbox
//
//  Pro feature: Manage folders for organizing notes.
//

import SwiftUI

struct FoldersView: View {
    @EnvironmentObject var noteStore: NoteStore
    @State private var showingAddFolder = false
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(noteStore.folders) { folder in
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(folderColor(folder.color))

                        Text(folder.name)

                        Spacer()

                        Text("\(notesInFolder(folder)) notes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete(perform: deleteFolders)
            }
            .listStyle(.plain)
            .navigationTitle("Folders")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showingAddFolder = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .overlay {
                if noteStore.folders.isEmpty {
                    ContentUnavailableView(
                        "No Folders",
                        systemImage: "folder",
                        description: Text("Create folders to organize your notes")
                    )
                }
            }
            .alert("New Folder", isPresented: $showingAddFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Cancel", role: .cancel) {
                    newFolderName = ""
                }
                Button("Create") {
                    if !newFolderName.isEmpty {
                        noteStore.addFolder(name: newFolderName)
                        newFolderName = ""
                    }
                }
            }
        }
    }

    private func folderColor(_ color: String) -> Color {
        switch color {
        case "blue": return .blue
        case "green": return .green
        case "purple": return .purple
        case "orange": return .orange
        case "red": return .red
        default: return .blue
        }
    }

    private func notesInFolder(_ folder: Folder) -> Int {
        noteStore.notes.filter { $0.folderId == folder.id }.count
    }

    private func deleteFolders(at offsets: IndexSet) {
        for index in offsets {
            noteStore.deleteFolder(noteStore.folders[index])
        }
    }
}

#Preview {
    FoldersView()
        .environmentObject({
            let store = NoteStore()
            store.unlockPro()
            return store
        }())
}
