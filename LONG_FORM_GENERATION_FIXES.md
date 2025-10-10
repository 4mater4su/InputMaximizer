# Long-Form Generation Bug Fixes

## Issues Fixed

### 1. **Lessons and Folder Not Appearing**
**Problem**: Generated lessons and folder weren't showing up in LessonSelectionView.

**Root Cause**: 
- Manual JSON file manipulation instead of using `LessonStore` and `FolderStore`
- No `@Published` property triggers to update UI
- Stores weren't being reloaded after generation

**Solution**:
- Modified `runLongFormGeneration` to accept `LessonStore` and `FolderStore` parameters
- Changed lesson creation to use `lessonStore.lessons.append()` instead of direct JSON writes
- Changed folder creation to use `folderStore.folders.append()` instead of direct JSON writes
- Added `lessonStore.load()` and `folderStore?.load()` after generation completes
- Both stores use `@Published` properties with `didSet { save() }`, so changes are automatically persisted and UI updates

### 2. **Navigation to Generated Content**
**Problem**: No way to navigate to the generated series folder after completion.

**Solution**:
- Return folder ID with `"folder:"` prefix from `runLongFormGeneration`
- Store this in `generator.lastLessonID`
- Added `navTargetFolder` state variable in `GeneratorView`
- Updated status section to detect folder IDs and show "Series ready — tap to open"
- Added `.navigationDestination(item: $navTargetFolder)` to navigate to `FolderDetailView`
- Button navigates user directly to the folder containing all generated lessons

## Modified Files

### `GeneratorService.swift`
1. Added `folderStore` parameter to `start()` method
2. Added `lessonStore` and `folderStore` parameters to `runGeneration()`
3. Added `lessonStore` and `folderStore` parameters to `runLongFormGeneration()`
4. Changed lesson creation to use `lessonStore.lessons.append()` on MainActor
5. Changed folder creation to use `folderStore.folders.append()` on MainActor
6. Return `"folder:\(folderID)"` instead of first lesson ID
7. Call `folderStore?.load()` after generation completes in `start()`

### `GeneratorView.swift`
1. Added `@EnvironmentObject private var folderStore: FolderStore`
2. Added `@State private var navTargetFolder: Folder?` for navigation
3. Pass `folderStore` to `generator.start()`
4. Updated status section to handle folder IDs with `hasPrefix("folder:")`
5. Show "Series ready — tap to open" for folder navigation
6. Added `.navigationDestination(item: $navTargetFolder)` for folder navigation

## How It Works Now

1. User enables "Long-form series" toggle in GeneratorView
2. Sets total words (e.g., 1200 words → ~4 lessons)
3. Presses "Generate Lesson"
4. Generator creates all lessons and adds them to `LessonStore`
5. Generator creates a folder and adds it to `FolderStore`
6. Both stores auto-save via `@Published` didSet
7. UI automatically refreshes to show new content
8. "Series ready — tap to open" button appears
9. Tapping button navigates directly to the folder containing all lessons

## Testing Checklist

- [x] Lessons appear in LessonSelectionView after generation
- [x] Folder appears in LessonSelectionView after generation
- [x] Folder contains all generated lessons
- [x] "Series ready" button appears after completion
- [x] Tapping button navigates to folder
- [x] All lessons are playable
- [x] Credits are deducted correctly (1 per lesson)

