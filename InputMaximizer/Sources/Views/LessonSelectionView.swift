//
//  LessonSelectionView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 18.08.25.
//

import SwiftUI
import Foundation

// MARK: - LessonStore

@MainActor
final class LessonStore: ObservableObject {
    @Published var lessons: [Lesson] = []
    init() { load() }

    func load() {
        FileManager.ensureLessonsDir()
        let docsJSON = FileManager.docsLessonsDir.appendingPathComponent("lessons.json")

        let candidateURLs: [URL?] = [
            FileManager.default.fileExists(atPath: docsJSON.path) ? docsJSON : nil,
            Bundle.main.url(forResource: "lessons", withExtension: "json", subdirectory: "Lessons"),
            (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
                .first(where: { $0.lastPathComponent == "lessons.json" })
        ]

        guard let url = candidateURLs.compactMap({ $0 }).first else {
            print("lessons.json not found.")
            lessons = []
            return
        }

        do {
            let data = try Data(contentsOf: url)
            lessons = try JSONDecoder().decode([Lesson].self, from: data)
        } catch {
            print("Failed to decode lessons.json: \(error)")
            lessons = []
        }
    }
}

// MARK: - Deletion / Persistence helpers
extension LessonStore {
    private var docsLessonsJSONURL: URL { FileManager.docsLessonsDir.appendingPathComponent("lessons.json") }

    /// Persist the current in-memory list to Documents/Lessons/lessons.json
    private func saveListToDisk() throws {
        try FileManager.default.createDirectory(at: FileManager.docsLessonsDir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(lessons)
        try data.write(to: docsLessonsJSONURL, options: .atomic)
    }

    /// Can we delete this lesson from device? (Only if its folder exists in Documents.)
    func isDeletable(_ lesson: Lesson) -> Bool {
        let folderURL = FileManager.docsLessonsDir.appendingPathComponent(lesson.folderName, isDirectory: true)
        return FileManager.default.fileExists(atPath: folderURL.path)
    }

    /// Delete lesson folder + remove from lessons.json (Documents only).
    func deleteLesson(id: String) throws {
        guard let idx = lessons.firstIndex(where: { $0.id == id }) else { return }
        let lesson = lessons[idx]

        // Remove files under Documents/Lessons/<folderName> if present
        let folderURL = FileManager.docsLessonsDir.appendingPathComponent(lesson.folderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: folderURL.path) {
            try FileManager.default.removeItem(at: folderURL)
        }

        // Remove from in-memory list and persist
        lessons.remove(at: idx)
        try saveListToDisk()
    }
}

// MARK: - User Folders

struct Folder: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var lessonIDs: [String]

    init(id: UUID = UUID(), name: String, lessonIDs: [String]) {
        self.id = id
        self.name = name
        self.lessonIDs = lessonIDs
    }
}

@MainActor
final class FolderStore: ObservableObject {
    @Published var folders: [Folder] = [] { didSet { save() } }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("folders.json")
    }

    init() { load() }

    func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            folders = try JSONDecoder().decode([Folder].self, from: data)
        } catch {
            folders = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(folders)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("Failed to save folders: \(error)")
        }
    }

    // MARK: - CRUD

    func addFolder(named name: String, lessonIDs: [String]) {
        let unique = uniqueName(from: name)
        folders.append(Folder(name: unique, lessonIDs: lessonIDs))
    }

    func remove(_ folder: Folder) { folders.removeAll { $0.id == folder.id } }

    func index(of id: UUID) -> Int? { folders.firstIndex { $0.id == id } }

    func move(from source: IndexSet, to destination: Int) { folders.move(fromOffsets: source, toOffset: destination) }

    func rename(id: UUID, to newName: String) {
        guard let idx = index(of: id) else { return }
        var f = folders[idx]
        let proposed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposed.isEmpty else { return }
        f.name = uniqueName(from: proposed, excluding: f.id)
        folders[idx] = f
    }

    func setLessonIDs(id: UUID, to lessonIDs: [String]) {
        guard let idx = index(of: id) else { return }
        folders[idx].lessonIDs = lessonIDs
    }

    // MARK: - Helpers

    private func uniqueName(from baseName: String, excluding id: UUID? = nil) -> String {
        let base = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return baseName }
        var unique = base
        var n = 2
        while folders.contains(where: { $0.name == unique && $0.id != id }) {
            unique = "\(base) \(n)"
            n += 1
        }
        return unique
    }
}

