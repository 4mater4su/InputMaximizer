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
    @Published var lessons: [Lesson] = [] {
        didSet {
            // Auto-save whenever lessons array changes (but skip during initial load)
            if isLoaded {
                try? saveListToDisk()
            }
        }
    }
    
    private var isLoaded = false
    
    init() { load() }

    func load() {
        isLoaded = false // Prevent didSet from saving during load
        
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

        // 5) Persist merged manifest to Documents so it "sticks" on existing installs
        if merged != docList {
            do {
                try FileManager.default.createDirectory(at: FileManager.docsLessonsDir, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(merged)
                try data.write(to: docsURL, options: .atomic)
            } catch {
                print("Failed to persist merged lessons.json: \(error)")
            }
        }
        
        isLoaded = true // Enable auto-save after initial load
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
        print("💾 Saved \(lessons.count) lessons to disk")
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
    
    /// Delete multiple lessons at once
    func deleteLessons(ids: [String]) throws {
        for id in ids {
            try deleteLesson(id: id)
        }
    }
}

// MARK: - User Folders

struct Folder: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var lessonIDs: [String]
    var isSeries: Bool
    
    init(id: UUID = UUID(), name: String, lessonIDs: [String], isSeries: Bool = false) {
        self.id = id
        self.name = name
        self.lessonIDs = lessonIDs
        self.isSeries = isSeries
    }
    
    // Custom decoding for backwards compatibility
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        lessonIDs = try container.decode([String].self, forKey: .lessonIDs)
        isSeries = try container.decodeIfPresent(Bool.self, forKey: .isSeries) ?? false
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, name, lessonIDs, isSeries
    }
}

@MainActor
final class FolderStore: ObservableObject {
    @Published var folders: [Folder] = [] {
        didSet {
            // Only save if already loaded to avoid unnecessary saves during init
            if isLoaded {
                save()
            }
        }
    }
    
