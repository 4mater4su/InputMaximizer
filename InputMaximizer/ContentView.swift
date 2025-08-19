import SwiftUI
import AVFoundation
import MediaPlayer

// MARK: - Segment Model
struct Segment: Codable, Identifiable {
    let id: Int
    let pt_text: String
    let en_text: String
    let pt_file: String
    let en_file: String
}

// MARK: - Lesson Model & Loader
struct Lesson: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let folderName: String
}

final class LessonStore: ObservableObject {
    @Published var lessons: [Lesson] = []
    init() { load() }

    func load() {
        // Try subdirectory first (nice to have), then anywhere
        if let url = Bundle.main.url(forResource: "lessons", withExtension: "json", subdirectory: "Lessons")
            ?? (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
                .first(where: { $0.lastPathComponent == "lessons.json" }) {

            do {
                let data = try Data(contentsOf: url)
                lessons = try JSONDecoder().decode([Lesson].self, from: data)
            } catch {
                print("Failed to decode lessons.json: \(error)")
                lessons = []
            }
        } else {
            print("lessons.json not found in app bundle.")
            lessons = []
        }
    }
}



// MARK: - Audio Manager
class AudioManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var segments: [Segment] = []
    @Published var currentIndex: Int = 0
    @Published var isPlayingPT: Bool = false
    @Published var isPaused: Bool = false
    
    private var audioPlayer: AVAudioPlayer?
    private var resumePTAfterENG = false

    @Published var segmentDelay: TimeInterval = UserDefaults.standard.double(forKey: "segmentDelay") == 0 ? 1.2 : UserDefaults.standard.double(forKey: "segmentDelay") {
        didSet {
            if segmentDelay < 0 { segmentDelay = 0 }
            UserDefaults.standard.set(segmentDelay, forKey: "segmentDelay")
        }
    }
    @Published var isInDelay: Bool = false

    private var pendingAdvance: DispatchWorkItem?

    @Published var didFinishLesson: Bool = false              // finished + reset to start
    var requestNextLesson: (() -> Void)?                      // UI provides this closure
    
    // Track current lesson location
    private var currentLessonBaseURL: URL?
    @Published var currentLessonTitle: String = ""

