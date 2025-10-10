# Iterative Series Generation - New Approach

## Overview

This is a **completely different approach** to multi-lesson series generation, inspired by your Python script. Instead of generating isolated lessons and trying to connect them, we:

1. **Generate one complete long story** iteratively
2. **Translate it once** as a whole
3. **Split it into equal parts**
4. **Segment each part** separately

This ensures **perfect narrative continuity** because it's literally the same story, just divided.

## Key Differences from Old Approach

### Old Approach (Problems):
- Generate Part 1 (300 words)
- Summarize Part 1
- Generate Part 2 based on summary (300 words)
- ❌ Each part feels isolated
- ❌ Summary loses details
- ❌ LLM might drift from original style/tone

### New Approach (Better):
- Generate foundation story (300 words)
- Extend iteratively 3x (add ~300 words each time)
- Finalize with conclusion
- Result: One coherent 1500-word story
- Split into 5×300 word lessons
- ✅ Perfect continuity (same story!)
- ✅ No information loss
- ✅ Consistent style throughout

## Implementation

### 1. Core Methods in GeneratorService

```swift
// Generate complete story iteratively
func generateSeriesIteratively(
    elevated: String,           // User prompt
    targetLang: String,          // Target language
    totalWordCount: Int,         // e.g., 1500 for 5×300
    partCount: Int,              // e.g., 5 parts
    jobId: String,
    jobToken: String
) async throws -> String
```

**Process:**
1. Generate initial story (~wordsPerPart)
2. Loop: Extend story (partCount-1 times)
3. Finalize with conclusion
4. Return complete story

```swift
// Extend story without ending
private func extendStory(
    _ currentStory: String,
    targetLang: String,
    metadata: String,
    jobId: String,
    jobToken: String
) async throws -> String
```

**Prompt:**
```
Continue the story without repeating earlier sentences.
Do not end the story yet. Avoid ellipses.
Keep it open-ended for future extensions.

Current story:
[full text so far]
```

```swift
// Add conclusion
private func finalizeStory(
    _ story: String,
    targetLang: String,
    metadata: String,
    jobId: String,
    jobToken: String
) async throws -> String
```

**Prompt:**
```
Here is a story that needs a conclusive ending.
Provide a final passage to gracefully conclude.
Avoid repeating earlier lines.

Story:
[complete story]
```

```swift
// Split by paragraphs
func splitStoryIntoParts(
    _ completeStory: String,
    partCount: Int
) -> [String]
```

**Logic:**
- Split by "\n\n" (paragraphs)
- Divide into equal parts
- Last part gets any remainder

### 2. Helper Methods

```swift
private func cleanupExtension(
    _ extension: String,
    previousStory: String
) -> String
```

- Remove ellipses ("..." and "…")
- Remove repetition of last line

```swift
private func wordCount(of text: String) -> Int
```

- Count non-empty words

### 3. Integration with GenerationQueue

```swift
func processSeriesIteratively(items: [QueueItem]) async
```

**Workflow:**
1. Mark all items as "generating"
2. Call `generateSeriesIteratively()` with total word count
3. Split complete story into parts
4. Translate complete story once (TODO)
5. For each part:
   - Extract the part text
   - Segment into sentences
   - Generate TTS audio
   - Save as lesson
6. Mark each item as "completed"
7. Add to folder

## Example Flow

### User Request:
- **Prompt**: "Detective investigates mysterious disappearances"
- **Parts**: 5
- **Words per part**: 300
- **Total**: 1500 words

### What Happens:

**Step 1: Foundation** (300 words)
```
Detective Emma arrived in Saltwater Bay to investigate...
[complete opening with setup]
```

**Step 2: Extension 1** (adds ~300 words)
```
LLM receives: [foundation] + "continue without ending"
Adds: Emma explores the lighthouse, finds clues...
Total: ~600 words
```

**Step 3: Extension 2** (adds ~300 words)
```
LLM receives: [600 words so far] + "continue without ending"
Adds: Discovery of hidden cave system...
Total: ~900 words
```

**Step 4: Extension 3** (adds ~300 words)
```
LLM receives: [900 words so far] + "continue without ending"
Adds: Confrontation with truth...
Total: ~1200 words
```

**Step 5: Finalization** (adds ~300 words)
```
LLM receives: [1200 words] + "provide conclusion"
Adds: Resolution and aftermath...
Total: ~1500 words
```

**Step 6: Split**
```
Part 1: Paragraphs 1-3 (arrival, setup)
Part 2: Paragraphs 4-6 (lighthouse exploration)
Part 3: Paragraphs 7-9 (cave discovery)
Part 4: Paragraphs 10-12 (confrontation)
Part 5: Paragraphs 13-15 (resolution)
```

**Step 7: Process Each Part**
```
For each part:
  - Translate (or use complete translation)
  - Segment into sentences
  - Generate TTS
  - Save as separate lesson
```

## Benefits

1. **Perfect Continuity**: It's literally the same story, just split
2. **No Information Loss**: No summaries needed between parts
3. **Consistent Style**: Same generation session = same tone/style
4. **Efficient Credits**: No overhead of part-by-part generation
5. **Flexible Splitting**: Can split at natural paragraph boundaries

## Remaining Implementation

### TODO:
1. **Complete Story Translation**: Translate entire story once before splitting
2. **Part Segmentation**: Segment each split part into sentences
3. **TTS Generation**: Generate audio for each segmented part
4. **Job System Integration**: Properly use job tokens for credit management
5. **Error Handling**: Handle failures mid-generation
6. **Progress Updates**: Show "Extending story (2/5)" in UI
7. **Quality Checks**: Ensure parts are roughly equal length

### Files Modified:
- ✅ `GeneratorService.swift` - Added iterative methods
- ✅ `GenerationQueue.swift` - Added `processSeriesIteratively`
- ⏳ Need to complete translation/segmentation integration
- ⏳ Need to update UI to trigger new workflow

## Python Script Comparison

Your Python script does exactly this:
```python
extend_story(initial, max_iterations, max_word_count)  # Iterative extension
finalize_story(story, metadata)                        # Add conclusion
pause_inserter(complete_story)                         # Segment with pauses
```

Our Swift implementation mirrors this:
```swift
generateSeriesIteratively(...)  // Same as extend_story
finalizeStory(...)              // Same as finalize_story
segmentText(...)                // Same as pause_inserter
```

## Next Steps

The foundation is in place. Now we need to:
1. Complete the translation integration
2. Implement per-part segmentation
3. Update `GeneratorView` to use new workflow
4. Test with real generation

This approach will produce **far better multi-lesson series** than the old summary-based approach! 🎉

