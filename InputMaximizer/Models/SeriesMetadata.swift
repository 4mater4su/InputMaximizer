//
//  SeriesMetadata.swift
//  InputMaximizer
//
//  Tracks multi-lesson series information
//

import Foundation

/// Metadata for a multi-lesson series
struct SeriesMetadata: Codable, Identifiable {
    let id: String  // seriesId
    let title: String
    let folderId: String  // Associated folder ID
    var lessonIDs: [String]  // Ordered list of lesson IDs in series
    let totalParts: Int
    var completedParts: Int
    let mode: GenerationMode
    let createdAt: Date
    var outline: [String]?  // For outline-based series
    var lastSummary: String?  // Summary of last lesson for continuation
    
    enum GenerationMode: String, Codable {
        case outline
        case continuation
    }
    
    /// Check if series can be continued
    var canContinue: Bool {
        completedParts < totalParts
    }
    
    /// Get the next part number to generate
    var nextPartNumber: Int {
        completedParts + 1
    }
}

/// Storage manager for series metadata
@MainActor
class SeriesMetadataStore: ObservableObject {
    @Published private(set) var series: [SeriesMetadata] = []
    
    private let fileManager = FileManager.default
    private var seriesDirectory: URL {
        FileManager.docsLessonsDir
    }
    
    init() {
        load()
    }
    
    /// Load all series metadata from disk
    func load() {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: seriesDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        
        let seriesFiles = urls.filter { $0.lastPathComponent.hasPrefix("series_") && $0.pathExtension == "json" }
        
        series = seriesFiles.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let meta = try? JSONDecoder().decode(SeriesMetadata.self, from: data) else {
                return nil
            }
            return meta
        }
    }
    
    /// Save a series metadata to disk
    func save(_ meta: SeriesMetadata) {
        let url = seriesDirectory.appendingPathComponent("series_\(meta.id).json")
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: url)
        
        // Update in memory
        if let index = series.firstIndex(where: { $0.id == meta.id }) {
            series[index] = meta
        } else {
            series.append(meta)
        }
    }
    
    /// Get series by ID
    func getSeries(id: String) -> SeriesMetadata? {
        series.first { $0.id == id }
    }
    
    /// Get series for a specific lesson
    func getSeries(forLessonId lessonId: String) -> SeriesMetadata? {
        series.first { $0.lessonIDs.contains(lessonId) }
    }
    
    /// Update series with new lesson
    func addLesson(seriesId: String, lessonId: String) {
        guard var meta = getSeries(id: seriesId) else { return }
        meta.lessonIDs.append(lessonId)
        meta.completedParts = meta.lessonIDs.count
        save(meta)
    }
    
    /// Update last summary for continuation
    func updateSummary(seriesId: String, summary: String) {
        guard var meta = getSeries(id: seriesId) else { return }
        meta.lastSummary = summary
        save(meta)
    }
    
    /// Delete a series metadata
    func delete(seriesId: String) {
        let url = seriesDirectory.appendingPathComponent("series_\(seriesId).json")
        try? fileManager.removeItem(at: url)
        series.removeAll { $0.id == seriesId }
    }
}

