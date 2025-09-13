//
//  ContentView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 01.09.25.
//

import SwiftUI
import NaturalLanguage

// Display-only segment that can represent a sub-sentence row
private struct DisplaySegment: Identifiable {
    let id: Int               // unique, stable for SwiftUI (originalID * 1000 + subIndex)
    let originalID: Int       // the original Segment.id (used for playback/highlight)
    let paragraph: Int
    let pt_text: String
    let en_text: String
}

// Group model for paragraph rendering (now uses DisplaySegment)
private struct ParaGroup: Identifiable {
    let id: Int          // paragraph index
    let segments: [DisplaySegment]
}

private enum TextDisplayMode: Int {
    case both = 0
    case targetOnly = 1
    case translationOnly = 2

    mutating func cycle() {
        self = TextDisplayMode(rawValue: (rawValue + 1) % 3) ?? .both
    }
}

@MainActor
struct ContentView: View {
    @EnvironmentObject private var audioManager: AudioManager

    @State private var showDelaySheet = false
    private let delayPresets: [Double] = [0, 0.5, 1.0, 1.5, 2.0, 3.0, 5.0]
    
    let lessons: [Lesson]
    @State private var currentLessonIndex: Int
    let selectedLesson: Lesson

    @AppStorage("textDisplayMode") private var textDisplayModeRaw: Int = TextDisplayMode.both.rawValue
    private var textDisplayMode: TextDisplayMode {
        get { TextDisplayMode(rawValue: textDisplayModeRaw) ?? .both }
        set { textDisplayModeRaw = newValue.rawValue }
    }

    @AppStorage("segmentDelay") private var storedDelay: Double = 0.5

    // Local, non-playing transcript for whatever is *selected* in UI
    @State private var displaySegments: [DisplaySegment] = []

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
    
    private func explodeForDisplay(from baseSegments: [Segment]) -> [DisplaySegment] {
        var out: [DisplaySegment] = []
        let ptLocale = Locale(identifier: "pt")
        let enLocale = Locale(identifier: "en")

        for seg in baseSegments {
            let ptParts = splitSentences(seg.pt_text, locale: ptLocale)
            let enParts = splitSentences(seg.en_text, locale: enLocale)

            // If both are already single sentences or counts mismatch, keep as one row
            guard ptParts.count == enParts.count, ptParts.count > 1 else {
                out.append(DisplaySegment(
                    id: seg.id * 1000,              // stable “whole” row id
                    originalID: seg.id,
                    paragraph: seg.paragraph,
                    pt_text: seg.pt_text,
                    en_text: seg.en_text
                ))
                continue
            }

            // Create one DisplaySegment per sentence pair
            for (i, (pt, en)) in zip(ptParts, enParts).enumerated() {
                out.append(DisplaySegment(
                    id: seg.id * 1000 + i,
                    originalID: seg.id,
                    paragraph: seg.paragraph,
                    pt_text: pt,
                    en_text: en
                ))
            }
        }
        return out
    }
    
    private func splitSentences(_ text: String, locale: Locale) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.setLanguage(NLLanguage(locale.identifier))
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        return sentences
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

            // Transcript with auto-scroll and tap-to-start
            ScrollViewReader { proxy in
                TranscriptList(
                    groups: groupedByParagraph,
                    folderName: currentLesson.folderName,
                    displayMode: textDisplayMode,
                    playingSegmentID: playingSegmentID,
                    headerTitle: currentLesson.title
                ) { segment in
                    if !isViewingActiveLesson {
                        audioManager.loadLesson(
                            folderName: currentLesson.folderName,
                            lessonTitle: currentLesson.title
                        )
                    }
                    if let idx = audioManager.segments.firstIndex(where: { $0.id == segment.originalID }) {
                        audioManager.playInContinuousLane(from: idx)
                    }
                }
                .onChange(of: audioManager.currentIndex, initial: false) { _, _ in
                    guard let id = playingScrollID else { return }
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }

                .onChange(of: textDisplayModeRaw, initial: false) { _, _ in
                    guard let id = playingScrollID else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .scrollIndicators(.hidden)

            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    HStack(spacing: 60) {
                        Button {
                            audioManager.togglePlayPause()
                        } label: {
                            Image(systemName: audioManager.isPlaying ? "pause.fill" : "play.fill")
                                .imageScale(.large)
                        }
                        .buttonStyle(MinimalIconButtonStyle())
                        .accessibilityLabel(audioManager.isPlayingPT ? "Pause Portuguese" : "Play Portuguese")

                        Button {
                            audioManager.playOppositeOnce()
                        } label: {
                            Image(systemName: "globe").imageScale(.large)
                        }
                        .buttonStyle(MinimalIconButtonStyle())
                    }
                    .padding(.vertical, 14) // a bit more breathing room
                }
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(
                        colors: [
                            Color.appBackground.opacity(0.0), // fully transparent above
                            Color.appBackground.opacity(0.95) // nearly opaque behind controls
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .background(.ultraThinMaterial) // keep blur effect
                )
            }

        }
        .onAppear {
            let base = audioManager.previewSegments(for: currentLesson.folderName)
            displaySegments = explodeForDisplay(from: base)
            
            audioManager.segmentDelay = storedDelay
            audioManager.requestNextLesson = { [weak audioManager] in
                DispatchQueue.main.async {
                    goToNextLessonAndPlay()
                    audioManager?.didFinishLesson = false
                }
            }
        }
        .onChange(of: currentLessonIndex, initial: false) { _, _ in
            let base = audioManager.previewSegments(for: currentLesson.folderName)
            displaySegments = explodeForDisplay(from: base)
        }

