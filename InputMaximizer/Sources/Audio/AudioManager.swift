//
//  AudioManager.swift
//  InputMaximizer
//
//  Created by Robin Geske on 01.09.25.
//

import Foundation
import AVFoundation
import MediaPlayer
import Combine

@MainActor
final class AudioManager: NSObject, ObservableObject, AVAudioPlayerDelegate {

    // MARK: - Types
    enum PlaybackMode { case target, translation, both } // continuous lane
    private enum Lane { case pt, en }

    // MARK: - Published State

    @Published var segments: [Segment] = []
    @Published var currentIndex: Int = 0

    @Published var isPlaying: Bool = false       // something is playing (either lane)
    @Published var isPlayingPT: Bool = false     // current lane == Portuguese
    @Published var isPaused: Bool = false
    @Published var isInDelay: Bool = false
    
    @Published var playbackMode: PlaybackMode = .target
    private var lastSingleMode: PlaybackMode = .target      // ✅ remembers which comes first in Dual
    private var firstLaneForPair: Lane {
        (lastSingleMode == .target) ? .pt : .en
    }
    private func opposite(_ lane: Lane) -> Lane { lane == .pt ? .en : .pt }

    // Call this instead of setting playbackMode directly:
    func setPlaybackMode(_ newMode: PlaybackMode) {
        playbackMode = newMode
        if newMode == .target || newMode == .translation {
            lastSingleMode = newMode
        }
    }

    @Published var didFinishLesson: Bool = false
    @Published var currentLessonFolderName: String?
    @Published var currentLessonTitle: String = ""

    /// Pause between segments (persisted).
    @Published var segmentDelay: TimeInterval = {
        let stored = UserDefaults.standard.double(forKey: "segmentDelay")
        return stored == 0 ? 1.2 : stored
    }() {
        didSet {
            if segmentDelay < 0 { segmentDelay = 0 }
            UserDefaults.standard.set(segmentDelay, forKey: "segmentDelay")
        }
    }

    // MARK: - Private State

    private var audioPlayer: AVAudioPlayer?
    private var pendingAdvance: DispatchWorkItem?

    // One-off resume flags (symmetric)
    private var resumePTAfterENG = false  // play EN once, then resume PT
    private var resumeENAfterPT = false   // play PT once, then resume EN

    // End-of-lesson double-tap
    private var allowNextDoubleUntil: Date?
    private let doubleTapWindow: TimeInterval = 0.6

    // Keepalive (silent loop to remain addressable by remote center)
    private let keepalive = SilentKeepalive()

    // MARK: - Hand-off closure from UI

    var requestNextLesson: (() -> Void)?

    // MARK: - Lifecycle

    override init() {
        super.init()
        setupAudioSession()
        RemoteCommandsBinder.removeTargets() // ensure clean slate
        setupRemoteControls()
    }

    deinit {
        // deinit is nonisolated — do minimal, thread-safe cleanup only.
        audioPlayer?.stop()
        keepalive.stop()
        RemoteCommandsBinder.removeTargets()
        do { try AVAudioSession.sharedInstance().setActive(false) }
        catch { print("Failed to deactivate audio session: \(error)") }
    }

    // MARK: - Public API

