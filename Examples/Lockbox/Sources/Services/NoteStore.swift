//
//  NoteStore.swift
//  Lockbox
//
//  Manages note storage and Pro subscription state.
//

import Foundation
import Nuxie

@MainActor
class NoteStore: ObservableObject {
    @Published var notes: [Note] = []
    @Published var folders: [Folder] = []
    @Published var tags: Set<String> = []
    @Published private(set) var hasPro: Bool = false

    private let userDefaults = UserDefaults.standard
    private let notesKey = "lockbox_notes"
    private let foldersKey = "lockbox_folders"
    private let proKey = "lockbox_has_pro"

    init() {
        loadData()
        loadProStatus()
    }

    // MARK: - Pro Status

    func checkProStatus() -> Bool {
        // In a real app, this would check NuxieSDK.shared.features.isAllowed("pro")
        // For demo purposes, we use local state
        return hasPro
    }

    func unlockPro() {
        hasPro = true
        userDefaults.set(true, forKey: proKey)
    }

    func restorePurchases() {
        // Simulate restore
        // In a real app, call StoreKit restore
    }

    private func loadProStatus() {
        hasPro = userDefaults.bool(forKey: proKey)
    }

    // MARK: - Notes CRUD

    func addNote() -> Note {
        let note = Note()
        notes.insert(note, at: 0)
        saveNotes()
        return note
    }

    func updateNote(_ note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            var updated = note
            updated.updatedAt = Date()
            notes[index] = updated
            saveNotes()
            updateTags()
        }
    }

    func deleteNote(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        saveNotes()
        updateTags()
    }

    // MARK: - Folders (Pro)

    func addFolder(name: String, color: String = "blue") {
        guard hasPro else { return }
        let folder = Folder(name: name, color: color)
        folders.append(folder)
        saveFolders()
    }

    func deleteFolder(_ folder: Folder) {
        guard hasPro else { return }
        folders.removeAll { $0.id == folder.id }
        // Remove folder assignment from notes
        for i in notes.indices where notes[i].folderId == folder.id {
            notes[i].folderId = nil
        }
        saveFolders()
        saveNotes()
    }

    // MARK: - Tags (Pro)

    func addTag(_ tag: String, to note: Note) {
        guard hasPro else { return }
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            var updated = note
            if !updated.tags.contains(tag) {
                updated.tags.append(tag)
            }
            notes[index] = updated
            saveNotes()
            updateTags()
        }
    }

    func removeTag(_ tag: String, from note: Note) {
        guard hasPro else { return }
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            var updated = note
            updated.tags.removeAll { $0 == tag }
            notes[index] = updated
            saveNotes()
            updateTags()
        }
    }

    private func updateTags() {
        tags = Set(notes.flatMap { $0.tags })
    }

    // MARK: - Persistence

    private func loadData() {
        if let data = userDefaults.data(forKey: notesKey),
           let decoded = try? JSONDecoder().decode([Note].self, from: data) {
            notes = decoded
        } else {
            notes = Note.samples
        }

        if let data = userDefaults.data(forKey: foldersKey),
           let decoded = try? JSONDecoder().decode([Folder].self, from: data) {
            folders = decoded
        }

        updateTags()
    }

    private func saveNotes() {
        if let encoded = try? JSONEncoder().encode(notes) {
            userDefaults.set(encoded, forKey: notesKey)
        }
    }

    private func saveFolders() {
        if let encoded = try? JSONEncoder().encode(folders) {
            userDefaults.set(encoded, forKey: foldersKey)
        }
    }
}