    override init() {
        super.init()
        // Set up audio session for background playback
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            print("Failed to set audio session: \(error)")
        }
        setupRemoteControls()
    }
    
    deinit {
        // ensure cleanup if this ever gets deallocated
        stop()
        removeRemoteControlTargets()
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
    }
    
    private func scheduleAdvanceAfterDelay() {
        pendingAdvance?.cancel()

        // If we're at the last segment, end lesson and reset to start
        guard currentIndex < segments.count - 1 else {
            isPlayingPT = false
            isPaused = false
            isInDelay = false
            didFinishLesson = true          // <-- mark lesson finished
            currentIndex = 0                // <-- back to start
            updateNowPlayingInfo()
            return
        }

        isInDelay = true
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.isInDelay = false
            self.currentIndex += 1
            self.playPortuguese(from: self.currentIndex)
        }
        pendingAdvance = work
        DispatchQueue.main.asyncAfter(deadline: .now() + segmentDelay, execute: work)
    }
    
    // Helper: find a resource anywhere in the bundle by exact filename
    private func findResource(named filename: String) -> URL? {
        let parts = (filename as NSString).deletingPathExtension
        let ext   = (filename as NSString).pathExtension
        if !ext.isEmpty, let url = Bundle.main.url(forResource: parts, withExtension: ext) {
            return url
        }
        // Fallback: enumerate all files with the same extension and match lastPathComponent
        let extToUse = ext.isEmpty ? nil : ext
        let urls = Bundle.main.urls(forResourcesWithExtension: extToUse, subdirectory: nil) ?? []
        return urls.first { $0.lastPathComponent == filename }
    }

    // Load segments by filename only
    func loadLesson(folderName: String, lessonTitle: String) {
        stop()
        currentIndex = 0
        segments = []
        currentLessonTitle = lessonTitle

        let filename = "segments_\(folderName).json"    // e.g. segments_Lesson1.json
        guard let url = findResource(named: filename) else {
            print("Segments manifest not found: \(filename)")
            updateNowPlayingInfo()
            return
        }

        do {
            let data = try Data(contentsOf: url)
            segments = try JSONDecoder().decode([Segment].self, from: data)
        } catch {
            print("Error decoding \(filename): \(error)")
        }

        updateNowPlayingInfo()
    }

    // Play audio by filename only
    private func playFile(named file: String) {
        audioPlayer?.stop()                      // ⬅️ stop any previous playback
        audioPlayer = nil
        
        guard let url = findResource(named: file) else {
            print("Audio file not found: \(file)")
            return
        }
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.play()
        } catch {
            print("Error playing audio: \(error)")
        }
    }
    
    private func cancelPendingAdvance() {
        pendingAdvance?.cancel()
        pendingAdvance = nil
        isInDelay = false
    }

    func playPortuguese(from index: Int) {
        guard !segments.isEmpty else { return }
        cancelPendingAdvance()
        didFinishLesson = false
        currentIndex = index
        isPlayingPT = true
        isPaused = false
        resumePTAfterENG = false
        playFile(named: segments[currentIndex].pt_file)
        updateNowPlayingInfo()
    }

    func playEnglish() {
        guard !segments.isEmpty else { return }
        cancelPendingAdvance()                 // don't auto-advance while reviewing EN
        didFinishLesson = false
        isPlayingPT = false
        isPaused = false
        resumePTAfterENG = true                // after EN, come back to same PT segment
        playFile(named: segments[currentIndex].en_file)
        updateNowPlayingInfo(isPT: false)
    }

    func togglePlayPause() {
        if let player = audioPlayer, player.isPlaying {
            player.pause()
            isPaused = true
            isPlayingPT = false
            cancelPendingAdvance()
            updateNowPlayingInfo()
            didFinishLesson = false
        } else if let player = audioPlayer, isPaused {
            player.play()
            isPaused = false
            isPlayingPT = true
            updateNowPlayingInfo()
            didFinishLesson = false
        } else {
            playPortuguese(from: currentIndex)
        }
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlayingPT = false
        isPaused = false
        resumePTAfterENG = false
        cancelPendingAdvance()
        didFinishLesson = false
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if resumePTAfterENG {
            resumePTAfterENG = false
            playPortuguese(from: currentIndex)   // resume same segment
        } else if isPlayingPT {
            scheduleAdvanceAfterDelay()          // <-- no index change here
        }
    }
    
    private func removeRemoteControlTargets() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.nextTrackCommand.removeTarget(nil)
        cc.previousTrackCommand.removeTarget(nil)
    }
    
    // MARK: - Remote Control Center
    private func setupRemoteControls() {
        // prevent duplicate handlers if setup is called more than once
        removeRemoteControlTargets()
        
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        // Next track → Play English if PT is playing; otherwise next PT segment
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            
            // If a lesson just finished (we're reset to start), double-press = next lesson
            if self.didFinishLesson {
                self.requestNextLesson?()
                return .success
            }
            
            if self.isPlayingPT {
                self.playEnglish()
                return .success
            } else if self.currentIndex < self.segments.count - 1 {
                self.playPortuguese(from: self.currentIndex + 1)
                return .success
            }
            return .noSuchContent
        }
        // Previous track → go to previous PT segment
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.currentIndex > 0 {
                self.playPortuguese(from: self.currentIndex - 1)
                return .success
            }
            return .noSuchContent
        }
    }

    // Lock screen metadata
    private func updateNowPlayingInfo(isPT: Bool? = nil) {
        guard !segments.isEmpty else { return }
        let segment = segments[currentIndex]
        let playingPT = isPT ?? isPlayingPT
        
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: playingPT ? segment.pt_text : segment.en_text,
            MPMediaItemPropertyArtist: currentLessonTitle.isEmpty ? "Portuguese ↔ English Learning" : currentLessonTitle,
        ]
        if let player = audioPlayer {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
            info[MPMediaItemPropertyPlaybackDuration] = player.duration
            info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? 1.0 : 0.0
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

// MARK: - SwiftUI View
struct ContentView: View {
    @EnvironmentObject private var audioManager : AudioManager
    
    let lessons: [Lesson]
    @State private var currentLessonIndex: Int
    let selectedLesson: Lesson

    init(selectedLesson: Lesson, lessons: [Lesson]) {
        self.selectedLesson = selectedLesson
        self.lessons = lessons
        _currentLessonIndex = State(initialValue: lessons.firstIndex(of: selectedLesson) ?? 0)
    }
    
    @AppStorage("segmentDelay") private var storedDelay: Double = 1.2
    
    private func goToNextLessonAndPlay() {
        guard !lessons.isEmpty else { return }
        // Wrap-around to first lesson when at the end (change to `min(..., lessons.count-1)` if you don't want wrap)
        currentLessonIndex = (currentLessonIndex + 1) % lessons.count
        let next = lessons[currentLessonIndex]
        audioManager.loadLesson(folderName: next.folderName, lessonTitle: next.title)
        audioManager.playPortuguese(from: 0)
    }
    
    var body: some View {
        VStack(spacing: 10) {
            
            Divider()
            
            // Transcript with auto-scroll and tap-to-start
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(audioManager.segments) { segment in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(segment.pt_text)
                                    .font(.headline)
                                    .foregroundColor(segment.id-1 == audioManager.currentIndex ? .blue : .primary)
                                Text(segment.en_text)
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(segment.id-1 == audioManager.currentIndex ? Color.blue.opacity(0.1) : Color.clear)
                            )
                            .onTapGesture {
                                audioManager.playPortuguese(from: segment.id - 1)
                            }
                            .id(segment.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: audioManager.currentIndex) {
                    withAnimation {
                        proxy.scrollTo(audioManager.currentIndex + 1, anchor: .center)
                    }
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 10) {
                Text("Pause Between Segments: \(storedDelay, specifier: "%.1f")s")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // Slider
                Slider(value: $storedDelay, in: 0...20, step: 1.0)
                    .accessibilityLabel("Pause Between Segments")
                    .accessibilityValue("\(storedDelay, specifier: "%.1f") seconds")
                
            }
            .padding(.horizontal)

            
            HStack(spacing: 60) {
                // Play/Pause PT
                Button {
                    audioManager.togglePlayPause()
                } label: {
                    Image(systemName: audioManager.isPlayingPT ? "pause.fill" : "play.fill")
                        .imageScale(.large)
                }
                .buttonStyle(MinimalIconButtonStyle())
                .accessibilityLabel(audioManager.isPlayingPT ? "Pause Portuguese" : "Play Portuguese")
                .accessibilityHint("Toggles Portuguese playback")

                // Play English once (then resume PT)
                Button {
                    audioManager.playEnglish()
                } label: {
                    Image(systemName: "globe")
                        .imageScale(.large)
                }
                .buttonStyle(MinimalIconButtonStyle())
                .accessibilityLabel("Play English once")
                .accessibilityHint("Plays current segment in English, then resumes Portuguese")
            }
            .padding(.bottom, 20)

        }
        .onAppear {
            // Load the initially selected lesson
            audioManager.loadLesson(
                folderName: selectedLesson.folderName,
                lessonTitle: selectedLesson.title
            )

            // Apply persisted delay to the audio manager
            audioManager.segmentDelay = storedDelay

            // Allow AirPods double-press (Next Track) at end-of-lesson to jump to next lesson
            audioManager.requestNextLesson = { [weak audioManager] in
                DispatchQueue.main.async {
                    // assumes you added `goToNextLessonAndPlay()` in ContentView
                    goToNextLessonAndPlay()
                    audioManager?.didFinishLesson = false
                }
            }
        }
        .onChange(of: storedDelay) {
            // Live-update the delay used for the next auto-advance
            audioManager.segmentDelay = storedDelay
        }

    }
}