    /// Read segments for a lesson without changing playback state.
    func previewSegments(for folderName: String) -> [Segment] {
        let filename = "segments_\(folderName).json"
        guard let url = ResourceLocator.shared.find(filename: filename),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Segment].self, from: data) else {
            return []
        }
        return list
    }

    /// Load lesson by folder + title; keeps current lesson if already loaded.
    func loadLesson(folderName: String, lessonTitle: String) {
        if currentLessonFolderName == folderName, !segments.isEmpty {
            currentLessonTitle = lessonTitle
            updateNowPlayingInfo()
            return
        }

        stop()  // only stop when actually switching lessons
        currentIndex = 0
        segments = []
        currentLessonTitle = lessonTitle
        currentLessonFolderName = folderName

        let filename = "segments_\(folderName).json"
        guard let url = ResourceLocator.shared.find(filename: filename) else {
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

    // MARK: - Unified Play Entry Points

    func playPortuguese(from index: Int) {
        play(.pt, from: index, resumeAfter: false)
    }

    /// Plays translation once; optionally resumes target mode depending on context.
    func playTranslation(resumeAfterTarget: Bool = true) {
        play(.en, from: currentIndex, resumeAfter: resumeAfterTarget && playbackMode == .target)
    }

    /// NEW: Start playback directly in the current continuous lane from a given index.
    func playInContinuousLane(from index: Int) {
        switch playbackMode {
        case .target:
            play(.pt, from: index, resumeAfter: false)
        case .translation:
            play(.en, from: index, resumeAfter: false)
        case .both:
            play(firstLaneForPair, from: index, resumeAfter: false)   // ✅ first lane depends on lastSingleMode
        }
    }

    /// NEW: One-off opposite lane, then resume the current continuous lane.
    func playOppositeOnce() {
        switch playbackMode {
        case .target:
            // same as your existing "globe" behavior
            playTranslation(resumeAfterTarget: true) // EN once, back to PT
        case .translation:
            // play PT once, then resume EN lane
            cancelPendingAdvance()
            didFinishLesson = false
            resumeENAfterPT = true
            play(.pt, from: currentIndex, resumeAfter: false)
        case .both:
            // Replay both languages for the current segment
            cancelPendingAdvance()
            didFinishLesson = false
            // Always restart from the first lane (PT or EN, depending on lastSingleMode)
            play(firstLaneForPair, from: currentIndex, resumeAfter: false)
        }
    }

    /// Convenience for "review English then return".
    func playEnglish() {
        play(.en, from: currentIndex, resumeAfter: true)
    }

    func togglePlayPause() {
        if let player = audioPlayer, player.isPlaying {
            player.pause()
            isPaused = true
            isPlaying = false
            cancelPendingAdvance()
            updateNowPlayingInfo()
            didFinishLesson = false
            return
        } else if let player = audioPlayer, isPaused {
            player.play()
            isPaused = false
            isPlaying = true
            updateNowPlayingInfo()
            didFinishLesson = false
            return
        }

        // Nothing playing
        if didFinishLesson {
            // Restart according to the current continuous mode
            playInContinuousLane(from: 0)
            didFinishLesson = false
        } else if isInDelay {
            playEnglish()
        } else {
            // Respect the current continuous lane for ad-hoc starts, too
            playInContinuousLane(from: currentIndex)
        }
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlayingPT = false
        isPaused = false
        isPlaying = false
        resumePTAfterENG = false
        resumeENAfterPT = false
        cancelPendingAdvance()
        didFinishLesson = false
        keepalive.stop()
    }

    // MARK: - AVAudioPlayerDelegate

    // Satisfy the nonisolated protocol requirement in Swift 6.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.handleDidFinishPlaying(success: flag)
        }
    }

    // Keep all the original logic here, still on the MainActor.
    @MainActor
    private func handleDidFinishPlaying(success: Bool) {
        isPlaying = false

        // keep existing one-off logic
        if resumePTAfterENG { resumePTAfterENG = false; play(.pt, from: currentIndex, resumeAfter: false); return }
        if resumeENAfterPT { resumeENAfterPT = false; play(.en, from: currentIndex, resumeAfter: false); return }

        let justPlayedPT = isPlayingPT

        // ✅ Dual-mode chaining: PT→EN or EN→PT, then advance
        if playbackMode == .both {
            let first = firstLaneForPair
            let justPlayed: Lane = justPlayedPT ? .pt : .en
            if justPlayed == first {
                // play the other lane, same segment
                play(opposite(first), from: currentIndex, resumeAfter: false)
                return
            } else {
                // both lanes done → advance
                scheduleAdvanceAfterDelay()
                return
            }
        }

        // original single-lane behavior
        if (justPlayedPT && playbackMode == .target) || (!justPlayedPT && playbackMode == .translation) {
            scheduleAdvanceAfterDelay()
        }
    }


    // MARK: - Private: Unified Play

    private func play(_ lane: Lane, from index: Int, resumeAfter: Bool) {
        guard !segments.isEmpty, index >= 0, index < segments.count else { return }

        cancelPendingAdvance()
        didFinishLesson = false
        currentIndex = index

        switch lane {
        case .pt:
            isPlayingPT = true
            isPaused = false
            // if we're playing PT, make sure we don't incorrectly resume PT-after-EN
            if resumeAfter == false { resumePTAfterENG = false }
            playFile(named: segments[currentIndex].pt_file)
            updateNowPlayingInfo(isPTOverride: true)

        case .en:
            isPlayingPT = false
            isPaused = false
            resumePTAfterENG = resumeAfter
            playFile(named: segments[currentIndex].en_file)
            updateNowPlayingInfo(isPTOverride: false)
        }
    }

    // MARK: - Private: Audio & Timing

    private func playFile(named file: String) {
        keepalive.stop()
        audioPlayer?.stop()
        audioPlayer = nil

        guard let url = ResourceLocator.shared.find(filename: file) else {
            print("Audio file not found: \(file)")
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            audioPlayer = player
            player.delegate = self
            player.play()
            isPlaying = true
        } catch {
            print("Error playing audio: \(error)")
        }
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            print("Failed to set audio session: \(error)")
        }
    }

    private func scheduleAdvanceAfterDelay() {
        pendingAdvance?.cancel()

        // End of lesson?
        guard currentIndex < segments.count - 1 else {
            // reset playback state
            isPlayingPT = false
            isPaused = false
            isInDelay = false
            isPlaying = false
            didFinishLesson = true
            // keep any in-flight double-tap window alive; the tap handler will consume/expire it

            // ⬅️ Make sure we move the cursor back to the first segment
            currentIndex = 0

            // keep Control Center info coherent with the lane
            let titleForFirstLane: String = {
                guard !segments.isEmpty else { return "Lesson" }
                let seg0 = segments[0]
                switch playbackMode {
                case .target:      return seg0.pt_text
                case .translation: return seg0.en_text
                case .both:
                    return (firstLaneForPair == .pt) ? seg0.pt_text : seg0.en_text
                }
            }()

            // update Now Playing (shows 0 duration/paused keepalive)
            updateNowPlayingInfo()

            // keepalive so remote center remains addressable
            keepalive.start(
                nowPlayingTitle: titleForFirstLane,
                artist: currentLessonTitle.isEmpty ? NowPlayingBuilder.defaultArtist : currentLessonTitle,
                queueCount: segments.count,
                queueIndex: currentIndex // ← should be 0 after the assignment above
            )
            return
        }

        // Delay phase
        isPlayingPT = false
        isInDelay = true
        // Do not touch allowNextDoubleUntil here

        keepalive.start(nowPlayingTitle: segments[currentIndex].pt_text,
                        artist: currentLessonTitle.isEmpty ? NowPlayingBuilder.defaultArtist : currentLessonTitle,
                        queueCount: segments.count,
                        queueIndex: currentIndex)

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.isInDelay = false
            self.keepalive.stop()
            self.currentIndex += 1

            switch self.playbackMode {
            case .target:       self.play(.pt, from: self.currentIndex, resumeAfter: false)
            case .translation:  self.play(.en, from: self.currentIndex, resumeAfter: false)
            case .both:         self.play(self.firstLaneForPair, from: self.currentIndex, resumeAfter: false) // ✅
            }
        }
        pendingAdvance = work
        DispatchQueue.main.asyncAfter(deadline: .now() + segmentDelay, execute: work)
    }

    private func cancelPendingAdvance() {
        pendingAdvance?.cancel()
        pendingAdvance = nil
        isInDelay = false
    }

    // MARK: - Now Playing

    private func updateNowPlayingInfo(isPTOverride: Bool? = nil) {
        guard !segments.isEmpty else { return }
        let seg = segments[currentIndex]
        let showPT = isPTOverride ?? isPlayingPT

        let info = NowPlayingBuilder.infoDict(
            title: showPT ? seg.pt_text : seg.en_text,
            artist: currentLessonTitle.isEmpty ? "Portuguese ↔ English Learning" : currentLessonTitle,
            elapsed: audioPlayer?.currentTime,
            duration: audioPlayer?.duration,
            isPlaying: audioPlayer?.isPlaying ?? false
        )
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Remote Commands

    private func setupRemoteControls() {
        RemoteCommandsBinder.removeTargets()

        RemoteCommandsBinder.bind(
            onPlayOrToggle: { [weak self] in
                guard let self else { return .commandFailed }
                let now = Date()

                // End-of-lesson gestures
                if didFinishLesson || allowNextDoubleUntil != nil {
                    if let until = allowNextDoubleUntil, now < until {
                        // SECOND TAP → next lesson
                        // Stop anything we just (re)started to avoid overlap/state bleed
                        allowNextDoubleUntil = nil
                        stop()                    // avoid overlap/state bleed
                        requestNextLesson?()
                        didFinishLesson = false
                        return .success
                    } else {
                        // FIRST TAP → restart current lesson from segment 0 in the active continuous lane
                        allowNextDoubleUntil = now.addingTimeInterval(doubleTapWindow)

                        // 🔧 Make the restart deterministic
                        cancelPendingAdvance()
                        keepalive.stop()
                        resumePTAfterENG = false
                        resumeENAfterPT = false
                        didFinishLesson = false
                        currentIndex = 0

                        // Respect .target / .translation / .both (Dual starts from firstLaneForPair)
                        playInContinuousLane(from: 0)
                        return .success
                    }
                }


                if isInDelay {
                    playEnglish()
                    return .success
                }

                togglePlayPause()
                return .success
            },
            onPause: { [weak self] in
                self?.togglePlayPause()
                return .success
            },
            // Inside setupRemoteControls()
            onNext: { [weak self] in
                guard let self else { return .commandFailed }
                let now = Date()

                // ✅ End-of-lesson: a Next command should go straight to the NEXT LESSON (all modes).
                if didFinishLesson {
                    allowNextDoubleUntil = nil
                    stop()                    // avoid overlap/state bleed (stops keepalive too)
                    requestNextLesson?()
                    didFinishLesson = false
                    return .success
                }

                // ✅ If a Next arrives within the play/pause double-tap window, treat it as "second tap" → next lesson.
                if let until = allowNextDoubleUntil, now < until {
                    allowNextDoubleUntil = nil
                    stop()
                    requestNextLesson?()
                    didFinishLesson = false
                    return .success
                }

                // Otherwise, normal "Next" behavior by mode
                if playbackMode == .translation {
                    cancelPendingAdvance()
                    didFinishLesson = false
                    resumeENAfterPT = true
                    if !isPlayingPT || isInDelay {
                        // EN (or delay) → PT of SAME segment
                        play(.pt, from: currentIndex, resumeAfter: false)
                        return .success
                    } else {
                        // PT is playing (second press) → EN of NEXT segment
                        guard currentIndex < segments.count - 1 else { return .noSuchContent }
                        play(.en, from: currentIndex + 1, resumeAfter: false)
                        return .success
                    }
                }

                if playbackMode == .both {
                    cancelPendingAdvance()
                    didFinishLesson = false

                    if isPlayingPT {
                        // PT → EN of NEXT segment
                        guard currentIndex < segments.count - 1 else { return .noSuchContent }
                        play(.en, from: currentIndex + 1, resumeAfter: false)
                        return .success
                    } else {
                        // EN (or delay) → PT of SAME segment
                        play(.pt, from: currentIndex, resumeAfter: false)
                        return .success
                    }
                }

                // Single-lane fallbacks (.target or generic)
                if isPlayingPT || isInDelay {
                    playEnglish(); return .success
                } else if currentIndex < segments.count - 1 {
                    play(.pt, from: currentIndex + 1, resumeAfter: false); return .success
                }
                return .noSuchContent
            },


            onPrev: { [weak self] in
                guard let self else { return .commandFailed }
                allowNextDoubleUntil = nil

                // ✅ Dual (both) mode – corrected "Back" behavior
                if playbackMode == .both {
                    cancelPendingAdvance()
                    didFinishLesson = false

                    if isPlayingPT {
                        // PT → EN of SAME segment
                        play(.en, from: currentIndex, resumeAfter: false)
                        return .success
                    } else {
                        // EN (or delay) → PT of PREVIOUS segment
                        guard currentIndex > 0 else { return .noSuchContent }
                        play(.pt, from: currentIndex - 1, resumeAfter: false)
                        return .success
                    }
                }

                // (unchanged for other modes)
                guard currentIndex > 0 else { return .noSuchContent }
                switch playbackMode {
                case .translation:
                    play(.en, from: currentIndex - 1, resumeAfter: false)
                    return .success
                case .target:
                    play(.pt, from: currentIndex - 1, resumeAfter: false)
                    return .success
                case .both:
                    return .success // handled above
                }
            }

        )
    }
}