extension FolderStore {
    /// Remove a lesson id from every folder (persisted via @Published didSet).
    func removeLessonFromAllFolders(_ lessonID: String) {
        for i in folders.indices {
            folders[i].lessonIDs.removeAll { $0 == lessonID }
        }
    }
}

// MARK: - Folder Detail

@MainActor
struct FolderDetailView: View {
    @EnvironmentObject private var store: LessonStore
    @EnvironmentObject private var audioManager: AudioManager
    @EnvironmentObject private var folderStore: FolderStore

    @State private var lessonToDelete: Lesson?
    @State private var showDeleteConfirm = false

    let folder: Folder
    let lessons: [Lesson]

    private var folderedLessonIDs: Set<String> {
        Set(folderStore.folders.flatMap { $0.lessonIDs })
    }

    private var currentFolder: Folder {
        folderStore.folders.first(where: { $0.id == folder.id }) ?? folder
    }

    private var lessonsInFolder: [Lesson] {
        let ids = currentFolder.lessonIDs
        return ids.compactMap { id in lessons.first(where: { $0.id == id }) }
    }

    @State private var selectedLesson: Lesson?
    @State private var showMembersSheet = false
    @State private var showRenameSheet = false
    @State private var renameText: String = ""
    @State private var selectedLessonIDs = Set<String>()

