//
//  GenerationQueueView.swift
//  InputMaximizer
//
//  UI for displaying and managing the generation queue
//

import SwiftUI

struct GenerationQueueView: View {
    @ObservedObject var queue: GenerationQueue
    @ObservedObject var generator: GeneratorService
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "books.vertical.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Series Generation")
                        .font(.headline)
                    if let current = queue.currentItem {
                        Text("Part \(current.partNumber) of \(current.totalParts)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                Button("Cancel All") {
                    queue.cancelAll()
                }
                .font(.caption)
                .foregroundStyle(.red)
            }
            
            // Queue items
            ForEach(queue.queuedItems) { item in
                QueueItemRow(item: item, queue: queue)
            }
            
            // Current generation status
            if queue.isProcessing, !generator.status.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(generator.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.blue.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.blue.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

private struct QueueItemRow: View {
    let item: QueueItem
    let queue: GenerationQueue
    
    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            statusIcon
                .font(.title3)
                .frame(width: 24)
            
            // Part info
            VStack(alignment: .leading, spacing: 2) {
                Text("Part \(item.partNumber)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                if let error = item.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if item.status == .completed, let lessonId = item.lessonId {
                    Text("✓ Completed")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            
            Spacer()
            
            // Actions
            if item.status == .failed {
                Button("Retry") {
                    queue.retry(itemId: item.id)
                }
                .font(.caption)
                .buttonStyle(.bordered)
            } else if item.status == .pending {
                Button("Cancel") {
                    queue.cancel(itemId: item.id)
                }
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(statusColor.opacity(0.1))
        )
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .generating:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
    
    private var statusColor: Color {
        switch item.status {
        case .pending: return .secondary
        case .generating: return .blue
        case .completed: return .green
        case .failed: return .red
        }
    }
}

#Preview {
    let generator = GeneratorService()
    let lessonStore = LessonStore()
    let seriesStore = SeriesMetadataStore()
    let folderStore = FolderStore()
    let queue = GenerationQueue(
        generator: generator,
        lessonStore: lessonStore,
        seriesStore: seriesStore,
        folderStore: folderStore
    )
    
    // Add some mock items using enqueue (which is the proper public API)
    let mockRequest = GeneratorService.Request(
        mode: .prompt,
        userPrompt: "Test",
        genLanguage: "English",
        transLanguage: "Spanish",
        segmentation: .sentences,
        lengthWords: 300
    )
    
    let mockItems = [
        QueueItem(id: UUID(), request: mockRequest, seriesId: "test", partNumber: 1, totalParts: 3, folderName: "Test Series", status: .completed, lessonId: "lesson1"),
        QueueItem(id: UUID(), request: mockRequest, seriesId: "test", partNumber: 2, totalParts: 3, folderName: "Test Series", status: .generating),
        QueueItem(id: UUID(), request: mockRequest, seriesId: "test", partNumber: 3, totalParts: 3, folderName: "Test Series", status: .pending)
    ]
    
    queue.enqueue(items: mockItems)
    
    return GenerationQueueView(queue: queue, generator: generator)
        .padding()
}