// MARK: - Keepalive (silent audio) + Now Playing builder

/// Tiny helper that plays a silent looping CAF to keep the app addressable by Remote Center.
private final class SilentKeepalive {
    private var player: AVAudioPlayer?

    func start(nowPlayingTitle: String, artist: String, queueCount: Int, queueIndex: Int) {
        guard player?.isPlaying != true,
              let url = ResourceLocator.shared.find(filename: "silence.caf") else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = 0.0
            p.prepareToPlay()
            p.play()
            player = p

            // present a valid "now playing" while idle
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyTitle] = nowPlayingTitle
            info[MPMediaItemPropertyArtist] = artist
            info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queueCount
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = p.currentTime
            info[MPMediaItemPropertyPlaybackDuration] = p.duration
            info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        } catch {
            print("Failed to start keepalive: \(error)")
        }
    }

    func stop() {
        player?.stop()
        player = nil

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

/// Centralizes Now Playing dictionary construction.
private enum NowPlayingBuilder {
    static let defaultArtist = "Language Practice"

    static func infoDict(
        title: String,
        artist: String,
        elapsed: TimeInterval?,
        duration: TimeInterval?,
        isPlaying: Bool
    ) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist
        ]
        if let elapsed { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        return info
    }
}

// MARK: - Remote Commands binder (nonisolated removal, single bind site)

