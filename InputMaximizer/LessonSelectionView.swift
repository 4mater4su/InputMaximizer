//
//  LessonSelectionView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 18.08.25.
//

import SwiftUI

// MARK: - User Folders (NEW)
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
        guard var idx = index(of: id) else { return }
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

// MARK: - Folder Detail (NEW)
struct FolderDetailView: View {
    @EnvironmentObject private var audioManager: AudioManager
    @EnvironmentObject private var folderStore: FolderStore
    let folder: Folder
    let lessons: [Lesson]

    // Inside FolderDetailView
    private var folderedLessonIDs: Set<String> {
        Set(folderStore.folders.flatMap { $0.lessonIDs })
    }
    
    // Always use the latest folder state from the store
    private var currentFolder: Folder { folderStore.folders.first(where: { $0.id == folder.id }) ?? folder }

    // Preserve the folder's order for its lessons
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
                ContentUnavailableView("Empty Folder", systemImage: "folder", description: Text("Add lessons to this folder using the + Add/Remove button."))
            } else {
                ForEach(lessonsInFolder) { lesson in
                    Button {
                        selectedLesson = lesson
                        audioManager.stop()
                    } label: {
                        HStack {
                            Image(systemName: "book")
                            Text(lesson.title)
                                .font(.headline)
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
                EditButton() // enables drag-to-reorder lessons
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
        // LessonSelectionView
        .navigationDestination(item: $selectedLesson) { lesson in
            ContentView(selectedLesson: lesson, lessons: lessonsInFolder)
                .environmentObject(audioManager)
        }
        .sheet(isPresented: $showMembersSheet) { membersSheet }
        .sheet(isPresented: $showRenameSheet) { renameSheet }
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

                    Spacer(minLength: 0) // keep everything left-aligned
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showMembersSheet = false }
                }
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showRenameSheet = false }
                }
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

// MARK: - LessonSelectionView (UPDATED)
struct LessonSelectionView: View {
    @EnvironmentObject private var audioManager: AudioManager
    @StateObject private var store = LessonStore()
    @StateObject private var folderStore = FolderStore()

    @State private var selectedLesson: Lesson?

    // Hide lessons that already belong to any folder
    private var folderedLessonIDs: Set<String> {
        Set(folderStore.folders.flatMap { $0.lessonIDs })
    }
    private var unfiledLessons: [Lesson] {
        store.lessons.filter { !folderedLessonIDs.contains($0.id) }
    }

    // Create Folder Sheet State
    @State private var showingCreateFolder = false
    @State private var newFolderName: String = ""
    @State private var selectedLessonIDs = Set<String>()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Folders Section (NEW)
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
                            // Grid of folders
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

                    // Lessons Section (existing)
                    VStack(spacing: 16) {
                        if unfiledLessons.isEmpty {
                            Text("No unfiled lessons. Everything is already in folders.")
                                .multilineTextAlignment(.center)
                                .foregroundColor(.secondary)
                                .padding(.top, 40)
                        } else {
                            ForEach(unfiledLessons) { lesson in
                                Button {
                                    audioManager.stop()
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
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Select a Lesson")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink("Generator") {
                        GeneratorView()
                            .environmentObject(store)     // << inject LessonStore
                    }
                }
            }
            .navigationDestination(for: Folder.self) { folder in
                FolderDetailView(folder: folder, lessons: store.lessons)
                    .environmentObject(audioManager)
                    .environmentObject(folderStore)
            }
            // Programmatic lesson navigation
            .navigationDestination(item: $selectedLesson) { lesson in
                ContentView(selectedLesson: lesson, lessons: unfiledLessons)
                    .environmentObject(audioManager)
            }
            .sheet(isPresented: $showingCreateFolder) { createFolderSheet }
        }
    }

    // MARK: - Create Folder Sheet (NEW)
    private var createFolderSheet: some View {
        NavigationStack {
            Form {
                Section("Folder Name") {
                    TextField("e.g. Travel, Grammar, Week 1", text: $newFolderName)
                        .textInputAutocapitalization(.words)
                }
                Section("Include Lessons") {
                    // Multi-select list of lessons
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
                    .refreshable {
                        store.load()
                    }
                    .frame(minHeight: 400) // ⬅️ increase available height for scrolling
                }

            }
            .navigationTitle("New Folder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingCreateFolder = false }
                }
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

// MARK: - Folder Manager (reorder folders)
struct FolderManagerView: View {
    @EnvironmentObject private var folderStore: FolderStore

    var body: some View {
        List {
            ForEach(folderStore.folders) { folder in
                HStack {
                    Image(systemName: "folder.fill")
                    Text(folder.name)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        folderStore.remove(folder)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onMove(perform: folderStore.move)
        }
        .navigationTitle("Manage Folders")
        .toolbar { EditButton() }
    }
}

// MARK: - Helpers
private extension Lesson { var _id: String { id } }

private extension Color {
    static let uiFolder = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor.systemYellow.withAlphaComponent(0.18) : UIColor.systemYellow.withAlphaComponent(0.22)
    })
}
