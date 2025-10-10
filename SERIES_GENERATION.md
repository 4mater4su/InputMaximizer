# Multi-Lesson Series Generation - How It Works

## Overview

The series generation feature creates **continuous narratives** across multiple lessons, not separate versions of the same content. For example, a 1500-word story can be split into 5 connected 300-word lessons that form one coherent narrative.

## How Lessons Stay Connected

### 1. **Outline Mode** (Plan Upfront)

When generating a series with an outline:

- **Part 1**: Generated based on the user's prompt + the full outline
  - LLM receives: "You are generating PART 1 of 5. Here's the outline for all parts..."
  - Focus: Establish characters, setting, and begin the narrative arc
  
- **Parts 2-4**: Generated with outline + summary of previous part
  - LLM receives: "You are generating PART 3 of 5. Outline: [...]. Previous part ended with: [summary]"
  - Focus: Continue the narrative naturally while following the outline
  
- **Part 5**: Final chapter with complete context
  - LLM receives: Full outline + summary of Part 4
  - Focus: Bring the narrative to a satisfying conclusion

### 2. **Continuation Mode** (Extend Existing Lesson)

When continuing a lesson or series:

- LLM receives a detailed summary of the previous lesson including:
  - Key events and developments
  - Character states and relationships
  - Unresolved elements or questions
  - Emotional tone

- Generates the next chapter that:
  - Continues naturally from where the previous lesson ended
  - Maintains character consistency and narrative style
  - Introduces new elements while respecting established context
  - Forms a complete episode with its own arc

## Technical Implementation

### Summary Generation Between Parts

After each part is generated, the system automatically:

1. **Loads the generated lesson text** from segments
2. **Reconstructs the full narrative** (combining all segments)
3. **Sends to LLM** with this prompt:
   ```
   Summarize this text in 2-3 sentences for continuation context. Focus on:
   - Key events and developments
   - Character states and relationships
   - Unresolved elements or questions
   - Emotional tone
   
   Text: [full lesson text]
   ```
4. **Stores the summary** in `SeriesMetadata.lastSummary`
5. **Updates the next queued item** to include this summary in its `seriesContext.previousSummary`

### Dynamic Context Injection

Before processing each part, `GenerationQueue.processNext()` does:

```swift
// Update request with latest summary from series if this is a continuation
if nextItem.partNumber > 1 {
    if let series = seriesStore.getSeries(id: nextItem.seriesId),
       let summary = series.lastSummary {
        // Recreate context with updated summary
        nextItem.request.seriesContext = SeriesContext(
            seriesId: oldContext.seriesId,
            partNumber: oldContext.partNumber,
            totalParts: oldContext.totalParts,
            previousSummary: summary,  // ← Fresh summary from previous part
            outline: oldContext.outline
        )
    }
}
```

This ensures each part has the **latest context** from the previous part.

### LLM Prompt Structure

The system prompt for series generation includes:

```
You are generating PART 2 of 5 in a multi-lesson series.

[IF OUTLINE MODE]
Series Outline:
Part 1: Introduction and setup
Part 2: Rising action
Part 3: Conflict
...

Focus on Part 2. This should be a complete chapter that:
- Stands alone with a clear beginning and end
- Advances the overall narrative according to the outline
- Sets up the next part naturally
- Maintains consistent style, tone, and characters throughout the series

[IF CONTINUATION MODE]
Previous Lesson Summary:
Ana discovered the hidden door in the library. She felt both excited
and nervous as she turned the key...

Generate the next chapter that:
- Continues naturally from where the previous lesson ended
- Maintains character consistency and narrative style
- Introduces new elements while respecting established context
- Forms a complete episode with its own arc
```

## Example: 1500-Word Story Split Into 5 Parts

### User Input
- **Prompt**: "A detective investigates mysterious disappearances in a small coastal town"
- **Series**: 5 parts × 300 words = 1500 words total
- **Optional Outline**:
  1. Detective arrives, interviews locals
  2. Discovers clues pointing to the old lighthouse
  3. Explores the lighthouse, finds hidden passage
  4. Confronts the truth underground
  5. Resolution and aftermath

### What Gets Generated

**Part 1** (300 words):
- Detective Emma arrives in Saltwater Bay
- Meets the worried harbormaster
- Learns about the three missing fishermen
- Notices strange behavior from lighthouse keeper
- **Ends with**: Emma deciding to visit the lighthouse tomorrow

**Generated Summary for Part 2**:
> Detective Emma arrived in Saltwater Bay to investigate three missing fishermen. The harbormaster was worried, and Emma noticed the lighthouse keeper acting strangely. She plans to visit the lighthouse the next day.

**Part 2** (300 words):
- **Starts naturally**: Emma wakes early and drives to the lighthouse
- Keeper is evasive, won't let her inside
- She finds footprints leading to the cliffs
- Discovers a hidden cave entrance
- **Ends with**: Emma entering the cave with her flashlight

**Generated Summary for Part 3**:
> Emma visited the lighthouse but the keeper was evasive. She found footprints leading to a hidden cave entrance on the cliffs and decided to investigate.

**Part 3** (300 words):
- **Continues**: Emma's flashlight reveals ancient stone steps
- Cave system is larger than expected
- Finds modern equipment—someone's been here recently
- Hears voices echoing from below
- **Ends with**: Emma hiding as she hears approaching footsteps

...and so on. Each part:
- ✅ Continues the **same story**
- ✅ Maintains **character consistency** (Emma's personality, skills, goals)
- ✅ Advances the **same plot** (not a retelling)
- ✅ References **previous events** naturally
- ✅ Sets up the **next part** organically

## Credits & Queue Management

- **Pay-as-you-go**: Each part costs 1 credit as it's generated
- **Cancellable**: Stop generation mid-series, only paying for completed parts
- **Resumable**: Use "Continue Story" button to add more parts later
- **Automatic folder**: All parts stored together in one folder
- **Series metadata**: Tracks which parts are complete, stores summaries

## Result

Instead of 3 variations of the same 300-word story, you get:
- 1 coherent 900-1500 word narrative
- Split into digestible 300-word chapters
- Each chapter stands alone but contributes to the whole
- Perfect for extended learning with deeper context and vocabulary