        .onChange(of: audioManager.currentLessonFolderName, initial: false) { _, newFolder in
            if let folder = newFolder,
               let idx = lessons.firstIndex(where: { $0.folderName == folder }) {
                currentLessonIndex = idx
                let base = audioManager.previewSegments(for: folder)
                displaySegments = explodeForDisplay(from: base)
            }
        }

        .onChange(of: storedDelay, initial: false) { _, newValue in
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
                    Image(systemName: "hourglass") // or "timer"
                }
            }

            
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    textDisplayModeRaw = (textDisplayModeRaw + 1) % 3
                } label: {
                    Group {
                        switch textDisplayMode {
                        case .both:            Image(systemName: "eye")                       // both
                        case .targetOnly:      Image(systemName: "character.book.closed")     // target only
                        case .translationOnly: Image(systemName: "globe")                     // translation only
                        }
                    }
                }
                .accessibilityLabel({
                    switch textDisplayMode {
                    case .both:            return "Show target only"
                    case .targetOnly:      return "Show translation only"
                    case .translationOnly: return "Show target and translation"
                    }
                }())
                .accessibilityHint("Cycles between both, target-only, and translation-only.")
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
    let segment: DisplaySegment
    let isPlaying: Bool
    let displayMode: TextDisplayMode
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
                // Target text
                if displayMode != .translationOnly {
                    Text(segment.pt_text)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineSpacing(2) // optional readability tweak
                }

                // Translation text (promote to primary style when shown alone)
                if displayMode != .targetOnly {
                    let isPrimaryTranslation = (displayMode == .translationOnly)
                    Text(segment.en_text)
                        .font(isPrimaryTranslation ? .headline : .subheadline)
                        .foregroundStyle(isPrimaryTranslation ? .primary : .secondary)
                        .lineSpacing(2) // optional readability tweak
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)   // 👈 stretch row inside card
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
    let displayMode: TextDisplayMode
    let playingSegmentID: Int?
    let onTap: (DisplaySegment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(group.segments) { seg in
                SegmentRow(
                    segment: seg,
                    isPlaying: playingSegmentID == seg.originalID,
                    displayMode: displayMode,
                    rowID: "\(folderName)#\(seg.originalID)",
                    onTap: { onTap(seg) }
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)   // 👈 force full width
        .cardBackground() // unified card look
    }
}

private struct TranscriptList: View {
    let groups: [ParaGroup]
    let folderName: String
    let displayMode: TextDisplayMode
    let playingSegmentID: Int?
    let headerTitle: String?
    let onTap: (DisplaySegment) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let headerTitle {
                    Text(headerTitle)
                        .font(.largeTitle.bold())
                        .padding(.horizontal)
                        .padding(.top, 6)
                }

                ForEach(groups, id: \.id) { group in
                    ParagraphBox(
                        group: group,
                        folderName: folderName,
                        displayMode: displayMode,
                        playingSegmentID: playingSegmentID,
                        onTap: onTap
                    )
                }
            }
            .id(folderName)           // reset layout identity on lesson change
            .padding(.horizontal)     // only horizontal padding
            .padding(.bottom, 26)     // leave air above bottom bar
        }
        .scrollIndicators(.hidden)
        .background(Color.appBackground)
    }
}

private extension NLLanguage {
    init(_ identifier: String) {
        self = NLLanguage(rawValue: identifier)
    }
}
