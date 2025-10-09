# Background Generation Improvements

## Overview
This update makes lesson generation robust against app backgrounding. Generation will now continue seamlessly even when you switch to other apps, as long as you don't force-quit the app.

## What Changed

### 1. New File: `BackgroundSessionDelegate.swift`
- **Purpose**: Handles background URLSession events
- **Location**: `InputMaximizer/Services/BackgroundSessionDelegate.swift`
- **Key Features**:
  - Manages data collection from background network requests
  - Uses async/await with continuations for clean integration
  - Thread-safe with NSLock protection
  - Singleton pattern for app-wide use

### 2. Updated: `ProxyClient.swift`
- **Added Background URLSession**: 
  - New `backgroundSession` with 5-minute resource timeout
  - Configured to continue when app is backgrounded
  - Automatically cancelled if user force-quits
  
- **New Methods**:
  - `chatBackground()`: Background-capable chat requests
  - `ttsBackground()`: Background-capable TTS requests
  
- **Backward Compatible**: Original methods still work for non-generation tasks

### 3. Updated: `GeneratorService.swift`
- **Network Methods Now Use Background Session**:
  - `chatViaProxy()` now uses `chatBackground()`
  - `ttsViaProxy()` now uses `ttsBackground()`
  - Increased timeouts: 90s for chat, 120s for TTS
  
- **Improved Retry Logic**:
  - Smarter error handling distinguishes transient vs. permanent errors
  - Exponential backoff for retries (0.8s, 1.6s, 3.2s)
  - Detailed logging for debugging
  - Won't retry on bad URLs or malformed responses (fails fast)
  - Will retry on network timeouts, connection lost, etc.

## Technical Details

### How Background Sessions Work

1. **Normal Operation (App Active)**:
   - Works exactly like before
   - Network requests complete normally
   
2. **When You Switch Apps**:
   - iOS would normally suspend network requests after ~30 seconds
   - Background URLSession continues working independently
   - Requests can take up to 5 minutes to complete
   - App wakes up when request completes to process data
   
3. **If You Force-Quit**:
   - iOS terminates the background session
   - Generation stops cleanly
   - Credits are managed via job system (cancelled automatically)

### Error Handling Strategy

**Transient Errors (Will Retry)**:
- Network timeout
- Cannot connect to host
- Network connection lost
- Not connected to internet

**Permanent Errors (Won't Retry)**:
- Bad URL
- Bad server response
- 402 (Insufficient credits)

**Server Errors (Will Retry Once)**:
- 500 Internal Server Error
- Other unexpected HTTP errors

## Expected Behavior

### Before This Update
❌ Generation fails if you switch apps for >30 seconds  
❌ Error message: "Network error 0"  
❌ Lost progress and credits  

### After This Update
✅ Generation continues when you switch apps  
✅ Can browse other apps during long generations  
✅ Automatic retry on transient network issues  
✅ Better error messages  
✅ Force-quit still cleanly cancels (as intended)  

## Testing Recommendations

1. **Basic Generation**: 
   - Start a generation
   - Should complete normally
   
2. **Background Test**:
   - Start a generation
   - Switch to Safari or another app
   - Wait 1-2 minutes
   - Return to InputMaximizer
   - Generation should have continued/completed
   
3. **Network Issues**:
   - Start a generation
   - Enable Airplane Mode briefly
   - Disable Airplane Mode
   - Should retry and continue
   
4. **Force Quit**:
   - Start a generation
   - Force quit the app (swipe up in app switcher)
   - Reopen app
   - Generation should be cancelled (expected)

## Configuration Notes

- **Background Session Identifier**: `com.inputmax.generation`
- **Request Timeout**: 60 seconds (inactivity)
- **Resource Timeout**: 300 seconds (5 minutes total)
- **Retry Attempts**: 3 attempts per request
- **Initial Retry Delay**: 1.0 second
- **Retry Factor**: 2.0x (exponential backoff)

## Important Notes

1. **No User Interaction Required**: Works automatically
2. **No Notifications**: Silent background operation
3. **Battery Friendly**: Uses standard iOS background APIs
4. **Cellular Data**: Respects user's cellular data settings
5. **WiFi Assist**: Works with WiFi Assist if enabled

## Troubleshooting

### If generation still fails when backgrounding:

1. **Check iOS Settings**:
   - Settings > General > Background App Refresh > InputMaximizer (should be ON)
   
2. **Check Network**:
   - Ensure stable WiFi or cellular connection
   - Try disabling VPN if active
   
3. **Check Credits**:
   - Low credits can cause 402 errors (won't retry)
   
4. **Force Quit vs. Background**:
   - Backgrounding = switching apps (generation continues)
   - Force quit = swiping up in app switcher (generation stops)

## Developer Notes

### Adding Background URLSession to Xcode Project

The new file `BackgroundSessionDelegate.swift` needs to be added to your Xcode project:

1. In Xcode, right-click on `Services` folder
2. Select "Add Files to InputMaximizer..."
3. Navigate to: `InputMaximizer/Services/BackgroundSessionDelegate.swift`
4. Ensure "Copy items if needed" is checked
5. Ensure your target is selected
6. Click "Add"

Alternatively, Xcode should auto-detect the file on next project reload.

### Future Enhancements

Potential improvements for future versions:

- [ ] Progress persistence (resume after force-quit)
- [ ] Background notification on completion
- [ ] Queue multiple generations
- [ ] Offline queue that processes when network available
- [ ] Background processing entitlement for even longer tasks

## Summary

This update makes generation significantly more robust by leveraging iOS background URLSession capabilities. Users can now freely switch between apps during generation without losing progress. The implementation is backward compatible, requires no user configuration, and gracefully handles both force-quit and normal backgrounding scenarios.

