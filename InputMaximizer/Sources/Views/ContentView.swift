//
//  ContentView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 01.09.25.
//

import SwiftUI

// Group model for paragraph rendering
private struct ParaGroup: Identifiable {
    let id: Int          // paragraph index
    let segments: [Segment]
}

@MainActor
struct ContentView: View {
    @EnvironmentObject private var audioManager: AudioManager

    @State private var showDelaySheet = false
    private let delayPresets: [Double] = [0, 0.5, 1.0, 1.5, 2.0, 3.0, 5.0]
    
    let lessons: [Lesson]
    @State private var currentLessonIndex: Int
    let selectedLesson: Lesson

    @AppStorage("showTranslation") private var showTranslation: Bool = true
    @AppStorage("segmentDelay") private var storedDelay: Double = 1.2

    // Local, non-playing transcript for whatever is *selected* in UI
    @State private var displaySegments: [Segment] = []

    // MARK: - Init
    init(selectedLesson: Lesson, lessons: [Lesson]) {
        self.selectedLesson = selectedLesson
        self.lessons = lessons
        _currentLessonIndex = State(initialValue: lessons.firstIndex(of: selectedLesson) ?? 0)
    }

    // MARK: - Derived
    private var currentLesson: Lesson { lessons[currentLessonIndex] }

    private var isViewingActiveLesson: Bool {
        audioManager.currentLessonFolderName == currentLesson.folderName
    }

    private var groupedByParagraph: [ParaGroup] {
        let groups = Dictionary(grouping: displaySegments, by: { $0.paragraph })
        return groups
            .map { key, value in
                ParaGroup(id: key, segments: value.sorted { $0.id < $1.id })
            }
            .sorted { ($0.segments.first?.id ?? 0) < ($1.segments.first?.id ?? 0) }
    }

    private var playingSegmentID: Int? {
        guard isViewingActiveLesson,
              audioManager.currentIndex >= 0,
              audioManager.currentIndex < audioManager.segments.count else { return nil }
        return audioManager.segments[audioManager.currentIndex].id
    }

    private func scrollID(for segmentID: Int, in folder: String) -> String {
        "\(folder)#\(segmentID)"
    }

    private var playingScrollID: String? {
        guard isViewingActiveLesson,
              audioManager.currentIndex >= 0,
              audioManager.currentIndex < audioManager.segments.count,
              let folder = audioManager.currentLessonFolderName
        else { return nil }
        let segID = audioManager.segments[audioManager.currentIndex].id
        return scrollID(for: segID, in: folder)
    }

    // MARK: - Actions
    /// Start playback in the lane that matches the current continuous mode
    private func goToNextLessonAndPlay() {
        guard !lessons.isEmpty else { return }
        currentLessonIndex = (currentLessonIndex + 1) % lessons.count
        let next = lessons[currentLessonIndex]
        audioManager.loadLesson(folderName: next.folderName, lessonTitle: next.title)

        switch audioManager.playbackMode {
        case .target:
            audioManager.playPortuguese(from: 0)
        case .translation:
            audioManager.playTranslation(resumeAfterTarget: false)
        case .both:
            // Start the dual sequence from the beginning
            audioManager.playInContinuousLane(from: 0)
        }
    }