    private var isLoaded = false

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("folders.json")
    }

    init() { load() }

    func load() {
        isLoaded = false // Prevent didSet from saving during load
        
        do {
            let data = try Data(contentsOf: fileURL)
            folders = try JSONDecoder().decode([Folder].self, from: data)
        } catch {
            folders = []
        }
        
        isLoaded = true // Enable auto-save after initial load
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

    func addFolder(named name: String, lessonIDs: [String], isSeries: Bool = false) {
        let unique = uniqueName(from: name)
        folders.append(Folder(name: unique, lessonIDs: lessonIDs, isSeries: isSeries))
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
    
    func toggleSeriesStatus(id: UUID) {
        guard let idx = index(of: id) else { return }
        folders[idx].isSeries.toggle()
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
    
    /// Remove multiple lesson IDs from all folders
    func removeLessonsFromAllFolders(_ lessonIDs: [String]) {
        for id in lessonIDs {
            removeLessonFromAllFolders(id)
        }
    }
}

// MARK: - Folder Lesson Card

private struct FolderLessonCard: View {
    let lesson: Lesson
    
    var body: some View {
        HStack(spacing: 12) {
            // Book icon
            Image(systemName: "book.fill")
                .font(.system(size: 24))
                .foregroundStyle(.blue)
                .frame(width: 40, height: 40)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            
            VStack(alignment: .leading, spacing: 4) {
                Text(lesson.title)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                
                if let target = lesson.targetLanguage, let helper = lesson.translationLanguage {
                    HStack(spacing: 4) {
                        Text(target)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(helper)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer(minLength: 0)
            
            // Chevron
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separator).opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.03), radius: 2, x: 0, y: 1)
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
    
    private var filteredLessonsForMembers: [Lesson] {
        if memberSearchText.isEmpty {
            return lessons
        }
        return lessons.filter { lesson in
            lesson.title.localizedCaseInsensitiveContains(memberSearchText)
        }
    }

    @State private var selectedLesson: Lesson?
    @State private var showMembersSheet = false
    @State private var showRenameSheet = false
    @State private var renameText: String = ""
    @State private var selectedLessonIDs = Set<String>()
    @State private var isReorderingEnabled = false
    @State private var isSelectionMode = false
    @State private var selectedLessonsForBatch = Set<String>()
    @State private var memberSearchText: String = ""

    private var emptyView: some View {
                ContentUnavailableView(
                    "Empty Folder",
                    systemImage: "folder",
            description: Text("Add lessons using the + button above.")
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
    
    private var lessonRows: some View {
                ForEach(lessonsInFolder) { lesson in
            lessonRow(for: lesson)
        }
        .onMove { indices, newOffset in
            guard let idx = folderStore.index(of: currentFolder.id) else { return }
            var ids = folderStore.folders[idx].lessonIDs
            ids.move(fromOffsets: indices, toOffset: newOffset)
            folderStore.folders[idx].lessonIDs = ids
        }
    }
    
    private func lessonRow(for lesson: Lesson) -> some View {
        Button { 
            if isSelectionMode {
                if selectedLessonsForBatch.contains(lesson.id) {
                    selectedLessonsForBatch.remove(lesson.id)
                } else {
                    selectedLessonsForBatch.insert(lesson.id)
                }
            } else {
                selectedLesson = lesson 
            }
        } label: {
            HStack {
                if isSelectionMode {
                    Image(systemName: selectedLessonsForBatch.contains(lesson.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selectedLessonsForBatch.contains(lesson.id) ? .blue : .secondary)
                }
                FolderLessonCard(lesson: lesson)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .moveDisabled(isSelectionMode || !isReorderingEnabled)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelectionMode {
                swipeActionsContent(for: lesson)
            }
        }
        .contextMenu {
            if !isSelectionMode {
                contextMenuContent(for: lesson)
            }
        }
    }
    
    @ViewBuilder
    private func swipeActionsContent(for lesson: Lesson) -> some View {
        if store.isDeletable(lesson) {
            Button(role: .destructive) {
                lessonToDelete = lesson
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        
                        Button {
                            if let idx = folderStore.index(of: currentFolder.id) {
                                var ids = folderStore.folders[idx].lessonIDs
                                ids.removeAll { $0 == lesson.id }
                                folderStore.folders[idx].lessonIDs = ids
                            }
                        } label: {
            Label("Remove", systemImage: "folder.badge.minus")
        }
        .tint(.orange)
    }
    
    @ViewBuilder
    private func contextMenuContent(for lesson: Lesson) -> some View {
        Button {
            if let idx = folderStore.index(of: currentFolder.id) {
                var ids = folderStore.folders[idx].lessonIDs
                ids.removeAll { $0 == lesson.id }
                folderStore.folders[idx].lessonIDs = ids
            }
        } label: {
            Label("Remove from Folder", systemImage: "folder.badge.minus")
                        }

                        if store.isDeletable(lesson) {
                            Button(role: .destructive) {
                                lessonToDelete = lesson
                                showDeleteConfirm = true
                            } label: {
                Label("Delete Lesson", systemImage: "trash")
            }
        }
    }

    private var lessonList: some View {
        List {
            if lessonsInFolder.isEmpty {
                emptyView
            } else {
                lessonRows
            }
        }
            .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
            .environment(\.defaultMinListRowHeight, 0)
            .environment(\.editMode, (isReorderingEnabled && !isSelectionMode) ? .constant(.active) : .constant(.inactive))
            .environment(\.layoutDirection, .rightToLeft)
            .scrollIndicators(.hidden)
    }
    
    var body: some View {
        ZStack(alignment: .trailing) {
            lessonList
        }
        .environment(\.layoutDirection, .leftToRight)
        .navigationTitle(currentFolder.name)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isSelectionMode && !selectedLessonsForBatch.isEmpty {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete (\(selectedLessonsForBatch.count))", systemImage: "trash")
                    }
                }
                
                Button {
                    folderStore.toggleSeriesStatus(id: currentFolder.id)
                } label: {
                    Image(systemName: currentFolder.isSeries ? "text.book.closed.fill" : "folder.fill")
                        .foregroundColor(currentFolder.isSeries ? .blue : .secondary)
                }
                .accessibilityLabel(currentFolder.isSeries ? "Mark as regular folder" : "Mark as series")
                
                Button {
                    selectedLessonIDs = Set(currentFolder.lessonIDs)
                    showMembersSheet = true
                } label: {
                    Label("Add/Remove", systemImage: "plus.circle")
                }
                
                Menu {
                    Button {
                        isReorderingEnabled.toggle()
                    } label: {
                        Label(isReorderingEnabled ? "Done Reordering" : "Reorder Lessons", 
                              systemImage: isReorderingEnabled ? "checkmark" : "arrow.up.arrow.down")
                    }
                    
                    Button {
                        isSelectionMode.toggle()
                        selectedLessonsForBatch.removeAll()
                        if isSelectionMode {
                            isReorderingEnabled = false
                        }
                    } label: {
                        Label(isSelectionMode ? "Cancel Selection" : "Select Lessons", 
                              systemImage: isSelectionMode ? "xmark" : "checkmark.circle")
                    }
                    
                Button {
                    renameText = currentFolder.name
                    showRenameSheet = true
                } label: {
                        Label("Rename Folder", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .navigationDestination(item: $selectedLesson) { lesson in
            ContentView(selectedLesson: lesson, lessons: lessonsInFolder)
                .environmentObject(audioManager)
        }
        .sheet(isPresented: $showMembersSheet) { membersSheet }
        .sheet(isPresented: $showRenameSheet) { renameSheet }
        .alert(isSelectionMode ? "Delete \(selectedLessonsForBatch.count) lesson(s)?" : "Delete lesson?", 
               isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                audioManager.stop()
                do {
                    if isSelectionMode {
                        let idsToDelete = Array(selectedLessonsForBatch)
                        try store.deleteLessons(ids: idsToDelete)
                        folderStore.removeLessonsFromAllFolders(idsToDelete)
                        selectedLessonsForBatch.removeAll()
                        isSelectionMode = false
                    } else if let lesson = lessonToDelete {
                        try store.deleteLesson(id: lesson.id)
                        folderStore.removeLessonFromAllFolders(lesson.id)
                    }
                    store.load()
                } catch {
                    print("Delete failed: \(error)")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if isSelectionMode {
                Text("This action cannot be undone.")
            } else if let lesson = lessonToDelete {
                Text("\"\(lesson.title)\" will be removed from your device.")
            }
        }
        .onChange(of: showMembersSheet, initial: false) { _, isShowing in
            if isShowing {
                selectedLessonIDs = Set(currentFolder.lessonIDs)
                memberSearchText = "" // Clear search when opening sheet
            }
        }
        
    }

    // MARK: - Sheets

    private var membersSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // Quick stats
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(selectedLessonIDs.count)")
                                .font(.title2.bold())
                                .foregroundColor(.blue)
                            Text("selected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Divider()
                            .frame(height: 40)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(filteredLessonsForMembers.count)")
                                .font(.title2.bold())
                                .foregroundColor(.primary)
                            Text(memberSearchText.isEmpty ? "total" : "found")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Button(selectedLessonIDs.isEmpty ? "Select All" : "Deselect All") {
                            if selectedLessonIDs.isEmpty {
                                selectedLessonIDs = Set(filteredLessonsForMembers.map { $0.id })
                            } else {
                                selectedLessonIDs.removeAll()
                            }
                        }
                        .font(.subheadline.weight(.medium))
                    }
                    .padding()
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search lessons...", text: $memberSearchText)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                        
                        if !memberSearchText.isEmpty {
                            Button {
                                memberSearchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    
                    // Lessons
                    VStack(spacing: 8) {
                        ForEach(filteredLessonsForMembers, id: \._id) { lesson in
                            let isSelected = selectedLessonIDs.contains(lesson.id)
                            let otherFolders = folderStore.folders
                                .filter { $0.id != currentFolder.id && $0.lessonIDs.contains(lesson.id) }
                                .map { $0.name }
                            
                            Button {
                                if isSelected {
                        selectedLessonIDs.remove(lesson.id)
                    } else {
                        selectedLessonIDs.insert(lesson.id)
                    }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(isSelected ? .blue : .secondary)
                                        .frame(width: 28)
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(lesson.title)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                            .multilineTextAlignment(.leading)
                                        
                                        if !otherFolders.isEmpty {
                                            HStack(spacing: 4) {
                                                Image(systemName: "folder.fill")
                                                    .font(.caption2)
                                                Text("Also in: \(otherFolders.joined(separator: ", "))")
                                                    .font(.caption)
                                                    .lineLimit(1)
                                            }
                                            .foregroundColor(.orange)
                                        }
                                    }
                                    
                                    Spacer(minLength: 0)
                                }
                                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(isSelected ? Color.blue.opacity(0.08) : Color(.secondarySystemBackground))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(isSelected ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1.5)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Manage Lessons")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { 
                    Button("Cancel") { showMembersSheet = false } 
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        folderStore.setLessonIDs(id: currentFolder.id, to: Array(selectedLessonIDs))
                        showMembersSheet = false
                    }
                }
            }
        }
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
    @State private var refreshTrigger = UUID()
    
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
                            .toolbar {
                                ToolbarItemGroup(placement: .keyboard) {
                                    Spacer()
                                    Button("Done") {
                                        searchIsFocused = false
                                    }
                                }
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
                    
                    Button {
                        showFilterSheet = true
                    } label: {
                        Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .font(.system(size: 22))
                            .foregroundStyle(hasActiveFilters ? .blue : .secondary)
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
                                            Image(systemName: item.folder.isSeries ? "text.book.closed.fill" : "folder.fill")
                                                .font(.system(size: 28))
                                                .foregroundColor(item.folder.isSeries ? .blue : .secondary)
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
                                                .id("\(lesson.id)-\(refreshTrigger)")
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
                            .id("foldered-\(refreshTrigger)")
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
                ContentView(selectedLesson: lesson, lessons: lessonsList(containing: lesson), isViewingAllLessons: true)
                    .environmentObject(audioManager)
            }
            .navigationDestination(item: $resumeLesson) { lesson in
                ContentView(selectedLesson: lesson, lessons: lessonsList(containing: lesson), isViewingAllLessons: true)
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
                            refreshTrigger = UUID() // Force refresh
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
        SmartFolderCreationSheet(
            store: store,
            folderStore: folderStore,
            folderedLessonIDs: folderedLessonIDs,
            newFolderName: $newFolderName,
            selectedLessonIDs: $selectedLessonIDs,
            onDismiss: { showingCreateFolder = false }
        )
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
    
    private var folderNames: [String] {
        folderStore.folders
            .filter { $0.lessonIDs.contains(lesson.id) }
            .map { $0.name }
    }
    
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
            
            // Folder indicators - show all folders
            if !folderNames.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(folderNames, id: \.self) { folderName in
                                Text(folderName)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.secondary.opacity(0.15))
                                    .foregroundColor(.secondary)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                                    Image(systemName: folder.isSeries ? "text.book.closed.fill" : "folder.fill")
                                        .foregroundColor(folder.isSeries ? .blue : .secondary)
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

// MARK: - Smart Folder Creation Sheet

private struct SmartFolderCreationSheet: View {
    @ObservedObject var store: LessonStore
    @ObservedObject var folderStore: FolderStore
    let folderedLessonIDs: Set<String>
    
    @Binding var newFolderName: String
    @Binding var selectedLessonIDs: Set<String>
    let onDismiss: () -> Void
    
    @State private var searchText = ""
    @State private var selectedSuggestion: String?
    @State private var cachedSuggestions: [String]?
    @FocusState private var folderNameFocused: Bool
    @FocusState private var searchFocused: Bool
    
    // Smart suggestions based on lesson titles - computed once
    private func computeSuggestions() -> [String] {
        var suggestions = Set<String>()
        let unfiledLessons = store.lessons.filter { !folderedLessonIDs.contains($0.id) }
        
        guard !unfiledLessons.isEmpty else { return [] }
        
        // 1. Extract common keywords from titles
        let keywords = [
            "travel", "food", "restaurant", "shopping", "market", "café", "coffee",
            "grammar", "conversation", "family", "work", "school", "office",
            "culture", "history", "music", "sports", "health", "medicine",
            "business", "hotel", "airport", "transport", "train", "bus",
            "weather", "daily", "routine", "hobby", "weekend", "vacation",
            "home", "house", "apartment", "city", "town", "village",
            "friend", "meeting", "phone", "email", "letter", "news",
            "doctor", "hospital", "pharmacy", "emergency", "help",
            "bank", "money", "price", "pay", "buy", "sell",
            "time", "date", "calendar", "schedule", "appointment"
        ]
        
        for lesson in unfiledLessons {
            let title = lesson.title.lowercased()
            for keyword in keywords {
                if title.contains(keyword) {
                    suggestions.insert(keyword.capitalized)
                }
            }
        }
        
        // 2. Language-based suggestions (one per unique language)
        let uniqueLanguages = Set(unfiledLessons.compactMap { $0.targetLanguage })
        for lang in uniqueLanguages {
            suggestions.insert(lang)
        }
        
        // 3. Extract common words from titles (frequency analysis)
        var wordFrequency: [String: Int] = [:]
        let stopWords = Set(["the", "a", "an", "in", "on", "at", "to", "for", "of", "and", "or", "but", "is", "are", "was", "were", "be", "been", "being", "have", "has", "had", "do", "does", "did", "will", "would", "could", "should", "may", "might", "can", "you", "your", "my", "i", "me", "we", "us", "it", "this", "that"])
        
        for lesson in unfiledLessons {
            let words = lesson.title.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty && $0.count > 3 && !stopWords.contains($0) }
            
            for word in words {
                wordFrequency[word, default: 0] += 1
            }
        }
        
        // Add words that appear in multiple lessons
        let commonWords = wordFrequency.filter { $0.value > 1 }.keys
        for word in commonWords {
            suggestions.insert(word.capitalized)
        }
        
        // 4. Level-based suggestions if available
        let levels = Set(["Beginner", "Intermediate", "Advanced", "A1", "A2", "B1", "B2", "C1", "C2"])
        for lesson in unfiledLessons {
            let title = lesson.title
            for level in levels {
                if title.contains(level) {
                    suggestions.insert(level)
                }
            }
        }
        
        // 5. Generic helpful suggestions based on count
        if unfiledLessons.count >= 3 {
            suggestions.insert("Recent")
            suggestions.insert("Favorites")
        }
        
        // 6. Time-based suggestions if dates mentioned
        let timeKeywords = ["morning", "afternoon", "evening", "night", "today", "tomorrow", "week", "month"]
        for lesson in unfiledLessons {
            let title = lesson.title.lowercased()
            for timeWord in timeKeywords {
                if title.contains(timeWord) {
                    suggestions.insert("Daily Life")
                    break
                }
            }
        }
        
        // Return top 8 suggestions, prioritizing those with more matches
        return Array(suggestions)
            .sorted { a, b in
                let countA = unfiledLessons.filter { 
                    $0.title.lowercased().contains(a.lowercased()) || 
                    $0.targetLanguage?.lowercased().contains(a.lowercased()) == true 
                }.count
                let countB = unfiledLessons.filter { 
                    $0.title.lowercased().contains(b.lowercased()) || 
                    $0.targetLanguage?.lowercased().contains(b.lowercased()) == true 
                }.count
                return countA > countB
            }
            .prefix(8)
            .map { $0 }
    }
    
    private var filteredLessons: [Lesson] {
        let unfiled = store.lessons.filter { !folderedLessonIDs.contains($0.id) }
        if searchText.isEmpty {
            return unfiled
        }
        let searchLower = searchText.lowercased()
        return unfiled.filter { $0.title.lowercased().contains(searchLower) }
    }
    
    // Group lessons by language
    private var lessonsByLanguage: [(language: String, lessons: [Lesson])] {
        let unfiled = filteredLessons
        var grouped: [String: [Lesson]] = [:]
        
        for lesson in unfiled {
            let lang = lesson.targetLanguage ?? "Other"
            grouped[lang, default: []].append(lesson)
        }
        
        return grouped.map { (language: $0.key, lessons: $0.value) }
            .sorted { $0.language < $1.language }
    }
    
    var body: some View {
        NavigationStack {
            Form {
                // Folder Name Section
                Section {
                    HStack(spacing: 8) {
                        TextField("Folder Name", text: $newFolderName)
                        .textInputAutocapitalization(.words)
                            .focused($folderNameFocused)
                            .submitLabel(.done)
                            .onSubmit {
                                folderNameFocused = false
                            }
                        
                    if !newFolderName.isEmpty {
                        Button {
                            newFolderName = ""
                            selectedSuggestion = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    }
                    
                    // Smart Suggestions
                    if let suggestions = cachedSuggestions, !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(selectedSuggestion == nil ? "Suggestions (tap to select one)" : "Selected Category")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            FlowLayout(spacing: 8) {
                                ForEach(suggestions, id: \.self) { suggestion in
                                    Button {
                                        toggleSuggestion(suggestion)
                                    } label: {
                                        Text(suggestion)
                                            .font(.subheadline)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(selectedSuggestion == suggestion ? Color.blue : Color.blue.opacity(0.1))
                                            .foregroundColor(selectedSuggestion == suggestion ? .white : .blue)
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                } header: {
                    Text("Folder Name")
                }
                
                // Quick Stats
                Section {
                    HStack {
                        Label("\(selectedLessonIDs.count) selected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                        Spacer()
                        Button(selectedLessonIDs.isEmpty ? "Select All" : "Deselect All") {
                            if selectedLessonIDs.isEmpty {
                                selectedLessonIDs = Set(filteredLessons.map { $0.id })
                            } else {
                                selectedLessonIDs.removeAll()
                            }
                        }
                        .font(.subheadline)
                    }
                }
                
                // Search Bar
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search lessons...", text: $searchText)
                            .focused($searchFocused)
                            .submitLabel(.done)
                            .onSubmit {
                                searchFocused = false
                            }
                    }
                }
                
                // Lessons Grouped by Language
                ForEach(lessonsByLanguage, id: \.language) { group in
                    Section(group.language) {
                        ForEach(group.lessons) { lesson in
                            Button {
                                toggleLesson(lesson.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedLessonIDs.contains(lesson.id) ? "checkmark.circle.fill" : "circle")
                                        .imageScale(.large)
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(selectedLessonIDs.contains(lesson.id) ? .blue : .secondary)

                                    VStack(alignment: .leading, spacing: 4) {
                                    Text(lesson.title)
                                        .font(.body)
                                            .foregroundStyle(.primary)
                                        
                                        if let target = lesson.targetLanguage, let helper = lesson.translationLanguage {
                                            Text("\(target) → \(helper)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                                    }
                            .buttonStyle(.plain)
                                }
                            }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .toolbar {
                // Navigation bar buttons
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        folderStore.addFolder(named: newFolderName, lessonIDs: Array(selectedLessonIDs))
                        onDismiss()
                    }
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                
                // Unified keyboard toolbar
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        // Dismiss whichever field is focused
                        folderNameFocused = false
                        searchFocused = false
                    }
                }
            }
            .task {
                // Compute suggestions once on first load - task ensures it runs only once
                if cachedSuggestions == nil {
                    cachedSuggestions = computeSuggestions()
                }
            }
        }
    }
    
    private func toggleLesson(_ id: String) {
        if selectedLessonIDs.contains(id) {
            selectedLessonIDs.remove(id)
        } else {
            selectedLessonIDs.insert(id)
        }
    }
    
    private func toggleSuggestion(_ suggestion: String) {
        if selectedSuggestion == suggestion {
            // Deselect if tapping the same one
            selectedSuggestion = nil
            // Clear all selected lessons
            selectedLessonIDs.removeAll()
        } else {
            // Select new suggestion and replace previous selection
            selectedSuggestion = suggestion
            // Clear previous selections and select matching lessons
            selectedLessonIDs.removeAll()
            autoSelectMatchingLessons(for: suggestion)
        }
        
        // Update folder name
        updateFolderName()
    }
    
    private func autoSelectMatchingLessons(for suggestion: String) {
        let keyword = suggestion.lowercased()
        let matching = store.lessons.filter { lesson in
            !folderedLessonIDs.contains(lesson.id) &&
            (lesson.title.lowercased().contains(keyword) ||
             lesson.targetLanguage?.lowercased().contains(keyword) == true)
        }
        for lesson in matching {
            selectedLessonIDs.insert(lesson.id)
        }
    }
    
    private func updateFolderName() {
        if let suggestion = selectedSuggestion {
            newFolderName = suggestion
        } else {
            // Clear if no suggestion selected
            newFolderName = ""
        }
    }
}

// MARK: - Flow Layout for Suggestions

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(
            in: proposal.replacingUnspecifiedDimensions().width,
            subviews: subviews,
            spacing: spacing
        )
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(
            in: bounds.width,
            subviews: subviews,
            spacing: spacing
        )
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                     y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                if currentX + size.width > maxWidth && currentX > 0 {
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }
                
                positions.append(CGPoint(x: currentX, y: currentY))
                lineHeight = max(lineHeight, size.height)
                currentX += size.width + spacing
            }
            
            self.size = CGSize(width: maxWidth, height: currentY + lineHeight)
        }
    }
}

