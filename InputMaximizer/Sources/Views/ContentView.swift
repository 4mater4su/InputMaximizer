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

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Pause Between Segments: \(storedDelay, specifier: "%.1f")s")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Slider(value: $storedDelay, in: 0...20, step: 0.5)
                    .accessibilityLabel("Pause Between Segments")
                    .accessibilityValue("\(storedDelay, specifier: "%.1f") seconds")
            }
            .padding(.horizontal)

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
                Button {
                    showTranslation.toggle()
                } label: {
                    Image(systemName: showTranslation ? "eye" : "eye.slash")
                }
                .accessibilityLabel(showTranslation ? "Hide translation" : "Show translation")
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    let next: AudioManager.PlaybackMode =
                        (audioManager.playbackMode == .target) ? .translation : .target
                    audioManager.playbackMode = next

                    // Immediately re-play current segment in chosen lane
                    if next == .target {
                        audioManager.playPortuguese(from: audioManager.currentIndex)
                    } else {
                        audioManager.playTranslation(resumeAfterTarget: false)
                    }
                } label: {
                    Image(systemName: audioManager.playbackMode == .target ? "character.book.closed" : "globe")
                }
                .accessibilityLabel(
                    audioManager.playbackMode == .target
                    ? "Switch to continuous translation playback"
                    : "Switch to continuous target playback"
                )
                .accessibilityHint("Changes which language auto-advance uses. One-off button still plays the opposite lane.")
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
        VStack(alignment: .leading, spacing: 5) {
            Text(segment.pt_text)
                .font(.headline)
                .foregroundColor(isPlaying ? .blue : .primary)
            if showTranslation {
                Text(segment.en_text)
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isPlaying ? Color.accentColor.opacity(0.18) : .clear)
        )
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
        let isAlt = group.id % 2 == 1
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill((isAlt ? Color.paraAlt : Color.paraBase).opacity(0.30))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.paraStroke.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 1, x: 0, y: 1)
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
    }
}

// MARK: - Colors

private extension Color {
    static var paraBase: Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor.secondarySystemBackground : UIColor.systemGray6
        })
    }
    static var paraAlt: Color { Color(UIColor { _ in UIColor.systemGray5 }) }
    static var paraStroke: Color { Color(UIColor.separator) }
}
