# Multi-Lesson Series Implementation Status

## Completed ✅

### 1. Core Infrastructure
- ✅ **SeriesMetadata.swift**: Model and storage for series tracking
- ✅ **GeneratorService.Request**: Extended with `SeriesMode` and `SeriesContext`
- ✅ **GenerationQueue.swift**: Complete queue management system
- ✅ **Folder model**: Added `seriesId` and `createdAt` fields
- ✅ **App initialization**: Added `SeriesMetadataStore` and `GenerationQueue` to environment

### 2. Generation Logic
- ✅ **Series-aware prompts**: `generateFromElevatedPrompt` now includes series context
- ✅ **Outline mode**: LLM receives full outline and focuses on specific part
- ✅ **Continuation mode**: LLM receives previous summary for natural continuation
- ✅ **Automatic folder creation**: Queue creates folders for first part, adds to existing for subsequent parts
- ✅ **Summary generation**: Queue generates summaries after each part for next continuation

### 3. UI Components
- ✅ **GenerationQueueView.swift**: Complete queue UI with status, retry, cancel

## Remaining Work 🚧

### 4. Generator View UI (in progress)

**Location**: After ModeCard (line ~795), before Advanced Options (line 802)

**Add this section**:

```swift
// --- Series Generation Card ---
Section {
    AdvancedCard(expanded: $seriesExpanded, title: "Series Generation") {
        Toggle("Enable Multi-Lesson Series", isOn: $enableSeries)
            .padding(.vertical, 8)
        
        if enableSeries {
            Divider()
                .padding(.vertical, 8)
            
            // Part count picker
            HStack {
                Text("Number of Parts")
                Spacer()
                Picker("", selection: $seriesPartCount) {
                    ForEach(2...5, id: \.self) { count in
                        Text("\(count) parts").tag(count)
                    }
                }
                .pickerStyle(.menu)
            }
            
            // Generate all at once toggle
            Toggle("Generate All At Once", isOn: $generateAllNow)
                .padding(.vertical, 4)
            
            if !generateAllNow {
                Text("First part will be generated. Use 'Continue Story' to generate more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            // Optional outline (only for 3+ parts)
            if seriesPartCount >= 3 {
                Divider()
                    .padding(.vertical, 8)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Outline (Optional)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    TextField("One idea per line for each part...", text: $seriesOutline, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                    
                    Text("Provide a brief description for each part to guide the narrative.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
```

**Add state variables** (around line 185):

```swift
// Series generation
@State private var enableSeries = false
@State private var seriesPartCount = 3
@State private var generateAllNow = true
@State private var seriesOutline = ""
@State private var seriesExpanded = false
```

**Inject dependencies** (at top of GeneratorView struct, around line 175):

```swift
@EnvironmentObject private var seriesStore: SeriesMetadataStore
@EnvironmentObject private var generationQueue: GenerationQueue
@EnvironmentObject private var folderStore: FolderStore
```

**Update Generate button logic** (in `performGenerate()` function, around line 950):

```swift
private func performGenerate() {
    guard !gen.isBusy, !generationQueue.isProcessing else { return }
    
    if enableSeries {
        // Multi-lesson generation
        generateSeries()
    } else {
        // Single lesson (existing logic)
        let req = GeneratorService.Request(
            // ... existing fields ...
        )
        gen.start(req, lessonStore: store)
    }
}

private func generateSeries() {
    let seriesId = UUID().uuidString
    let outline = seriesOutline.isEmpty ? nil : seriesOutline
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    
    var items: [QueueItem] = []
    
    for partNum in 1...seriesPartCount {
        let shouldGenerate = generateAllNow || partNum == 1
        guard shouldGenerate else { continue }
        
        var req = GeneratorService.Request(
            mode: mode == .random ? .random : .prompt,
            userPrompt: userPrompt,
            genLanguage: targetLanguage,
            transLanguage: translationLanguage,
            segmentation: segmentation == .sentences ? .sentences : .paragraphs,
            lengthWords: lengthWords,
            speechSpeed: speechSpeed == .regular ? .regular : .slow
        )
        
        req.languageLevel = languageLevel
        req.translationStyle = translationStyle
        req.userChosenTopic = randomTopic
        req.topicPool = interests
        
        // Add series context
        if partNum == 1 {
            req.seriesMode = .multiPartOutline(totalParts: seriesPartCount)
            req.seriesContext = GeneratorService.Request.SeriesContext(
                seriesId: seriesId,
                partNumber: partNum,
                totalParts: seriesPartCount,
                previousSummary: nil,
                outline: outline
            )
        } else {
            // Subsequent parts will get summary from previous part
            req.seriesMode = .continuation(fromLessonId: "placeholder")
            req.seriesContext = GeneratorService.Request.SeriesContext(
                seriesId: seriesId,
                partNumber: partNum,
                totalParts: seriesPartCount,
                previousSummary: nil,  // Will be filled by queue
                outline: outline
            )
        }
        
        let folderName = "\(mode == .random ? (randomTopic ?? "Random") : userPrompt) (Series)"
        
        items.append(QueueItem(
            id: UUID(),
            request: req,
            seriesId: seriesId,
            partNumber: partNum,
            totalParts: seriesPartCount,
            folderName: folderName,
            status: .pending
        ))
    }
    
    // Create series metadata
    let seriesMeta = SeriesMetadata(
        id: seriesId,
        title: items[0].folderName,
        folderId: "",  // Will be set by queue
        lessonIDs: [],
        totalParts: seriesPartCount,
        completedParts: 0,
        mode: outline != nil ? .outline : .continuation,
        createdAt: Date(),
        outline: outline
    )
    seriesStore.save(seriesMeta)
    
    // Enqueue items
    generationQueue.enqueue(items: items)
}
```