    var body: some View {
        List {
            if lessonsInFolder.isEmpty {
                ContentUnavailableView(
                    "Empty Folder",
                    systemImage: "folder",
                    description: Text("Add lessons to this folder using the + Add/Remove button.")
                )
            } else {
                ForEach(lessonsInFolder) { lesson in
                    Button { selectedLesson = lesson } label: {
                        HStack {
                            Image(systemName: "book")
                            Text(lesson.title).font(.headline)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            if let idx = folderStore.index(of: currentFolder.id) {
                                var ids = folderStore.folders[idx].lessonIDs
                                ids.removeAll { $0 == lesson.id }
                                folderStore.folders[idx].lessonIDs = ids
                            }
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }

                        if store.isDeletable(lesson) {
                            Button(role: .destructive) {
                                lessonToDelete = lesson
                                showDeleteConfirm = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .onMove { indices, newOffset in
                    guard let idx = folderStore.index(of: currentFolder.id) else { return }
                    var ids = folderStore.folders[idx].lessonIDs
                    ids.move(fromOffsets: indices, toOffset: newOffset)
                    folderStore.folders[idx].lessonIDs = ids
                }
            }
        }
        .navigationTitle(currentFolder.name)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                EditButton()
                Button {
                    selectedLessonIDs = Set(currentFolder.lessonIDs)
                    showMembersSheet = true
                } label: {
                    Label("Add/Remove", systemImage: "plusminus")
                }
                Button {
                    renameText = currentFolder.name
                    showRenameSheet = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
        }
        .navigationDestination(item: $selectedLesson) { lesson in
            ContentView(selectedLesson: lesson, lessons: lessonsInFolder)
                .environmentObject(audioManager)
        }
        .sheet(isPresented: $showMembersSheet) { membersSheet }
        .sheet(isPresented: $showRenameSheet) { renameSheet }
        .alert("Delete lesson?", isPresented: $showDeleteConfirm, presenting: lessonToDelete) { lesson in
            Button("Delete", role: .destructive) {
                audioManager.stop()
                do {
                    try store.deleteLesson(id: lesson.id)
                    folderStore.removeLessonFromAllFolders(lesson.id)
                    store.load()
                } catch {
                    print("Delete failed: \(error)")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { lesson in
            Text("“\(lesson.title)” will be removed from your device.")
        }
    }

    // MARK: - Sheets

    private var membersSheet: some View {
        NavigationStack {
            List(lessons, id: \._id) { lesson in
                let isAlreadyInAFolder = folderedLessonIDs.contains(lesson.id)

                HStack(spacing: 12) {
                    Image(systemName: selectedLessonIDs.contains(lesson.id) ? "checkmark.circle.fill" : "circle")
                        .imageScale(.large)
                        .symbolRenderingMode(.hierarchical)

                    Text(lesson.title)
                        .font(.body)
                        .foregroundStyle(isAlreadyInAFolder ? .orange : .primary)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if selectedLessonIDs.contains(lesson.id) {
                        selectedLessonIDs.remove(lesson.id)
                    } else {
                        selectedLessonIDs.insert(lesson.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add/Remove Lessons")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showMembersSheet = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        folderStore.setLessonIDs(id: currentFolder.id, to: Array(selectedLessonIDs))
                        showMembersSheet = false
                    }
                }
            }
        }
    }

    private var renameSheet: some View {
        NavigationStack {
            Form {
                TextField("Folder name", text: $renameText)
                    .textInputAutocapitalization(.words)
            }
            .navigationTitle("Rename Folder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showRenameSheet = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        folderStore.rename(id: currentFolder.id, to: renameText)
                        showRenameSheet = false
                    }
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - LessonSelectionView

@MainActor
struct LessonSelectionView: View {
    @EnvironmentObject private var audioManager: AudioManager
    @EnvironmentObject private var store: LessonStore
    @EnvironmentObject private var folderStore: FolderStore
    @EnvironmentObject private var generator: GeneratorService

    @State private var lessonToDelete: Lesson?
    @State private var showDeleteConfirm = false
    @State private var resumeLesson: Lesson?
    @State private var selectedLesson: Lesson?

    @State private var toastMessage: String? = nil
    @State private var toastIsSuccess: Bool = false
    @State private var toastAutoDismissTask: Task<Void, Never>? = nil
    
    // Helper: show/dismiss the banner
    private func showToast(message: String, success: Bool) {
        toastAutoDismissTask?.cancel()
        toastMessage = message
        toastIsSuccess = success
        toastAutoDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { withAnimation { toastMessage = nil } }
        }
    }
    
    // Hide lessons that already belong to any folder
    private var folderedLessonIDs: Set<String> {
        Set(folderStore.folders.flatMap { $0.lessonIDs })
    }
    private var unfiledLessons: [Lesson] {
        store.lessons.filter { !folderedLessonIDs.contains($0.id) }
    }

    private var activeLesson: Lesson? {
        guard let fn = audioManager.currentLessonFolderName else { return nil }
        return store.lessons.first { $0.folderName == fn }
    }

    // Create Folder Sheet State
    @State private var showingCreateFolder = false
    @State private var newFolderName: String = ""
    @State private var selectedLessonIDs = Set<String>()

    // MARK: - Helper: choose the correct list for a given lesson
    private func lessonsList(containing lesson: Lesson) -> [Lesson] {
        if let folder = folderStore.folders.first(where: { $0.lessonIDs.contains(lesson.id) }) {
            // Preserve folder order
            let ids = folder.lessonIDs
            return ids.compactMap { id in store.lessons.first(where: { $0.id == id }) }
        } else {
            // Lesson is unfiled → use current unfiled list
            return unfiledLessons
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // NOW PLAYING BAR
                    if let playing = activeLesson,
                       (audioManager.isPlaying || audioManager.isPaused || !audioManager.segments.isEmpty) {
                        Button {
                            // Navigate using the list that actually contains this lesson
                            resumeLesson = playing
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: audioManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 24, weight: .semibold))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Now Playing")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(playing.title)
                                        .font(.headline)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    // Folders
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Folders", systemImage: "folder")
                                .font(.title3.bold())
                            Spacer()
                            Button {
                                newFolderName = ""
                                selectedLessonIDs = []
                                showingCreateFolder = true
                            } label: {
                                Label("New Folder", systemImage: "folder.badge.plus")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Create a new folder")
                        }

                        if folderStore.folders.isEmpty {
                            Text("No folders yet. Tap **New Folder** to group lessons.")
                                .foregroundColor(.secondary)
                        } else {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                ForEach(folderStore.folders) { folder in
                                    NavigationLink(value: folder) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Image(systemName: "folder.fill")
                                                .font(.system(size: 28))
                                            Text(folder.name)
                                                .font(.headline)
                                                .lineLimit(1)
                                            Text("\(folder.lessonIDs.count) lesson\(folder.lessonIDs.count == 1 ? "" : "s")")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        .padding()
                                        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                                        .background(Color.uiFolder)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            folderStore.remove(folder)
                                        } label: {
                                            Label("Delete Folder", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    // Lessons
                    VStack(spacing: 16) {
                        if unfiledLessons.isEmpty {
                            Text("No unfiled lessons. Everything is already in folders.")
                                .multilineTextAlignment(.center)
                                .foregroundColor(.secondary)
                                .padding(.top, 40)
                        } else {
                            ForEach(unfiledLessons) { lesson in
                                Button {
                                    selectedLesson = lesson
                                } label: {
                                    Text(lesson.title)
                                        .font(.headline)
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .background(Color.blue.opacity(0.1))
                                        .cornerRadius(12)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if store.isDeletable(lesson) {
                                        Button(role: .destructive) {
                                            lessonToDelete = lesson
                                            showDeleteConfirm = true
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Select a Lesson")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        GeneratorView()
                            .environmentObject(store) // already provided in your code
                    } label: {
                        ShinyCapsule(title: "Generate", systemImage: "wand.and.stars")
                            .hoverEffect(.highlight)          // iPad/iOS
                            .sensoryFeedback(.impact, trigger: UUID()) // subtle haptic on tap (iOS 18)
                    }
                }
            }
            .navigationDestination(for: Folder.self) { folder in
                FolderDetailView(folder: folder, lessons: store.lessons)
                    .environmentObject(audioManager)
                    .environmentObject(folderStore)
            }
            // ✅ Use the correct list for the selected lesson
            .navigationDestination(item: $selectedLesson) { lesson in
                ContentView(selectedLesson: lesson, lessons: lessonsList(containing: lesson))
                    .environmentObject(audioManager)
            }
            // ✅ Use the correct list for the "Now Playing" lesson
            .navigationDestination(item: $resumeLesson) { lesson in
                ContentView(selectedLesson: lesson, lessons: lessonsList(containing: lesson))
                    .environmentObject(audioManager)
            }
            .sheet(isPresented: $showingCreateFolder) { createFolderSheet }
            .alert("Delete lesson?", isPresented: $showDeleteConfirm, presenting: lessonToDelete) { lesson in
                Button("Delete", role: .destructive) {
                    audioManager.stop()
                    do {
                        try store.deleteLesson(id: lesson.id)
                        folderStore.removeLessonFromAllFolders(lesson.id)
                        store.load()
                    } catch {
                        print("Delete failed: \(error)")
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { lesson in
                Text("“\(lesson.title)” will be removed from your device.")
            }
            
            // ✅ Watch the generator’s lifecycle
            .onChange(of: generator.isBusy) { isBusy in
                guard !isBusy else { return } // only react when it just finished
                let status = generator.status.lowercased()

                if let id = generator.lastLessonID,
                   let lesson = store.lessons.first(where: { $0.id == id || $0.folderName == id }) {
                    // success case: we found the generated lesson
                    withAnimation(.spring()) {
                        showToast(message: "Lesson created: \(lesson.title). Tap to open.", success: true)
                    }
                } else if status.hasPrefix("error") {
                    withAnimation(.spring()) {
                        showToast(message: "Generation failed. Tap to review.", success: false)
                    }
                } else if status.contains("cancelled") {
                    withAnimation(.spring()) {
                        showToast(message: "Generation cancelled.", success: false)
                    }
                }
            }
            // ✅ Place the banner at the very top
            .overlay(alignment: .top) {
                if let message = toastMessage {
                    ToastBanner(message: message, isSuccess: toastIsSuccess) {
                        // On tap: navigate to the lesson if we have it
                        if let id = generator.lastLessonID,
                           let lesson = store.lessons.first(where: { $0.id == id || $0.folderName == id }) {
                            selectedLesson = lesson        // ← uses your existing navigationDestination
                        }
                        withAnimation { toastMessage = nil }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - Create Folder Sheet

    private var createFolderSheet: some View {
        NavigationStack {
            Form {
                Section("Folder Name") {
                    TextField("e.g. Travel, Grammar, Week 1", text: $newFolderName)
                        .textInputAutocapitalization(.words)
                }
                Section("Include Lessons") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(store.lessons, id: \._id) { lesson in
                                let isAlreadyInAFolder = folderedLessonIDs.contains(lesson.id)

                                HStack(spacing: 12) {
                                    Image(systemName: selectedLessonIDs.contains(lesson.id) ? "checkmark.circle.fill" : "circle")
                                        .imageScale(.large)
                                        .symbolRenderingMode(.hierarchical)

                                    Text(lesson.title)
                                        .font(.body)
                                        .foregroundStyle(isAlreadyInAFolder ? .orange : .primary)

                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if selectedLessonIDs.contains(lesson.id) {
                                        selectedLessonIDs.remove(lesson.id)
                                    } else {
                                        selectedLessonIDs.insert(lesson.id)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 4)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .refreshable { store.load() }
                    .frame(minHeight: 400)
                }
            }
            .navigationTitle("New Folder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingCreateFolder = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        folderStore.addFolder(named: newFolderName, lessonIDs: Array(selectedLessonIDs))
                        showingCreateFolder = false
                    }
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Helpers

private extension Color {
    static let uiFolder = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
        ? UIColor.systemYellow.withAlphaComponent(0.18)
        : UIColor.systemYellow.withAlphaComponent(0.22)
    })
}

