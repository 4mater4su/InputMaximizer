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
    private let segmentDelay: TimeInterval = 1.2 // delay between PT segments
    
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
    
    // Toggle PT playback
    func togglePlayPause() {
        if let player = audioPlayer, player.isPlaying {
            player.pause()
            isPaused = true
            isPlayingPT = false
            updateNowPlayingInfo()
        } else if let player = audioPlayer, isPaused {
            player.play()
            isPaused = false
            isPlayingPT = true
            updateNowPlayingInfo()
        } else {
            playPortuguese(from: currentIndex)
        }
    }
    
    // Play PT from specific index
    func playPortuguese(from index: Int) {
        guard !segments.isEmpty else { return }
        currentIndex = index
        isPlayingPT = true
        isPaused = false
        resumePTAfterENG = false
        playFile(named: segments[currentIndex].pt_file)
        updateNowPlayingInfo()
    }
    
    // Play ENG once, then resume PT
    func playEnglish() {
        guard !segments.isEmpty else { return }
        isPlayingPT = false
        isPaused = false
        resumePTAfterENG = true
        playFile(named: segments[currentIndex].en_file)
        updateNowPlayingInfo(isPT: false)
    }
    
    // Stop everything (used when switching lessons)
    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlayingPT = false
        isPaused = false
        resumePTAfterENG = false
    }
    


    
    // Handle when audio finishes
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if resumePTAfterENG {
            // After ENG, return to PT (same segment)
            resumePTAfterENG = false
            playPortuguese(from: currentIndex)
        } else if isPlayingPT {
            // Advance PT with a short delay
            if currentIndex < segments.count - 1 {
                currentIndex += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + segmentDelay) {
                    self.playPortuguese(from: self.currentIndex)
                }
            } else {
                // Finished all PT segments
                isPlayingPT = false
                isPaused = false
                currentIndex = 0
                updateNowPlayingInfo()
            }
        }
    }
    
    // MARK: - Remote Control Center
    private func setupRemoteControls() {
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
    @StateObject private var audioManager = AudioManager()
    var selectedLesson: Lesson
    
    var body: some View {
        VStack(spacing: 10) {
            
            Divider()
            
            Text("Language Learning Audio")
                .font(.title2)
                .padding(.top, 4)
            
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
            
            
            HStack(spacing: 20) {
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
            audioManager.loadLesson(folderName: selectedLesson.folderName,
                                                lessonTitle: selectedLesson.title)
        }
    }
}

