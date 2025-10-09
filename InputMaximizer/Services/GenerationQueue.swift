//
//  GenerationQueue.swift
//  InputMaximizer
//
//  Manages queued multi-lesson generation
//

import SwiftUI

/// Represents a single item in the generation queue
struct QueueItem: Identifiable, Equatable {
    let id: UUID
    let request: GeneratorService.Request
    let seriesId: String
    let partNumber: Int
    let totalParts: Int
    let folderName: String
    var status: Status
    var lessonId: String?
    var error: String?
    
    enum Status: Equatable {
        case pending
        case generating
        case completed
        case failed
    }
    
    static func == (lhs: QueueItem, rhs: QueueItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// Manages a queue of lesson generations for series
@MainActor
final class GenerationQueue: ObservableObject {
    @Published private(set) var queuedItems: [QueueItem] = []
    @Published private(set) var isProcessing: Bool = false
    @Published private(set) var currentItem: QueueItem?
    
    private let generator: GeneratorService
    private let lessonStore: LessonStore
    private let seriesStore: SeriesMetadataStore
    private let folderStore: FolderStore
    
    init(generator: GeneratorService, lessonStore: LessonStore, seriesStore: SeriesMetadataStore, folderStore: FolderStore) {
        self.generator = generator
        self.lessonStore = lessonStore
        self.seriesStore = seriesStore
        self.folderStore = folderStore
    }
    
    /// Enqueue items for generation
    func enqueue(items: [QueueItem]) {
        queuedItems.append(contentsOf: items)
        
        // Start processing if not already
        if !isProcessing {
            Task {
                await processNext()
            }
        }
    }
    
    /// Process the next pending item in queue
    func processNext() async {
        // Find next pending item
        guard let nextItem = queuedItems.first(where: { $0.status == .pending }) else {
            isProcessing = false
            currentItem = nil
            return
        }
        
        isProcessing = true
        currentItem = nextItem
        updateItemStatus(nextItem.id, .generating)
        
        do {
            // Start generation using the existing GeneratorService
            generator.start(nextItem.request, lessonStore: lessonStore)
            
            // Wait for generation to complete
            while generator.isBusy {
                try await Task.sleep(nanoseconds: 500_000_000) // Poll every 0.5s
            }
            
            // Check if generation succeeded
            guard let lessonId = generator.lastLessonID else {
                throw NSError(domain: "GenerationQueue", code: 1, 
                            userInfo: [NSLocalizedDescriptionKey: "Generation failed: no lesson ID"])
            }
            
            // Update item status
            updateItemStatus(nextItem.id, .completed, lessonId: lessonId)
            
            // Update series metadata
            seriesStore.addLesson(seriesId: nextItem.seriesId, lessonId: lessonId)
            
            // Create or update folder
            if let index = folderStore.folders.firstIndex(where: { $0.seriesId == nextItem.seriesId }) {
                // Existing folder - add lesson
                if !folderStore.folders[index].lessonIDs.contains(lessonId) {
                    folderStore.folders[index].lessonIDs.append(lessonId)
                    // Save triggers automatically via didSet in FolderStore
                }
            } else if nextItem.partNumber == 1 {
                // First part - create new folder
                let folder = Folder(
                    id: UUID(),
                    name: nextItem.folderName,
                    lessonIDs: [lessonId],
                    seriesId: nextItem.seriesId,
                    createdAt: Date()
                )
                folderStore.folders.append(folder)
                // Save triggers automatically via didSet in FolderStore
            }
            
            // Generate summary for next part (if not last)
            if nextItem.partNumber < nextItem.totalParts {
                if let lesson = lessonStore.lessons.first(where: { $0.id == lessonId || $0.folderName == lessonId }) {
                    let summary = try await generateSummary(for: lesson)
                    seriesStore.updateSummary(seriesId: nextItem.seriesId, summary: summary)
                }
            }
            
            // Process next item
            await processNext()
            
        } catch {
            updateItemStatus(nextItem.id, .failed, error: error.localizedDescription)
            isProcessing = false
            currentItem = nil
        }
    }
    
    /// Generate a summary of a lesson for continuation context
    private func generateSummary(for lesson: Lesson) async throws -> String {
        // Load lesson text from segments
        let docsBase = FileManager.docsLessonsDir.appendingPathComponent(lesson.folderName, isDirectory: true)
        let segmentsURL = docsBase.appendingPathComponent("segments_\(lesson.folderName).json")
        
        guard let segmentsData = try? Data(contentsOf: segmentsURL),
              let segments = try? JSONDecoder().decode([Segment].self, from: segmentsData) else {
            throw NSError(domain: "GenerationQueue", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to load lesson text"])
        }
        
        // Reconstruct text
        let paragraphGroups = Dictionary(grouping: segments, by: { $0.paragraph })
        let text = paragraphGroups
            .sorted { $0.key < $1.key }
            .map { _, segs in
                segs.sorted { $0.id < $1.id }
                    .map { $0.pt_text }
                    .joined(separator: " ")
            }
            .joined(separator: "\n\n")
        
        // Generate summary using LLM
        let summaryPrompt = """
        Summarize this text in 2-3 sentences for continuation context. Focus on:
        - Key events and developments
        - Character states and relationships
        - Unresolved elements or questions
        - Emotional tone
        
        Text:
        \(text)
        """
        
        return try await generator.chatViaProxySimple(summaryPrompt)
    }
    
    /// Update status of a queue item
    private func updateItemStatus(_ id: UUID, _ status: QueueItem.Status, lessonId: String? = nil, error: String? = nil) {
        guard let index = queuedItems.firstIndex(where: { $0.id == id }) else { return }
        queuedItems[index].status = status
        if let lessonId = lessonId {
            queuedItems[index].lessonId = lessonId
        }
        if let error = error {
            queuedItems[index].error = error
        }
    }
    
    /// Cancel a specific item
    func cancel(itemId: UUID) {
        guard let index = queuedItems.firstIndex(where: { $0.id == itemId }) else { return }
        
        if queuedItems[index].status == .generating {
            // Cancel current generation
            generator.cancel()
        }
        
        queuedItems[index].status = .failed
        queuedItems[index].error = "Cancelled by user"
        
        // If this was current item, stop processing
        if currentItem?.id == itemId {
            isProcessing = false
            currentItem = nil
        }
    }
    
    /// Cancel all items in a series
    func cancelSeries(seriesId: String) {
        let itemsToCancel = queuedItems.filter { $0.seriesId == seriesId && $0.status != .completed }
        
        for item in itemsToCancel {
            cancel(itemId: item.id)
        }
    }
    
    /// Cancel all pending/generating items
    func cancelAll() {
        for item in queuedItems where item.status != .completed {
            cancel(itemId: item.id)
        }
    }
    
    /// Retry a failed item
    func retry(itemId: UUID) {
        guard let index = queuedItems.firstIndex(where: { $0.id == itemId }) else { return }
        queuedItems[index].status = .pending
        queuedItems[index].error = nil
        
        if !isProcessing {
            Task {
                await processNext()
            }
        }
    }
    
    /// Clear completed items
    func clearCompleted() {
        queuedItems.removeAll { $0.status == .completed }
    }
    
    /// Get items for a specific series
    func items(forSeries seriesId: String) -> [QueueItem] {
        queuedItems.filter { $0.seriesId == seriesId }
    }
}

