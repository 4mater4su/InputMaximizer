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
    var request: GeneratorService.Request
    let seriesId: String
    let partNumber: Int
    let totalParts: Int
    let folderName: String
    var status: Status
    var lessonId: String?
    var errorMessage: String?
    
    enum Status: String, Codable, Equatable {
        case pending
        case generating
        case completed
        case failed
        case cancelled
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
    
    /// NEW: Generate complete series iteratively (all at once)
    func processSeriesIteratively(items: [QueueItem]) async {
        guard let firstItem = items.first else { return }
        
        await MainActor.run {
            isProcessing = true
        }
        
        do {
            // Start job for the entire series
            let jobResponse = try await GeneratorService.proxy.jobStart(
                deviceId: DeviceID.current,
                amount: firstItem.totalParts
            )
            
            let totalWordCount = firstItem.request.lengthWords * firstItem.totalParts
            
            // Mark all items as generating
            for item in items {
                await updateItemStatus(item.id, .generating)
            }
            
            // 1. Generate complete story iteratively
            let completeStory = try await GeneratorService.generateSeriesIteratively(
                elevated: firstItem.request.userPrompt,
                targetLang: firstItem.request.genLanguage,
                totalWordCount: totalWordCount,
                partCount: firstItem.totalParts,
                jobId: jobResponse.jobId,
                jobToken: jobResponse.jobToken,
                progress: { status in
                    await MainActor.run {
                        self.generator.status = status
                    }
                }
            )
            
            // 2. Translate complete story (paragraph by paragraph to avoid context length issues)
            let translatedStory = try await GeneratorService.translateStoryParagraphByParagraph(
                completeStory,
                to: firstItem.request.transLanguage,
                style: firstItem.request.translationStyle,
                jobId: jobResponse.jobId,
                jobToken: jobResponse.jobToken,
                progress: { status in
                    await MainActor.run {
                        self.generator.status = status
                    }
                }
            )
            
            // 3. Split both stories into parts
            let originalParts = GeneratorService.splitStoryIntoParts(completeStory, partCount: firstItem.totalParts)
            let translatedParts = GeneratorService.splitStoryIntoParts(translatedStory, partCount: firstItem.totalParts)
            
            guard originalParts.count == translatedParts.count else {
                throw NSError(domain: "GenerationQueue", code: 5,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to split story into parts"])
            }
            
            // Create or get series folder
            var seriesFolderId: String?
            await MainActor.run {
                if let existingFolder = folderStore.folders.first(where: { $0.seriesId == firstItem.seriesId }) {
                    seriesFolderId = existingFolder.id.uuidString
                }
            }
            
            // 4. Process each part: segment, generate TTS, save
            for (index, item) in items.enumerated() {
                guard index < originalParts.count && index < translatedParts.count else { break }
                
                await updateItemStatus(item.id, .generating)
                await MainActor.run {
                    generator.status = "Processing part \(index + 1)/\(items.count): Segmentation..."
                }
                
                let originalText = originalParts[index]
                let translatedText = translatedParts[index]
                
                // Extract title from first paragraph or generate from prompt
                let title = if index == 0 {
                    "Part 1: \(firstItem.request.userPrompt.prefix(30))..."
                } else {
                    "Part \(index + 1)"
                }
                
                // Segment the part
                let segments = try await segmentPart(
                    originalText: originalText,
                    translatedText: translatedText,
                    segmentation: firstItem.request.segmentation,
                    jobId: jobResponse.jobId,
                    jobToken: jobResponse.jobToken
                )
                
                // Generate TTS for all segments
                await MainActor.run {
                    generator.status = "Processing part \(index + 1)/\(items.count): Generating audio..."
                }
                
                let audioFiles = try await generateAudioForSegments(
                    segments: segments,
                    targetLang: firstItem.request.genLanguage,
                    transLang: firstItem.request.transLanguage,
                    speechSpeed: firstItem.request.speechSpeed,
                    jobId: jobResponse.jobId,
                    jobToken: jobResponse.jobToken
                )
                
                // Save lesson
                let lessonId = try await saveLesson(
                    title: title,
                    segments: segments,
                    audioFiles: audioFiles,
                    targetLang: firstItem.request.genLanguage,
                    transLang: firstItem.request.transLanguage,
                    partNumber: index + 1,
                    totalParts: items.count
                )
                
                // Update item status
                await updateItemStatus(item.id, .completed, lessonId: lessonId)
                
                // Add to folder (create if first part)
                await MainActor.run {
                    if let folderId = seriesFolderId,
                       let folderIndex = folderStore.folders.firstIndex(where: { $0.id.uuidString == folderId }) {
                        // Add to existing folder
                        if !folderStore.folders[folderIndex].lessonIDs.contains(lessonId) {
                            folderStore.folders[folderIndex].lessonIDs.append(lessonId)
                        }
                    } else if index == 0 {
                        // Create new folder for series
                        let folder = Folder(
                            id: UUID(),
                            name: item.folderName,
                            lessonIDs: [lessonId],
                            seriesId: firstItem.seriesId,
                            createdAt: Date()
                        )
                        folderStore.folders.append(folder)
                        seriesFolderId = folder.id.uuidString
                    }
                    
                    // Update series metadata
                    seriesStore.addLesson(seriesId: firstItem.seriesId, lessonId: lessonId)
                }
            }
            
            // Commit job (deduct credits)
            try await GeneratorService.proxy.jobCommit(
                deviceId: DeviceID.current,
                jobId: jobResponse.jobId
            )
            
            await MainActor.run {
                isProcessing = false
                currentItem = nil
            }
            
        } catch {
            // Cancel job on error (refund credits)
            // Note: job will auto-cancel if not committed
            
            for item in items {
                await updateItemStatus(item.id, .failed, error: error.localizedDescription)
            }
            await MainActor.run {
                isProcessing = false
                currentItem = nil
            }
        }
    }
    
    /// Segment a story part into sentences/paragraphs
    private func segmentPart(
        originalText: String,
        translatedText: String,
        segmentation: GeneratorService.Request.Segmentation,
        jobId: String,
        jobToken: String
    ) async throws -> [SegmentData] {
        // Split by paragraphs
        let originalParagraphs = originalText.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        let translatedParagraphs = translatedText.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        guard originalParagraphs.count == translatedParagraphs.count else {
            throw NSError(domain: "GenerationQueue", code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "Paragraph count mismatch"])
        }
        
        var segments: [SegmentData] = []
        var segmentId = 0
        
        for (paragraphIndex, (originalPara, translatedPara)) in zip(originalParagraphs, translatedParagraphs).enumerated() {
            // Split into sentences if needed
            if segmentation == .sentences {
                let originalSentences = splitIntoSentences(originalPara)
                let translatedSentences = splitIntoSentences(translatedPara)
                
                // Match sentences (may not be 1:1, use best effort)
                for (sentIndex, (origSent, transSent)) in zip(originalSentences, translatedSentences).enumerated() {
                    segments.append(SegmentData(
                        id: segmentId,
                        originalText: origSent,
                        translatedText: transSent,
                        paragraph: paragraphIndex
                    ))
                    segmentId += 1
                }
            } else {
                // Paragraph mode
                segments.append(SegmentData(
                    id: segmentId,
                    originalText: originalPara,
                    translatedText: translatedPara,
                    paragraph: paragraphIndex
                ))
                segmentId += 1
            }
        }
        
        return segments
    }
    
    /// Simple sentence splitter
    private func splitIntoSentences(_ text: String) -> [String] {
        // Split on sentence-ending punctuation followed by space
        let pattern = #"[.!?]+\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [text]
        }
        
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        
        var sentences: [String] = []
        var lastEnd = 0
        
        for match in matches {
            let sentenceRange = NSRange(location: lastEnd, length: match.range.location - lastEnd)
            if let range = Range(sentenceRange, in: text) {
                let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    sentences.append(sentence)
                }
            }
            lastEnd = match.range.location + match.range.length
        }
        
        // Add remaining text
        if lastEnd < nsText.length {
            let remainingRange = NSRange(location: lastEnd, length: nsText.length - lastEnd)
            if let range = Range(remainingRange, in: text) {
                let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    sentences.append(sentence)
                }
            }
        }
        
        return sentences.isEmpty ? [text] : sentences
    }
    
    /// Generate TTS audio for all segments
    private func generateAudioForSegments(
        segments: [SegmentData],
        targetLang: String,
        transLang: String,
        speechSpeed: GeneratorService.Request.SpeechSpeed,
        jobId: String,
        jobToken: String
    ) async throws -> [(Data, Data)] { // Returns [(targetAudioData, transAudioData)]
        var audioFiles: [(Data, Data)] = []
        
        for (index, segment) in segments.enumerated() {
            await MainActor.run {
                generator.status = "Generating audio \(index + 1)/\(segments.count)..."
            }
            
            // Generate target language audio
            let targetAudio = try await ProxyClient(baseURL: URL(string: "https://inputmax-proxy.robing43.workers.dev")!)
                .ttsBackground(
                    deviceId: DeviceID.current,
                    jobId: jobId,
                    jobToken: jobToken,
                    text: segment.originalText,
                    language: targetLang,
                    speed: speechSpeed.rawValue
                )
            
            // Generate translation language audio
            let transAudio = try await ProxyClient(baseURL: URL(string: "https://inputmax-proxy.robing43.workers.dev")!)
                .ttsBackground(
                    deviceId: DeviceID.current,
                    jobId: jobId,
                    jobToken: jobToken,
                    text: segment.translatedText,
                    language: transLang,
                    speed: speechSpeed.rawValue
                )
            
            // Audio data will be saved by caller
            audioFiles.append((targetAudio, transAudio))
        }
        
        return audioFiles
    }
    
    /// Save lesson to disk
    private func saveLesson(
        title: String,
        segments: [SegmentData],
        audioFiles: [(Data, Data)],
        targetLang: String,
        transLang: String,
        partNumber: Int,
        totalParts: Int
    ) async throws -> String {
        let lessonId = UUID().uuidString
        let folderName = lessonId
        
        // Create lesson directory
        let lessonDir = FileManager.docsLessonsDir.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: lessonDir, withIntermediateDirectories: true)
        
        // Save audio files
        var segmentsToSave: [Segment] = []
        for (index, segment) in segments.enumerated() {
            let targetFile = "target_\(index).mp3"
            let transFile = "trans_\(index).mp3"
            
            // Save audio data
            let targetURL = lessonDir.appendingPathComponent(targetFile)
            let transURL = lessonDir.appendingPathComponent(transFile)
            try audioFiles[index].0.write(to: targetURL)
            try audioFiles[index].1.write(to: transURL)
            
            segmentsToSave.append(Segment(
                id: segment.id,
                pt_text: segment.originalText,
                en_text: segment.translatedText,
                pt_file: targetFile,
                en_file: transFile,
                paragraph: segment.paragraph
            ))
        }
        
        // Save segments JSON
        let segmentsData = try JSONEncoder().encode(segmentsToSave)
        let segmentsURL = lessonDir.appendingPathComponent("segments_\(folderName).json")
        try segmentsData.write(to: segmentsURL)
        
        // Create and save lesson
        await MainActor.run {
            let lesson = Lesson(
                id: lessonId,
                title: title,
                folderName: folderName,
                targetLanguage: targetLang,
                translationLanguage: transLang
            )
            lessonStore.lessons.append(lesson)
            // Note: LessonStore uses @Published array which auto-persists via didSet
        }
        
        return lessonId
    }
    
    /// Helper struct for segment data during processing
    private struct SegmentData {
        let id: Int
        let originalText: String
        let translatedText: String
        let paragraph: Int
    }
    
    /// Process the next pending item in queue
    func processNext() async {
        // Find next pending item
        guard var nextItem = queuedItems.first(where: { $0.status == .pending }) else {
            isProcessing = false
            currentItem = nil
            return
        }
        
        // Update request with latest summary from series if this is a continuation
        if nextItem.partNumber > 1 {
            if let series = seriesStore.getSeries(id: nextItem.seriesId),
               let summary = series.lastSummary,
               let oldContext = nextItem.request.seriesContext {
                // Create new context with updated summary
                nextItem.request.seriesContext = GeneratorService.Request.SeriesContext(
                    seriesId: oldContext.seriesId,
                    partNumber: oldContext.partNumber,
                    totalParts: oldContext.totalParts,
                    previousSummary: summary,
                    outline: oldContext.outline
                )
            }
        }
        
        await MainActor.run {
            isProcessing = true
            currentItem = nextItem
        }
        await updateItemStatus(nextItem.id, .generating)
        
        do {
            // Start generation using the existing GeneratorService
            await MainActor.run {
                generator.start(nextItem.request, lessonStore: lessonStore)
            }
            
            // Wait for generation to complete
            while await MainActor.run(body: { generator.isBusy }) {
                try await Task.sleep(nanoseconds: 500_000_000) // Poll every 0.5s
            }
            
            // Check if generation succeeded
            guard let lessonId = await MainActor.run(body: { generator.lastLessonID }) else {
                throw NSError(domain: "GenerationQueue", code: 1, 
                            userInfo: [NSLocalizedDescriptionKey: "Generation failed: no lesson ID"])
            }
            
            // Update item status
            await updateItemStatus(nextItem.id, .completed, lessonId: lessonId)
            
            // Update series metadata
            await MainActor.run {
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
            }
            
            // Generate summary for next part (if not last)
            if nextItem.partNumber < nextItem.totalParts {
                let lesson = await MainActor.run {
                    lessonStore.lessons.first(where: { $0.id == lessonId || $0.folderName == lessonId })
                }
                if let lesson = lesson {
                    let summary = try await generateSummary(for: lesson)
                    await MainActor.run {
                        seriesStore.updateSummary(seriesId: nextItem.seriesId, summary: summary)
                    }
                }
            }
            
            // Process next item
            await processNext()
            
        } catch {
            await updateItemStatus(nextItem.id, .failed, error: error.localizedDescription)
            await MainActor.run {
                isProcessing = false
                currentItem = nil
            }
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
    @MainActor
    private func updateItemStatus(_ id: UUID, _ status: QueueItem.Status, lessonId: String? = nil, error: String? = nil) {
        guard let index = queuedItems.firstIndex(where: { $0.id == id }) else { return }
        queuedItems[index].status = status
        if let lessonId = lessonId {
            queuedItems[index].lessonId = lessonId
        }
        if let error = error {
            queuedItems[index].errorMessage = error
        }
        // Force UI update
        objectWillChange.send()
    }
    
    /// Cancel a specific item
    func cancel(itemId: UUID) {
        guard let index = queuedItems.firstIndex(where: { $0.id == itemId }) else { return }
        
        if queuedItems[index].status == .generating {
            // Cancel current generation
            generator.cancel()
        }
        
        queuedItems[index].status = .cancelled
        queuedItems[index].errorMessage = "Cancelled by user"
        
        // If this was current item, stop processing
        if currentItem?.id == itemId {
            isProcessing = false
            currentItem = nil
        }
        
        // Force UI update
        objectWillChange.send()
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
        queuedItems[index].errorMessage = nil
        
        if !isProcessing {
            Task {
                await processNext()
            }
        }
        
        // Force UI update
        objectWillChange.send()
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

