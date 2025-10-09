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
        let docsURL = FileManager.docsLessonsDir.appendingPathComponent("lessons.json")

        // 1) Read existing user manifest (if any)
        let decoder = JSONDecoder()
        let docList: [Lesson] = (try? Data(contentsOf: docsURL))
            .flatMap { try? decoder.decode([Lesson].self, from: $0) } ?? []

        // 2) Read bundled defaults (Lessons/lessons.json), with a loose fallback
        let bundleURL =
            Bundle.main.url(forResource: "lessons", withExtension: "json", subdirectory: "Lessons")
            ?? (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
                .first { $0.lastPathComponent == "lessons.json" }

        let bundleList: [Lesson] = bundleURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? decoder.decode([Lesson].self, from: $0) } ?? []

        // 3) Merge: keep user order, append bundled items not already present
        var merged = docList
        var seenIDs = Set(docList.map(\.id))
        var seenFolders = Set(docList.map(\.folderName))
        for item in bundleList {
            if !seenIDs.contains(item.id) && !seenFolders.contains(item.folderName) {
                merged.append(item)
                seenIDs.insert(item.id)
                seenFolders.insert(item.folderName)
            }
        }

        // 4) Publish
        lessons = merged

        // 5) Persist merged manifest to Documents so it “sticks” on existing installs
        if merged != docList {
            do {
                try FileManager.default.createDirectory(at: FileManager.docsLessonsDir, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(merged)
                try data.write(to: docsURL, options: .atomic)
            } catch {
                print("Failed to persist merged lessons.json: \(error)")
            }
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
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle(currentFolder.name)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
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
        .onChange(of: showMembersSheet, initial: false) { _, isShowing in
            if isShowing {
                selectedLessonIDs = Set(currentFolder.lessonIDs)
            }
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
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Add/Remove Lessons")
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
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
        // The preselected items are visible immediately
        .onAppear {
            selectedLessonIDs = Set(currentFolder.lessonIDs)
        }
    }

    private var renameSheet: some View {
        NavigationStack {
            Form {
                TextField("Folder name", text: $renameText)
                    .textInputAutocapitalization(.words)
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Rename Folder")
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
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

    @AppStorage("appearancePreference") private var appearanceRaw: String = AppearancePreference.system.rawValue
    private var appearance: AppearancePreference { AppearancePreference(rawValue: appearanceRaw) ?? .system }

    @State private var lessonToDelete: Lesson?
    @State private var showDeleteConfirm = false
    @State private var resumeLesson: Lesson?
    @State private var selectedLesson: Lesson?

    @State private var toastMessage: String? = nil
    @State private var toastIsSuccess: Bool = false
    @State private var toastAutoDismissTask: Task<Void, Never>? = nil
    
    private func showToast(message: String, success: Bool) {
        toastAutoDismissTask?.cancel()
        toastMessage = message
        toastIsSuccess = success
        toastAutoDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { withAnimation { toastMessage = nil } }
        }
    }
    
    @State private var showAppearanceSheet = false
    
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

    @State private var showingCreateFolder = false
    @State private var newFolderName: String = ""
    @State private var selectedLessonIDs = Set<String>()
    
    // Search and filter state
    @State private var searchText: String = ""
    @State private var showFilterSheet = false
    @State private var filterTargetLanguages = Set<String>()
    @State private var filterHelperLanguages = Set<String>()
    @State private var filterLevels = Set<String>()
    @State private var filterSegmentation: String? = nil
    @State private var filterSpeechSpeed: String? = nil
    @State private var filterFolderStatus: FolderFilterStatus = .all
    @FocusState private var searchIsFocused: Bool
    
    // Add to folder state
    @State private var lessonToAddToFolder: Lesson?
    @State private var showAddToFolderSheet = false
    @State private var selectedFolderForAdd: UUID?
    
    enum FolderFilterStatus: String, CaseIterable {
        case all = "All"
        case inFolders = "In Folders"
        case unfiled = "Unfiled"
    }

    private func lessonsList(containing lesson: Lesson) -> [Lesson] {
        if let folder = folderStore.folders.first(where: { $0.lessonIDs.contains(lesson.id) }) {
            let ids = folder.lessonIDs
            return ids.compactMap { id in store.lessons.first(where: { $0.id == id }) }
        } else {
            return unfiledLessons
        }
    }
    
    // MARK: - Filter Helpers
    
    private var allTargetLanguages: [String] {
        Array(Set(store.lessons.compactMap { $0.targetLanguage })).sorted()
    }
    
    private var allHelperLanguages: [String] {
        Array(Set(store.lessons.compactMap { $0.translationLanguage })).sorted()
    }
    
    private var hasActiveFilters: Bool {
        !searchText.isEmpty ||
        !filterTargetLanguages.isEmpty ||
        !filterHelperLanguages.isEmpty ||
        !filterLevels.isEmpty ||
        filterSegmentation != nil ||
        filterSpeechSpeed != nil ||
        filterFolderStatus != .all
    }
    
    private func matchesFilters(_ lesson: Lesson) -> Bool {
        // Search text
        if !searchText.isEmpty {
            let searchLower = searchText.lowercased()
            if !lesson.title.lowercased().contains(searchLower) {
                return false
            }
        }
        
        // Target language
        if !filterTargetLanguages.isEmpty {
            guard let lang = lesson.targetLanguage, filterTargetLanguages.contains(lang) else {
                return false
            }
        }
        
        // Helper language
        if !filterHelperLanguages.isEmpty {
            guard let lang = lesson.translationLanguage, filterHelperLanguages.contains(lang) else {
                return false
            }
        }
        
        // Folder status
        switch filterFolderStatus {
        case .all:
            break
        case .inFolders:
            if !folderedLessonIDs.contains(lesson.id) {
                return false
            }
        case .unfiled:
            if folderedLessonIDs.contains(lesson.id) {
                return false
            }
        }
        
        return true
    }
    
    private var filteredLessons: [Lesson] {
        store.lessons.filter { matchesFilters($0) }
    }
    
    private var filteredUnfiledLessons: [Lesson] {
        filteredLessons.filter { !folderedLessonIDs.contains($0.id) }
    }
    
    private var filteredFolderedLessons: [Lesson] {
        // When search/filters are active, show matching lessons even if they're in folders
        guard hasActiveFilters else { return [] }
        return filteredLessons.filter { folderedLessonIDs.contains($0.id) }
    }
    
    private var filteredFolders: [(folder: Folder, matchCount: Int)] {
        folderStore.folders.compactMap { folder in
            let matchingLessons = folder.lessonIDs.compactMap { id in
                store.lessons.first(where: { $0.id == id })
            }.filter { matchesFilters($0) }
            
            let count = matchingLessons.count
            return count > 0 ? (folder, count) : nil
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search Bar
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search lessons...", text: $searchText)
                            .textFieldStyle(.plain)
                            .focused($searchIsFocused)
                            .submitLabel(.done)
                            .onSubmit {
                                searchIsFocused = false
                            }
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(uiColor: .tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    
                    if searchIsFocused {
                        Button("Done") {
                            searchIsFocused = false
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        Button {
                            showFilterSheet = true
                        } label: {
                            Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                                .font(.system(size: 22))
                                .foregroundStyle(hasActiveFilters ? .blue : .secondary)
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: searchIsFocused)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)
                
                // Filter chips
                if hasActiveFilters && (!filterTargetLanguages.isEmpty || !filterHelperLanguages.isEmpty || filterFolderStatus != .all) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(filterTargetLanguages), id: \.self) { lang in
                                FilterChip(title: lang, color: .blue) {
                                    filterTargetLanguages.remove(lang)
                                }
                            }
                            ForEach(Array(filterHelperLanguages), id: \.self) { lang in
                                FilterChip(title: lang, color: .green) {
                                    filterHelperLanguages.remove(lang)
                                }
                            }
                            if filterFolderStatus != .all {
                                FilterChip(title: filterFolderStatus.rawValue, color: .orange) {
                                    filterFolderStatus = .all
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 8)
                }
                
                Divider()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {

                        // NOW PLAYING BAR
                        if let playing = activeLesson,
                           (audioManager.isPlaying || audioManager.isPaused || !audioManager.segments.isEmpty) {
                            Button {
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
                                .cardBackground()
                            }
                        }

                        // Folders (with match counts)
                        if !filteredFolders.isEmpty {
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

                                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                    ForEach(filteredFolders, id: \.folder.id) { item in
                                        NavigationLink(value: item.folder) {
                                            VStack(alignment: .leading, spacing: 8) {
                                                Image(systemName: "folder.fill")
                                                    .font(.system(size: 28))
                                                Text(item.folder.name)
                                                    .font(.headline)
                                                    .lineLimit(1)
                                                HStack(spacing: 4) {
                                                    if hasActiveFilters {
                                                        Text("\(item.matchCount)")
                                                            .font(.caption.bold())
                                                            .foregroundColor(.blue)
                                                        Text("of")
                                                            .font(.caption)
                                                            .foregroundColor(.secondary)
                                                    }
                                                    Text("\(item.folder.lessonIDs.count) lesson\(item.folder.lessonIDs.count == 1 ? "" : "s")")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                            .padding()
                                            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                                            .background(Color.folderTile)
                                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.hairline, lineWidth: 1))
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                        }
                                        .contextMenu {
                                            Button(role: .destructive) {
                                                folderStore.remove(item.folder)
                                            } label: {
                                                Label("Delete Folder", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Show divider only if we have both folders and lessons
                        if !filteredFolders.isEmpty && !filteredUnfiledLessons.isEmpty {
                            Divider()
                        }

                        // Lessons from folders (when searching/filtering)
                        if !filteredFolderedLessons.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Label("Matching Lessons in Folders", systemImage: "doc.text.magnifyingglass")
                                        .font(.title3.bold())
                                }
                                
                                VStack(spacing: 16) {
                                    ForEach(filteredFolderedLessons) { lesson in
                                        Button {
                                            selectedLesson = lesson
                                        } label: {
                                            LessonCardWithFolder(lesson: lesson, folderStore: folderStore)
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button {
                                                lessonToAddToFolder = lesson
                                                showAddToFolderSheet = true
                                            } label: {
                                                Label("Move to Folder", systemImage: "folder.badge.plus")
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
                                }
                            }
                        }
                        
                        // Show divider between foldered and unfiled lessons
                        if !filteredFolderedLessons.isEmpty && !filteredUnfiledLessons.isEmpty {
                            Divider()
                        }
                        
                        // Unfiled lessons (with language badges)
                        if !filteredUnfiledLessons.isEmpty {
                            VStack(spacing: 16) {
                                // Show section header only when we also have foldered lessons
                                if !filteredFolderedLessons.isEmpty {
                                    HStack {
                                        Label("Unfiled Lessons", systemImage: "doc")
                                            .font(.title3.bold())
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                
                                ForEach(filteredUnfiledLessons) { lesson in
                                    Button {
                                        selectedLesson = lesson
                                    } label: {
                                        LessonCard(lesson: lesson)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button {
                                            lessonToAddToFolder = lesson
                                            showAddToFolderSheet = true
                                        } label: {
                                            Label("Add to Folder", systemImage: "folder.badge.plus")
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
                            }
                        }
                        
                        // Empty state
                        if filteredFolders.isEmpty && filteredUnfiledLessons.isEmpty && filteredFolderedLessons.isEmpty {
                            VStack(spacing: 16) {
                                if hasActiveFilters {
                                    ContentUnavailableView(
                                        "No matches",
                                        systemImage: "magnifyingglass",
                                        description: Text("Try adjusting your search or filters")
                                    )
                                } else if folderStore.folders.isEmpty && unfiledLessons.isEmpty {
                                    ContentUnavailableView(
                                        "No lessons yet",
                                        systemImage: "book",
                                        description: Text("Tap Generate to create your first lesson")
                                    )
                                } else {
                                    ContentUnavailableView(
                                        "All lessons are in folders",
                                        systemImage: "folder.fill",
                                        description: Text("Great organization!")
                                    )
                                }
                            }
                            .padding(.top, 40)
                        }
                    }
                    .padding()
                }
            }
            .background(Color.appBackground)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Select a Lesson")
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        GeneratorView()
                            .environmentObject(store)
                    } label: {
                        ShinyCapsule(title: "Generate", systemImage: "wand.and.stars")
                    }
                }

                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showAppearanceSheet = true
                    } label: {
                        Image(systemName: "paintbrush")
                    }
                    .accessibilityLabel("Appearance")
                }
            }
            .navigationDestination(for: Folder.self) { folder in
                FolderDetailView(folder: folder, lessons: store.lessons)
                    .environmentObject(audioManager)
                    .environmentObject(folderStore)
            }
            .navigationDestination(item: $selectedLesson) { lesson in
                ContentView(selectedLesson: lesson, lessons: lessonsList(containing: lesson))
                    .environmentObject(audioManager)
            }
            .navigationDestination(item: $resumeLesson) { lesson in
                ContentView(selectedLesson: lesson, lessons: lessonsList(containing: lesson))
                    .environmentObject(audioManager)
            }
            .sheet(isPresented: $showingCreateFolder) { createFolderSheet }
            .sheet(isPresented: $showAppearanceSheet) {
                AppearanceSettingsView()
            }
            .sheet(isPresented: $showFilterSheet) {
                FilterSheet(
                    filterTargetLanguages: $filterTargetLanguages,
                    filterHelperLanguages: $filterHelperLanguages,
                    filterFolderStatus: $filterFolderStatus,
                    allTargetLanguages: allTargetLanguages,
                    allHelperLanguages: allHelperLanguages
                )
            }
            .sheet(isPresented: $showAddToFolderSheet) {
                if let lesson = lessonToAddToFolder {
                    AddToFolderSheet(
                        lesson: lesson,
                        folderStore: folderStore,
                        selectedFolderId: $selectedFolderForAdd,
                        onDismiss: { 
                            showAddToFolderSheet = false
                            lessonToAddToFolder = nil
                        }
                    )
                }
            }
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
            .onChange(of: generator.isBusy, initial: false) { _, isBusy in
                guard !isBusy else { return }
                let status = generator.status.lowercased()

                if let id = generator.lastLessonID,
                   let lesson = store.lessons.first(where: { $0.id == id || $0.folderName == id }) {
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
            
            .onReceive(
                NotificationCenter.default
                    .publisher(for: .openGeneratedLesson)
                    .receive(on: RunLoop.main) // ✅ deliver on main
            ) { notif in
                guard let id = notif.userInfo?["id"] as? String else { return }

                // If store.load() touches model/UI, keep it on main
                store.load()

                if let lesson = store.lessons.first(where: { $0.id == id || $0.folderName == id }) {
                    // UI mutation must be on main
                    selectedLesson = lesson
                }
            }


            .overlay(alignment: .top) {
                if let message = toastMessage {
                    ToastBanner(message: message, isSuccess: toastIsSuccess) {
                        if let id = generator.lastLessonID,
                           let lesson = store.lessons.first(where: { $0.id == id || $0.folderName == id }) {
                            selectedLesson = lesson
                        }
                        withAnimation { toastMessage = nil }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .preferredColorScheme(appearance.colorScheme) // ← honor user appearance choice
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
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("New Folder")
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
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

// MARK: - Filter Chip Component

private struct FilterChip: View {
    let title: String
    let color: Color
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.15))
        .foregroundColor(color)
        .clipShape(Capsule())
    }
}

// MARK: - Lesson Card Component

private struct LessonCard: View {
    let lesson: Lesson
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lesson.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // Language badges
            HStack(spacing: 8) {
                if let targetLang = lesson.targetLanguage, let targetCode = lesson.targetLangCode {
                    LanguageBadge(language: targetLang, code: targetCode, isTarget: true)
                }
                
                if let targetLang = lesson.targetLanguage, let helperLang = lesson.translationLanguage {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                if let helperLang = lesson.translationLanguage, let helperCode = lesson.translationLangCode {
                    LanguageBadge(language: helperLang, code: helperCode, isTarget: false)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .cardBackground()
    }
}

// MARK: - Lesson Card With Folder Component

private struct LessonCardWithFolder: View {
    let lesson: Lesson
    let folderStore: FolderStore
    
    private var folderName: String? {
        folderStore.folders.first(where: { $0.lessonIDs.contains(lesson.id) })?.name
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lesson.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack(spacing: 8) {
                // Language badges
                if let targetLang = lesson.targetLanguage, let targetCode = lesson.targetLangCode {
                    LanguageBadge(language: targetLang, code: targetCode, isTarget: true)
                }
                
                if let targetLang = lesson.targetLanguage, let helperLang = lesson.translationLanguage {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                if let helperLang = lesson.translationLanguage, let helperCode = lesson.translationLangCode {
                    LanguageBadge(language: helperLang, code: helperCode, isTarget: false)
                }
                
                // Folder indicator
                if let folder = folderName {
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.caption2)
                        Text(folder)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15))
                    .foregroundColor(.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .cardBackground()
    }
}

// MARK: - Language Badge Component

private struct LanguageBadge: View {
    let language: String
    let code: String
    let isTarget: Bool
    
    var body: some View {
        HStack(spacing: 4) {
            Text(shortCode)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isTarget ? Color.blue.opacity(0.15) : Color.green.opacity(0.15))
        .foregroundColor(isTarget ? .blue : .green)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
    
    private var shortCode: String {
        // Extract short language code (e.g., "pt-BR" -> "PT", "en" -> "EN")
        code.split(separator: "-").first.map(String.init)?.uppercased() ?? code.uppercased()
    }
}

// MARK: - Filter Sheet

private struct FilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filterTargetLanguages: Set<String>
    @Binding var filterHelperLanguages: Set<String>
    @Binding var filterFolderStatus: LessonSelectionView.FolderFilterStatus
    
    let allTargetLanguages: [String]
    let allHelperLanguages: [String]
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Target Language") {
                    if allTargetLanguages.isEmpty {
                        Text("No target languages available")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(allTargetLanguages, id: \.self) { lang in
                            Button {
                                if filterTargetLanguages.contains(lang) {
                                    filterTargetLanguages.remove(lang)
                                } else {
                                    filterTargetLanguages.insert(lang)
                                }
                            } label: {
                                HStack {
                                    Text(lang)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if filterTargetLanguages.contains(lang) {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                        }
                    }
                }
                
                Section("Helper Language") {
                    if allHelperLanguages.isEmpty {
                        Text("No helper languages available")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(allHelperLanguages, id: \.self) { lang in
                            Button {
                                if filterHelperLanguages.contains(lang) {
                                    filterHelperLanguages.remove(lang)
                                } else {
                                    filterHelperLanguages.insert(lang)
                                }
                            } label: {
                                HStack {
                                    Text(lang)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if filterHelperLanguages.contains(lang) {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                        }
                    }
                }
                
                Section("Folder Status") {
                    ForEach(LessonSelectionView.FolderFilterStatus.allCases, id: \.self) { status in
                        Button {
                            filterFolderStatus = status
                        } label: {
                            HStack {
                                Text(status.rawValue)
                                    .foregroundColor(.primary)
                                Spacer()
                                if filterFolderStatus == status {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear All") {
                        filterTargetLanguages.removeAll()
                        filterHelperLanguages.removeAll()
                        filterFolderStatus = .all
                    }
                    .disabled(filterTargetLanguages.isEmpty && filterHelperLanguages.isEmpty && filterFolderStatus == .all)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Add to Folder Sheet

private struct AddToFolderSheet: View {
    let lesson: Lesson
    @ObservedObject var folderStore: FolderStore
    @Binding var selectedFolderId: UUID?
    let onDismiss: () -> Void
    
    @State private var showCreateNewFolder = false
    @State private var newFolderName = ""
    
    private var currentFolderId: UUID? {
        folderStore.folders.first(where: { $0.lessonIDs.contains(lesson.id) })?.id
    }
    
    var body: some View {
        NavigationStack {
            List {
                if !folderStore.folders.isEmpty {
                    Section("Select Folder") {
                        ForEach(folderStore.folders) { folder in
                            Button {
                                moveToFolder(folder.id)
                            } label: {
                                HStack {
                                    Image(systemName: "folder.fill")
                                        .foregroundColor(.secondary)
                                    Text(folder.name)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if currentFolderId == folder.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                        }
                    }
                }
                
                Section {
                    Button {
                        showCreateNewFolder = true
                    } label: {
                        Label("Create New Folder", systemImage: "folder.badge.plus")
                    }
                }
                
                if currentFolderId != nil {
                    Section {
                        Button(role: .destructive) {
                            removeFromCurrentFolder()
                        } label: {
                            Label("Remove from Current Folder", systemImage: "folder.badge.minus")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Move Lesson")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss()
                    }
                }
            }
            .alert("New Folder", isPresented: $showCreateNewFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Cancel", role: .cancel) {
                    newFolderName = ""
                }
                Button("Create") {
                    createFolderAndAdd()
                }
                .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("Enter a name for the new folder")
            }
        }
    }
    
    private func moveToFolder(_ folderId: UUID) {
        // Remove from current folder if in one
        if let currentFolder = currentFolderId,
           let idx = folderStore.index(of: currentFolder) {
            folderStore.folders[idx].lessonIDs.removeAll { $0 == lesson.id }
        }
        
        // Add to new folder
        if let idx = folderStore.index(of: folderId) {
            if !folderStore.folders[idx].lessonIDs.contains(lesson.id) {
                folderStore.folders[idx].lessonIDs.append(lesson.id)
            }
        }
        
        onDismiss()
    }
    
    private func removeFromCurrentFolder() {
        if let currentFolder = currentFolderId,
           let idx = folderStore.index(of: currentFolder) {
            folderStore.folders[idx].lessonIDs.removeAll { $0 == lesson.id }
        }
        onDismiss()
    }
    
    private func createFolderAndAdd() {
        let trimmedName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        // Remove from current folder if in one
        if let currentFolder = currentFolderId,
           let idx = folderStore.index(of: currentFolder) {
            folderStore.folders[idx].lessonIDs.removeAll { $0 == lesson.id }
        }
        
        // Create new folder with this lesson
        folderStore.addFolder(named: trimmedName, lessonIDs: [lesson.id])
        newFolderName = ""
        onDismiss()
    }
}

