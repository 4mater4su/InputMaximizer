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
            // First run or decode error → start empty
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

    func addFolder(named name: String, lessonIDs: [String]) {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return }
        var unique = base
        var n = 2
        while folders.contains(where: { $0.name == unique }) {
            unique = "\(base) \(n)"
            n += 1
        }
        folders.append(Folder(name: unique, lessonIDs: lessonIDs))
    }

    func remove(_ folder: Folder) {
        folders.removeAll { $0.id == folder.id }
    }
}

// MARK: - Folder Detail (NEW)
struct FolderDetailView: View {
    @EnvironmentObject private var audioManager: AudioManager
    let folder: Folder
    let lessons: [Lesson]

    var lessonsInFolder: [Lesson] {
        lessons.filter { folder.lessonIDs.contains($0.id) }
    }

    @State private var selectedLesson: Lesson?

    var body: some View {
        List {
            if lessonsInFolder.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder", description: Text("Add lessons to this folder from the creator sheet."))
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
            }
        }
        .navigationTitle(folder.name)
        // Programmatic navigation using NavigationStack
        .navigationDestination(item: $selectedLesson) { lesson in
            ContentView(selectedLesson: lesson, lessons: lessons)
                .environmentObject(audioManager)
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
                            Text("No unfiled lessons.Everything is already in folders.")
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
            .navigationDestination(for: Folder.self) { folder in
                FolderDetailView(folder: folder, lessons: store.lessons)
                    .environmentObject(audioManager)
            }
            // Programmatic lesson navigation
            .navigationDestination(item: $selectedLesson) { lesson in
                ContentView(selectedLesson: lesson, lessons: store.lessons)
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
                    List(store.lessons, id: \._id, selection: $selectedLessonIDs) { lesson in
                        HStack {
                            Image(systemName: selectedLessonIDs.contains(lesson.id) ? "checkmark.circle.fill" : "circle")
                            Text(lesson.title)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedLessonIDs.contains(lesson.id) {
                                selectedLessonIDs.remove(lesson.id)
                            } else {
                                selectedLessonIDs.insert(lesson.id)
                            }
                        }
                    }
                    .frame(minHeight: 240)
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

// MARK: - Helpers
private extension Lesson { var _id: String { id } }

private extension Color {
    static let uiFolder = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor.systemYellow.withAlphaComponent(0.18) : UIColor.systemYellow.withAlphaComponent(0.22)
    })
}