    // MARK: - View
    var body: some View {
        VStack(spacing: 10) {
            Divider()

            // Transcript with auto-scroll and tap-to-start
            ScrollViewReader { proxy in
                TranscriptList(
                    groups: groupedByParagraph,
                    folderName: currentLesson.folderName,
                    showTranslation: showTranslation,
                    playingSegmentID: playingSegmentID,
                    headerTitle: currentLesson.title
                ) { segment in
                    if !isViewingActiveLesson {
                        audioManager.loadLesson(
                            folderName: currentLesson.folderName,
                            lessonTitle: currentLesson.title
                        )
                    }

                    if let idx = audioManager.segments.firstIndex(where: { $0.id == segment.id }) {
                        // ✅ Play directly in the current continuous lane (no PT-then-EN hop)
                        audioManager.playInContinuousLane(from: idx)
                    }
                }
                .onChange(of: audioManager.currentIndex) { _ in
                    guard let id = playingScrollID else { return }
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .onChange(of: showTranslation) { _ in
                    guard let id = playingScrollID else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                }
            }

            HStack(spacing: 60) {
                Button {
                    audioManager.togglePlayPause()
                } label: {
                    Image(systemName: audioManager.isPlaying ? "pause.fill" : "play.fill")
                        .imageScale(.large)
                }
                .buttonStyle(MinimalIconButtonStyle())
                .accessibilityLabel(audioManager.isPlayingPT ? "Pause Portuguese" : "Play Portuguese")
                .accessibilityHint("Toggles Portuguese playback.")

                // One-off opposite lane (unchanged)
                Button {
                    audioManager.playOppositeOnce()
                } label: {
                    Image(systemName: "globe")
                        .imageScale(.large)
                }
                .buttonStyle(MinimalIconButtonStyle())
                .accessibilityLabel(
                    audioManager.playbackMode == .target
                    ? "Play translation once"
                    : "Play target once"
                )
                .accessibilityHint(
                    audioManager.playbackMode == .target
                    ? "Plays the translated line once, then resumes target language."
                    : "Plays the target line once, then resumes translation."
                )
            }
            .padding(.bottom, 20)
        }
        .onAppear {
            displaySegments = audioManager.previewSegments(for: currentLesson.folderName)
            audioManager.segmentDelay = storedDelay
            audioManager.requestNextLesson = { [weak audioManager] in
                DispatchQueue.main.async {
                    goToNextLessonAndPlay()
                    audioManager?.didFinishLesson = false
                }
            }
        }
        .onChange(of: currentLessonIndex) { _ in
            displaySegments = audioManager.previewSegments(for: currentLesson.folderName)
        }
        .onChange(of: audioManager.currentLessonFolderName ?? "") { _ in
            if let folder = audioManager.currentLessonFolderName,
               let idx = lessons.firstIndex(where: { $0.folderName == folder }) {
                currentLessonIndex = idx
                displaySegments = audioManager.previewSegments(for: folder)
            }
        }
        // keep AudioManager's delay in sync with the slider value
        .onChange(of: storedDelay) { newValue in
            audioManager.segmentDelay = newValue
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    // quick picks
                    Picker("Pause Between Segments", selection: $storedDelay) {
                        ForEach(delayPresets, id: \.self) { v in
                            Text("\(v, specifier: "%.1f")s").tag(v)
                        }
                    }
                    // fine-tune
                    Button("Custom…") { showDelaySheet = true }
                } label: {
                    Image(systemName: "metronome.fill") // or "timer"
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showTranslation.toggle()
                } label: {
                    Image(systemName: showTranslation ? "eye" : "eye.slash")
                }
                .accessibilityLabel(showTranslation ? "Hide translation" : "Show translation")
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    let next: AudioManager.PlaybackMode = {
                        switch audioManager.playbackMode {
                        case .target: return .translation
                        case .translation: return .both
                        case .both: return .target
                        }
                    }()

                    audioManager.setPlaybackMode(next)

                    // Re-play current segment according to the chosen mode (no auto-hop)
                    audioManager.playInContinuousLane(from: audioManager.currentIndex)
                } label: {
                    Group {
                        switch audioManager.playbackMode {
                        case .target:
                            Image(systemName: "character.book.closed")          // Target-only
                        case .translation:
                            Image(systemName: "globe")                           // Translation-only
                        case .both:
                            Image(systemName: "arrow.left.and.right.circle")     // Dual (both languages)
                        }
                    }
                }
                .accessibilityLabel({
                    switch audioManager.playbackMode {
                    case .target: return "Switch to translation playback"
                    case .translation: return "Switch to dual playback"
                    case .both: return "Switch to target playback"
                    }
                }())
                .accessibilityHint("Cycles between target, translation, and dual playback modes.")
            }
        }
        .sheet(isPresented: $showDelaySheet) {
            NavigationStack {
                Form {
                    Section {
                        Text("Pause Between Segments: \(storedDelay, specifier: "%.1f")s")
                        Slider(value: $storedDelay, in: 0...20, step: 0.5)
                            .accessibilityLabel("Pause Between Segments")
                    }
                }
                .navigationTitle("Playback Pause")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showDelaySheet = false }
                    }
                }
            }
        }
    }
}

// MARK: - Transcript List & Rows

private struct SegmentRow: View {
    let segment: Segment
    let isPlaying: Bool
    let showTranslation: Bool
    let rowID: String
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Accent rail highlights the currently playing segment
            Rectangle()
                .fill(isPlaying ? Color.accentColor : .clear)
                .frame(width: 3)
                .cornerRadius(2)

            VStack(alignment: .leading, spacing: 5) {
                Text(segment.pt_text)
                    .font(.headline)
                    .foregroundColor(.primary)
                if showTranslation {
                    Text(segment.en_text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(isPlaying ? Color.selectionAccent : Color.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .id(rowID)
        .onTapGesture(perform: onTap)
    }
}

private struct ParagraphBox: View {
    let group: ParaGroup
    let folderName: String
    let showTranslation: Bool
    let playingSegmentID: Int?
    let onTap: (Segment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(group.segments) { seg in
                SegmentRow(
                    segment: seg,
                    isPlaying: playingSegmentID == seg.id,
                    showTranslation: showTranslation,
                    rowID: "\(folderName)#\(seg.id)",
                    onTap: { onTap(seg) }
                )
            }
        }
        .padding(12)
        .cardBackground() // unified card look
    }
}

private struct TranscriptList: View {
    let groups: [ParaGroup]
    let folderName: String
    let showTranslation: Bool
    let playingSegmentID: Int?
    let headerTitle: String?
    let onTap: (Segment) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let headerTitle {
                    Text(headerTitle)
                        .font(.largeTitle.bold())
                        .padding(.horizontal)
                        .padding(.top, 8)
                }

                ForEach(groups, id: \.id) { group in
                    ParagraphBox(
                        group: group,
                        folderName: folderName,
                        showTranslation: showTranslation,
                        playingSegmentID: playingSegmentID,
                        onTap: onTap
                    )
                }
            }
            .id(folderName)          // reset layout identity on lesson change
            .padding()
        }
        .background(Color.appBackground)
    }
}