**Add Queue UI display** (in main ScrollView, after suggestions or mode card):

```swift
// Show queue if processing
if generationQueue.isProcessing || !generationQueue.queuedItems.isEmpty {
    Section {
        GenerationQueueView(queue: generationQueue, generator: gen)
    }
}
```

### 5. ContentView Continuation UI

**Add to ContentView** (around line 1050, in toolbar):

```swift
// Environment objects
@EnvironmentObject private var seriesStore: SeriesMetadataStore
@EnvironmentObject private var generationQueue: GenerationQueue

// State for continuation
@State private var showContinuationSheet = false
@State private var continuationPartsCount = 1

// In toolbar
if canContinueLesson {
    ToolbarItem(placement: .topBarTrailing) {
        Button {
            showContinuationSheet = true
        } label: {
            Label("Continue Story", systemImage: "plus.rectangle.on.rectangle")
        }
    }
}

// Computed property
private var canContinueLesson: Bool {
    // Check if lesson is part of a series and can be continued
    if let series = seriesStore.getSeries(forLessonId: currentLesson.id) {
        return series.canContinue
    }
    // Or if it's a standalone lesson (always can continue)
    return true
}

// Sheet
.sheet(isPresented: $showContinuationSheet) {
    ContinuationSheet(
        lesson: currentLesson,
        seriesStore: seriesStore,
        generationQueue: generationQueue,
        generator: generator,
        folderStore: folderStore,
        lessonStore: store
    )
    .presentationDetents([.medium, .large])
}
```

**Create ContinuationSheet** (new struct in ContentView.swift):

```swift
private struct ContinuationSheet: View {
    let lesson: Lesson
    let seriesStore: SeriesMetadataStore
    let generationQueue: GenerationQueue
    let generator: GeneratorService
    let folderStore: FolderStore
    let lessonStore: LessonStore
    
    @Environment(\.dismiss) private var dismiss
    @State private var partsCount = 1
    @State private var generateAll = false
    
    private var existingSeries: SeriesMetadata? {
        seriesStore.getSeries(forLessonId: lesson.id)
    }
    
    private var remainingParts: Int? {
        if let series = existingSeries {
            return series.totalParts - series.completedParts
        }
        return nil
    }
    
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Continue Story")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Based on: \(lesson.title)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                
                if let remaining = remainingParts {
                    Text("This lesson is part of a series. \(remaining) part(s) remaining.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                
                // Options
                VStack(spacing: 16) {
                    Picker("Generate", selection: $partsCount) {
                        Text("1 part").tag(1)
                        if (remainingParts ?? 5) >= 2 {
                            Text("2 parts").tag(2)
                        }
                        if (remainingParts ?? 5) >= 3 {
                            Text("3 parts").tag(3)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    if partsCount > 1 {
                        Toggle("Generate all at once", isOn: $generateAll)
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(12)
                .padding(.horizontal)
                
                Spacer()
                
                // Generate button
                Button {
                    generateContinuation()
                    dismiss()
                } label: {
                    Text("Generate")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
    
    private func generateContinuation() {
        // Implementation similar to generateSeries in GeneratorView
        // but uses lesson's language/settings and generates continuation
    }
}
```

## Testing Checklist

### Outline Mode
- [ ] Enable series in GeneratorView (3 parts)
- [ ] Provide outline (3 brief ideas)
- [ ] Generate all at once
- [ ] Verify folder created with series name
- [ ] Verify all 3 lessons generated sequentially
- [ ] Verify narrative coherence across parts
- [ ] Check credits deducted correctly (3 total)

### Continuation Mode (from ContentView)
- [ ] Play a standalone lesson
- [ ] Tap "Continue Story"
- [ ] Generate 1 more part
- [ ] Verify continuation makes sense
- [ ] Generate 2 more parts at once
- [ ] Verify queue processes both

### Queue Management
- [ ] Start multi-part generation
- [ ] Switch to another app mid-generation
- [ ] Return - verify generation continued
- [ ] Cancel one item in queue
- [ ] Retry a failed item
- [ ] Cancel entire series

### Edge Cases
- [ ] Run out of credits mid-series
- [ ] Network failure during generation
- [ ] Force quit app during generation
- [ ] Generate series with only 2 parts
- [ ] Generate series with 5 parts

## File Summary

**New Files Created:**
1. `InputMaximizer/Models/SeriesMetadata.swift` ✅
2. `InputMaximizer/Services/GenerationQueue.swift` ✅
3. `InputMaximizer/Views/GenerationQueueView.swift` ✅

**Modified Files:**
1. `InputMaximizer/Services/GeneratorService.swift` ✅
2. `InputMaximizer/Views/LessonSelectionView.swift` (Folder model) ✅
3. `InputMaximizer/App/input_maximizerApp.swift` ✅
4. `InputMaximizer/Views/GeneratorView.swift` (needs UI additions)
5. `InputMaximizer/Views/ContentView.swift` (needs continuation UI)

## Next Steps

1. Add series configuration UI to GeneratorView (code provided above)
2. Add continuation button and sheet to ContentView (code provided above)
3. Build and fix any compilation errors
4. Test all scenarios from checklist
5. Refine UX based on testing

