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

    // MARK: - Published State
    @Published var segments: [Segment] = []
    @Published var currentIndex: Int = 0
    @Published var isPlaying: Bool = false
    @Published var isPlayingPT: Bool = false
    @Published var isPaused: Bool = false
    @Published var isInDelay: Bool = false
    @Published var playbackMode: PlaybackMode = .target
    @Published var didFinishLesson: Bool = false
    @Published var currentLessonFolderName: String?
    @Published var currentLessonTitle: String = ""

    // MARK: - Public Config
    enum PlaybackMode { case target, translation }

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

    // MARK: - Private
    private var audioPlayer: AVAudioPlayer?
    private var keepalivePlayer: AVAudioPlayer?
    private var pendingAdvance: DispatchWorkItem?
    private var resumePTAfterENG = false

    private var allowNextDoubleUntil: Date?
    private let doubleTapWindow: TimeInterval = 0.6

    // Track current lesson location
    private var currentLessonBaseURL: URL?

    // MARK: - Hand-off closure from UI
    var requestNextLesson: (() -> Void)?

    // MARK: - Init / Deinit
    override init() {
        super.init()
        setupAudioSession()
        setupRemoteControls()
    }

    deinit {
        // IMPORTANT: deinit is nonisolated — don't call @MainActor instance methods here.
        // Do minimal, thread-safe cleanup only.
        audioPlayer?.stop()
        keepalivePlayer?.stop()
        Self.removeRemoteControlTargets() // static nonisolated helper (see below)
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
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

    /// Plays translation once; optionally resumes target mode depending on context.
    func playTranslation(resumeAfterTarget: Bool = true) {
        guard !segments.isEmpty else { return }
        cancelPendingAdvance()
        didFinishLesson = false
        isPlayingPT = false
        isPaused = false
        resumePTAfterENG = resumeAfterTarget && playbackMode == .target
        playFile(named: segments[currentIndex].en_file)
        updateNowPlayingInfo(isPT: false)
    }

    /// Convenience for "review English then return".
    func playEnglish() {
        guard !segments.isEmpty else { return }
        cancelPendingAdvance()
        didFinishLesson = false
        isPlayingPT = false
        isPaused = false
        resumePTAfterENG = true
        playFile(named: segments[currentIndex].en_file)
        updateNowPlayingInfo(isPT: false)
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
            playPortuguese(from: 0) // replay current lesson
            didFinishLesson = false
        } else if isInDelay {
            playEnglish()
        } else {
            playPortuguese(from: currentIndex)
        }
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlayingPT = false
        isPaused = false
        isPlaying = false
        resumePTAfterENG = false
        cancelPendingAdvance()
        didFinishLesson = false
        stopRemoteKeepalive()
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false

        if resumePTAfterENG {
            resumePTAfterENG = false
            playPortuguese(from: currentIndex)
            return
        }

        // Keep chaining only if language lane matches playbackMode
        if (isPlayingPT && playbackMode == .target) || (!isPlayingPT && playbackMode == .translation) {
            scheduleAdvanceAfterDelay()
        }
    }

    // MARK: - Private: Audio

    private func playFile(named file: String) {
        stopRemoteKeepalive()
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

        guard currentIndex < segments.count - 1 else {
            // Lesson is done
            isPlayingPT = false
            isPaused = false
            isInDelay = false
            didFinishLesson = true
            allowNextDoubleUntil = nil
            currentIndex = 0
            updateNowPlayingInfo()
            startRemoteKeepalive()
            return
        }

        isPlayingPT = false
        isInDelay = true
        allowNextDoubleUntil = nil
        startRemoteKeepalive()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.isInDelay = false
            self.stopRemoteKeepalive()
            self.currentIndex += 1

            switch self.playbackMode {
            case .target:
                self.playPortuguese(from: self.currentIndex)
            case .translation:
                self.playTranslation(resumeAfterTarget: false)
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

    // MARK: - Keepalive + Now Playing

    private func startRemoteKeepalive() {
        if let p = audioPlayer, p.isPlaying { return }
        guard keepalivePlayer == nil,
              let url = ResourceLocator.shared.find(filename: "silence.caf") else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = 0.0
            p.prepareToPlay()
            p.play()
            keepalivePlayer = p

            // Present a valid "now playing" while idle
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            let title = segments.isEmpty ? "Lesson" : segments[currentIndex].pt_text
            let artist = currentLessonTitle.isEmpty ? Self.defaultArtist : currentLessonTitle
            info[MPMediaItemPropertyTitle] = title
            info[MPMediaItemPropertyArtist] = artist
            info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = segments.count
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = currentIndex
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = p.currentTime
            info[MPMediaItemPropertyPlaybackDuration] = p.duration
            info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        } catch {
            print("Failed to start keepalive: \(error)")
        }
    }

    private func stopRemoteKeepalive() {
        keepalivePlayer?.stop()
        keepalivePlayer = nil

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if let real = audioPlayer {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = real.currentTime
            info[MPMediaItemPropertyPlaybackDuration] = real.duration
            info[MPNowPlayingInfoPropertyPlaybackRate] = real.isPlaying ? 1.0 : 0.0
        } else {
            info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private static let defaultArtist = "Language Practice"

    private func updateNowPlayingInfo(isPT: Bool? = nil) {
        guard !segments.isEmpty else { return }
        let segment = segments[currentIndex]
        let playingPT = isPT ?? isPlayingPT

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: playingPT ? segment.pt_text : segment.en_text,
            MPMediaItemPropertyArtist: currentLessonTitle.isEmpty ? "Portuguese ↔ English Learning" : currentLessonTitle
        ]

        if let player = audioPlayer {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
            info[MPMediaItemPropertyPlaybackDuration] = player.duration
            info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? 1.0 : 0.0
        } else {
            info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Remote Commands

    /// NOTE: static + nonisolated so it can be called from deinit safely.
    nonisolated private static func removeRemoteControlTargets() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.nextTrackCommand.removeTarget(nil)
        cc.previousTrackCommand.removeTarget(nil)
        cc.togglePlayPauseCommand.removeTarget(nil)
    }

    private func setupRemoteControls() {
        // Use the static nonisolated helper to clear any existing handlers
        Self.removeRemoteControlTargets()

        let cc = MPRemoteCommandCenter.shared()

        func handlePlayOrToggle() -> MPRemoteCommandHandlerStatus {
            let now = Date()

            // End-of-lesson gestures
            if didFinishLesson || allowNextDoubleUntil != nil {
                if let until = allowNextDoubleUntil, now < until {
                    allowNextDoubleUntil = nil
                    requestNextLesson?()
                    didFinishLesson = false
                    return .success
                } else {
                    allowNextDoubleUntil = now.addingTimeInterval(doubleTapWindow)
                    playPortuguese(from: 0)
                    didFinishLesson = false
                    return .success
                }
            }

            if isInDelay {
                playEnglish()
                return .success
            }

            togglePlayPause()
            return .success
        }

        cc.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            return handlePlayOrToggle()
        }

        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            return handlePlayOrToggle()
        }

        cc.pauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        // Next track → Play English if PT is playing (or during delay); else next PT segment
        cc.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.allowNextDoubleUntil = nil

            if self.didFinishLesson {
                self.requestNextLesson?()
                return .success
            }

            if self.isPlayingPT || self.isInDelay {
                self.playEnglish()
                return .success
            } else if self.currentIndex < self.segments.count - 1 {
                self.playPortuguese(from: self.currentIndex + 1)
                return .success
            }

            return .noSuchContent
        }

        // Previous track → previous PT segment
        cc.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.currentIndex > 0 {
                self.playPortuguese(from: self.currentIndex - 1)
                return .success
            }
            return .noSuchContent
        }
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