private enum RemoteCommandsBinder {
    nonisolated static func removeTargets() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.nextTrackCommand.removeTarget(nil)
        cc.previousTrackCommand.removeTarget(nil)
        cc.togglePlayPauseCommand.removeTarget(nil)
    }

    @MainActor
    static func bind(
        onPlayOrToggle: @escaping () -> MPRemoteCommandHandlerStatus,
        onPause: @escaping () -> MPRemoteCommandHandlerStatus,
        onNext: @escaping () -> MPRemoteCommandHandlerStatus,
        onPrev: @escaping () -> MPRemoteCommandHandlerStatus
    ) {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { _ in onPlayOrToggle() }
        cc.togglePlayPauseCommand.addTarget { _ in onPlayOrToggle() }
        cc.pauseCommand.addTarget { _ in onPause() }
        cc.nextTrackCommand.addTarget { _ in onNext() }
        cc.previousTrackCommand.addTarget { _ in onPrev() }
    }
}

// MARK: - Resource Locator

/// Centralized resource search used across the app.
struct ResourceLocator {
    static let shared = ResourceLocator()

    func find(filename: String) -> URL? {
        // 1) Documents/Lessons/**/filename
        let docs = FileManager.docsLessonsDir
        if let enumerator = FileManager.default.enumerator(at: docs, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.lastPathComponent == filename {
                return url
            }
        }

        // 2) Bundle direct by name/ext
        let parts = (filename as NSString).deletingPathExtension
        let ext   = (filename as NSString).pathExtension
        if !ext.isEmpty, let url = Bundle.main.url(forResource: parts, withExtension: ext) {
            return url
        }

        // 3) Bundle scan fallback
        let extToUse: String? = ext.isEmpty ? nil : ext
        let urls = Bundle.main.urls(forResourcesWithExtension: extToUse, subdirectory: nil) ?? []
        return urls.first { $0.lastPathComponent == filename }
    }
}
