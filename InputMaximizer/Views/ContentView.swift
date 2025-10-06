//
//  ContentView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 01.09.25.
//

import SwiftUI
import NaturalLanguage

// Toolbar layout constants (file-level)
private let CHIP_GAP: CGFloat      = 6   // space between chips
private let CHIP_HPAD: CGFloat     = 8   // horizontal padding inside Chip
private let PILL_SPACING: CGFloat  = 4   // space between language pills
private let PILL_HPAD: CGFloat     = 5   // horizontal padding inside TinyPill

// Display-only segment that can represent a sub-sentence row
private struct DisplaySegment: Identifiable {
    let id: Int               // unique, stable for SwiftUI (originalID * 1000 + subIndex)
    let originalID: Int       // the original Segment.id (used for playback/highlight)
    let paragraph: Int
    let pt_text: String
    let en_text: String
}

// Keyword pair with paragraph information
private struct KeywordPair: Identifiable {
    let id = UUID()
    let target: String
    let translation: String
    let paragraph: Int
    let firstOccurrenceIndex: Int  // for ordering within paragraph
}

// Preference key for tracking scroll offset
private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// Data structure for paragraph visibility tracking
private struct ParagraphVisibilityData: Equatable {
    let paragraphIndex: Int
    let frame: CGRect
}

// Preference key for tracking paragraph visibility
private struct ParagraphVisibilityPreferenceKey: PreferenceKey {
    static var defaultValue: [ParagraphVisibilityData] = []
    static func reduce(value: inout [ParagraphVisibilityData], nextValue: () -> [ParagraphVisibilityData]) {
        value.append(contentsOf: nextValue())
    }
}

// Group model for paragraph rendering (now uses DisplaySegment)
private struct ParaGroup: Identifiable {
    let id: Int          // paragraph index
    let segments: [DisplaySegment]
}

private enum FontComfortMode: Int {
    case standard = 0
    case comfy = 1
    mutating func toggle() { self = (self == .standard) ? .comfy : .standard }
}

private enum TextDisplayMode: Int {
    case both = 0
    case targetOnly = 1
    case translationOnly = 2

    mutating func cycle() {
        self = TextDisplayMode(rawValue: (rawValue + 1) % 3) ?? .both
    }
}

// Measure just width to keep the preference stable.
private struct WidthPrefKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
private struct WidthReader: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { gp in
                Color.clear.preference(key: WidthPrefKey.self, value: gp.size.width)
            }
        )
    }
}
private extension View { func readWidth() -> some View { modifier(WidthReader()) } }

private struct Chip: View {
    let icon: String?
    let content: AnyView
    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon) }
            content
        }
        .font(.callout)
        .padding(.horizontal, CHIP_HPAD)   // ← was chipHorzPadding
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .frame(height: 32)
    }
}


// Stronger, tidy vertical divider that matches chip height
private struct ChipDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.6))
            .frame(width: 1, height: 32)
            .cornerRadius(0.5)
            .padding(.horizontal, 3)
            .accessibilityHidden(true)
    }
}

private struct TinyPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.monospaced().bold())
            .padding(.vertical, 2)
            .padding(.horizontal, PILL_HPAD)   // ← was pillHorzPadding
            .background(
                Capsule().stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            )
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}


private struct Pill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.vertical, 2).padding(.horizontal, 6)
            .background(
                Capsule().stroke(Color.hairline, lineWidth: 1)
            )
    }
}

private struct LangPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.vertical, 2).padding(.horizontal, 6)
            .background(Capsule().stroke(Color.hairline, lineWidth: 1))
            .contentTransition(.opacity)
            .accessibilityHidden(true)
    }
}

@MainActor
struct ContentView: View {
    @EnvironmentObject private var audioManager: AudioManager
    @Environment(\.dismiss) private var dismiss
    
    @EnvironmentObject private var generator: GeneratorService
    @EnvironmentObject private var store: LessonStore

    @State private var showKeywords = false
    @State private var loadedKeywordPairs: [KeywordPair] = []
    @State private var mostVisibleParagraph: Int = 0

    
    @State private var toastMessage: String? = nil
    @State private var toastIsSuccess: Bool = false
    @State private var toastAutoDismissTask: Task<Void, Never>? = nil

    private func showToast(message: String, success: Bool) {
        toastAutoDismissTask?.cancel()
        toastMessage = message
        toastIsSuccess = success
        toastAutoDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { withAnimation { toastMessage = nil } }
        }
    }
    
    @State private var showDelaySheet = false
    private let delayPresets: [Double] = [0, 0.5, 1.0, 1.5, 2.0, 3.0, 5.0]
    
    let lessons: [Lesson]
    @State private var currentLessonIndex: Int
    let selectedLesson: Lesson

    private var isTargetChinese: Bool {
        lessonLangs.targetCode.lowercased().hasPrefix("zh")
    }

    private var isTranslationChinese: Bool {
        lessonLangs.translationCode.lowercased().hasPrefix("zh")
    }
    
    @AppStorage("fontComfortMode") private var fontComfortModeRaw: Int = FontComfortMode.standard.rawValue
    private var fontComfortMode: FontComfortMode {
        get { FontComfortMode(rawValue: fontComfortModeRaw) ?? .standard }
        set { fontComfortModeRaw = newValue.rawValue }
    }
    
    @AppStorage("textDisplayMode") private var textDisplayModeRaw: Int = TextDisplayMode.both.rawValue
    private var textDisplayMode: TextDisplayMode {
        get { TextDisplayMode(rawValue: textDisplayModeRaw) ?? .both }
        set { textDisplayModeRaw = newValue.rawValue }
    }

    @AppStorage("segmentDelay") private var storedDelay: Double = 0.5

    // Local, non-playing transcript for whatever is *selected* in UI
    @State private var displaySegments: [DisplaySegment] = []
    
    @State private var lessonLangs: LessonLanguages

    // Turn sentence explosion on/off.
    // OFF now; flip to true when you want to experiment.
    private var shouldExplode: Bool { false }
    
    // MARK: - Init
    init(selectedLesson: Lesson, lessons: [Lesson]) {
        self.selectedLesson = selectedLesson
        self.lessons = lessons
        _currentLessonIndex = State(initialValue: lessons.firstIndex(of: selectedLesson) ?? 0)
        _lessonLangs = State(initialValue: LessonLanguageResolver.resolve(for: selectedLesson))
    }

    // MARK: - Keywords loader
    private func loadKeywordPairs(for folder: String) {
        let base = FileManager.docsLessonsDir.appendingPathComponent(folder, isDirectory: true)
        let lessonID = folder
        let url = base.appendingPathComponent("keywords_\(lessonID).txt")
        guard let data = try? Data(contentsOf: url),
              let txt = String(data: data, encoding: .utf8)
        else {
            loadedKeywordPairs = []
            return
        }

        // Parse keyword pairs from file
        var rawPairs: [(String, String)] = []
        for raw in txt.split(separator: "\n") {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            
            if let tab = line.firstIndex(of: "\t") {
                let a = String(line[..<tab]).trimmingCharacters(in: .whitespaces)
                let b = String(line[line.index(after: tab)...]).trimmingCharacters(in: .whitespaces)
                if !a.isEmpty, !b.isEmpty { rawPairs.append((a, b)) }
            } else if line.contains(" — ") {
                let parts = line.components(separatedBy: " — ")
                if parts.count >= 2 {
                    rawPairs.append((parts[0].trimmingCharacters(in: .whitespaces),
                                   parts[1].trimmingCharacters(in: .whitespaces)))
                }
            } else if line.contains(" - ") {
                let parts = line.components(separatedBy: " - ")
                if parts.count >= 2 {
                    rawPairs.append((parts[0].trimmingCharacters(in: .whitespaces),
                                   parts[1].trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        
        // Map keywords to paragraphs and order by first occurrence
        var keywordPairs: [KeywordPair] = []
        var unmappedKeywords: [(String, String)] = []
        
        for (target, translation) in rawPairs {
            // Find which paragraph this keyword first appears in
            var firstParagraph = 0
            var firstOccurrenceIndex = Int.max
            
            for (paraIndex, group) in groupedByParagraph.enumerated() {
                for (segIndex, segment) in group.segments.enumerated() {
                    // Check if keyword appears in this segment (case-insensitive)
                    if segment.pt_text.localizedCaseInsensitiveContains(target) {
                        if segIndex < firstOccurrenceIndex {
                            firstParagraph = paraIndex
                            firstOccurrenceIndex = segIndex
                        }
                        break // Found in this paragraph, move to next paragraph
                    }
                }
            }
            
            // If we found the keyword, add it with paragraph info
            if firstOccurrenceIndex != Int.max {
                keywordPairs.append(KeywordPair(
                    target: target,
                    translation: translation,
                    paragraph: firstParagraph,
                    firstOccurrenceIndex: firstOccurrenceIndex
                ))
            } else {
                // Store unmapped keywords for fallback
                unmappedKeywords.append((target, translation))
            }
        }
        
        // If we have mapped keywords, use them
        if !keywordPairs.isEmpty {
            // Sort by paragraph first, then by first occurrence within paragraph
            loadedKeywordPairs = keywordPairs.sorted { pair1, pair2 in
                if pair1.paragraph != pair2.paragraph {
                    return pair1.paragraph < pair2.paragraph
                }
                return pair1.firstOccurrenceIndex < pair2.firstOccurrenceIndex
            }
        } else {
            // Fallback: if no keywords could be mapped to paragraphs, 
            // create a single paragraph group with all keywords
            loadedKeywordPairs = unmappedKeywords.enumerated().map { (index, pair) in
                KeywordPair(
                    target: pair.0,
                    translation: pair.1,
                    paragraph: 0,
                    firstOccurrenceIndex: index
                )
            }
        }
    }

    
    // MARK: - Derived
    private var currentLesson: Lesson { lessons[currentLessonIndex] }
    
    // Update most visible paragraph based on scroll position
    private func updateMostVisibleParagraph(offset: CGFloat) {
        // Calculate which paragraph is most visible based on scroll offset
        // Use a more accurate calculation based on the actual content
        let scrollOffset = -offset
        
        // Find which paragraph group is most visible
        var bestParagraph = 0
        var maxVisibleArea: CGFloat = 0
        
        for (paragraphIndex, group) in groupedByParagraph.enumerated() {
            // Calculate approximate position of this paragraph
            let paragraphStartY = CGFloat(paragraphIndex) * 300 // Approximate paragraph height
            let paragraphEndY = paragraphStartY + 300
            
            // Calculate how much of this paragraph is visible
            let visibleStart = max(paragraphStartY, scrollOffset)
            let visibleEnd = min(paragraphEndY, scrollOffset + 800) // Approximate screen height
            let visibleArea = max(0, visibleEnd - visibleStart)
            
            if visibleArea > maxVisibleArea {
                maxVisibleArea = visibleArea
                bestParagraph = paragraphIndex
            }
        }
        
        if bestParagraph != mostVisibleParagraph {
            mostVisibleParagraph = bestParagraph
        }
    }

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
    
    private func makeDisplaySegments(
        from baseSegments: [Segment],
        explode: Bool
    ) -> [DisplaySegment] {

        // When segmentation is by paragraph, DO NOT explode.
        guard explode else {
            return baseSegments.map { seg in
                DisplaySegment(
                    id: seg.id * 1000,          // keep stable row id shape
                    originalID: seg.id,
                    paragraph: seg.paragraph,
                    pt_text: seg.pt_text,
                    en_text: seg.en_text
                )
            }
        }

        // Existing explosion logic (unchanged)
        var out: [DisplaySegment] = []
        let ptLocale = Locale(identifier: "pt")
        let enLocale = Locale(identifier: "en")

        for seg in baseSegments {
            let ptParts = splitSentences(seg.pt_text, locale: ptLocale)
            let enParts = splitSentences(seg.en_text, locale: enLocale)

            guard ptParts.count == enParts.count, ptParts.count > 1 else {
                out.append(DisplaySegment(
                    id: seg.id * 1000,
                    originalID: seg.id,
                    paragraph: seg.paragraph,
                    pt_text: seg.pt_text,
                    en_text: seg.en_text
                ))
                continue
            }

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

    // MARK: - Accessibility Strings (lighter for the type-checker)
    private var textModeAXLabel: String {
        switch textDisplayMode {
        case .both:            return "Show \(lessonLangs.targetShort) only"
        case .targetOnly:      return "Show \(lessonLangs.translationShort) only"
        case .translationOnly: return "Show both \(lessonLangs.targetShort) and \(lessonLangs.translationShort)"
        }
    }

    private var playbackAXLabel: String {
        switch audioManager.playbackMode {
        case .target:       return "Switch to \(lessonLangs.translationShort) playback"
        case .translation:  return "Switch to dual playback"
        case .both:         return "Switch to \(lessonLangs.targetShort) playback"
        }
    }
    
    private var playOppositeAXLabel: String {
        switch audioManager.playbackMode {
        case .target:       return "Play \(lessonLangs.translationName) once"
        case .translation:  return "Play \(lessonLangs.targetName) once"
        case .both:         return "Replay both languages for this segment"
        }
    }

    // MARK: - Chip Content Builders (type-erased to AnyView)
    private var textModeChipContent: AnyView {
        AnyView(
            ZStack {
                // reserve for two pills so width doesn’t jump
                HStack(spacing: PILL_SPACING) {
                    TinyPill(text: lessonLangs.targetShort)
                    TinyPill(text: lessonLangs.translationShort)
                }
                .opacity(0)

                switch textDisplayMode {
                case .both:
                    HStack(spacing: PILL_SPACING) {
                        TinyPill(text: lessonLangs.targetShort)
                        TinyPill(text: lessonLangs.translationShort)
                    }
                case .targetOnly:
                    TinyPill(text: lessonLangs.targetShort)
                case .translationOnly:
                    TinyPill(text: lessonLangs.translationShort)
                }
            }
        )
    }

    private var playbackChipContent: AnyView {
        AnyView(
            ZStack {
                // reserve for two pills
                HStack(spacing: PILL_SPACING) {
                    TinyPill(text: lessonLangs.targetShort)
                    TinyPill(text: lessonLangs.translationShort)
                }
                .opacity(0)

                switch audioManager.playbackMode {
                case .both:
                    HStack(spacing: PILL_SPACING) {
                        TinyPill(text: lessonLangs.targetShort)
                        TinyPill(text: lessonLangs.translationShort)
                    }
                case .target:
                    TinyPill(text: lessonLangs.targetShort)
                case .translation:
                    TinyPill(text: lessonLangs.translationShort)
                }
            }
        )
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

    private func secondsString(_ v: Double) -> String {
        let nf = NumberFormatter()
        nf.locale = Locale(identifier: "en_US_POSIX") // force dot decimal
        nf.minimumFractionDigits = 1
        nf.maximumFractionDigits = 1
        return (nf.string(from: v as NSNumber) ?? String(format: "%.1f", v)) + "s"
    }
    
    private let toolbarItemWidth: CGFloat = 118
    private let toolbarItemHeight: CGFloat = 28

    @State private var chipMeasuredWidth: CGFloat = 0        // replaces chipMeasuredSize


    @ViewBuilder
    private func TextModeToolbarLabel(mode: TextDisplayMode, langs: LessonLanguages) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "captions.bubble") // ← captions bubble for text mode

            ZStack {
                // Reserve max width (two pills baseline)
                HStack(spacing: 4) {
                    Pill(text: langs.targetShort)
                    Pill(text: langs.translationShort)
                }
                .opacity(0)

                switch mode {
                case .both:
                    HStack(spacing: 4) {
                        Pill(text: langs.targetShort)
                        Pill(text: langs.translationShort)
                    }
                case .targetOnly:
                    Pill(text: langs.targetShort)
                case .translationOnly:
                    Pill(text: langs.translationShort)
                }
            }
            .frame(height: toolbarItemHeight, alignment: .center)
        }
        .frame(width: toolbarItemWidth, alignment: .trailing)
    }

    @ViewBuilder
    private func PlaybackToolbarLabel(mode: AudioManager.PlaybackMode, langs: LessonLanguages) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.wave.2.fill") // ← always speaker with waves

            ZStack {
                // Reserve max width (two pills baseline)
                HStack(spacing: 4) {
                    Pill(text: langs.targetShort)
                    Pill(text: langs.translationShort)
                }
                .opacity(0)

                switch mode {
                case .both:
                    HStack(spacing: 4) {
                        Pill(text: langs.targetShort)
                        Pill(text: langs.translationShort)
                    }
                case .target:
                    Pill(text: langs.targetShort)
                case .translation:
                    Pill(text: langs.translationShort)
                }
            }
            .frame(height: toolbarItemHeight, alignment: .center)
        }
        .frame(width: toolbarItemWidth, alignment: .trailing)
    }
    
    @ViewBuilder
    private func DisplayModeIcon(_ mode: TextDisplayMode, langs: LessonLanguages) -> some View {
        switch mode {
        case .both:
            HStack(spacing: 4) { LangPill(text: langs.targetShort); LangPill(text: langs.translationShort) }
        case .targetOnly:
            LangPill(text: langs.targetShort)
        case .translationOnly:
            LangPill(text: langs.translationShort)
        }
    }

    @ViewBuilder
    private func PlaybackModeIcon(_ mode: AudioManager.PlaybackMode, langs: LessonLanguages) -> some View {
        switch mode {
        case .target:
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                LangPill(text: langs.targetShort)
            }
        case .translation:
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                LangPill(text: langs.translationShort)
            }
        case .both:
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.and.right.circle")
                LangPill(text: langs.targetShort)
                LangPill(text: langs.translationShort)
            }
        }
    }

    /// If you prefer the button to show the **next** mode instead of the current one:
    @ViewBuilder
    private func PlaybackNextIcon(current: AudioManager.PlaybackMode, langs: LessonLanguages) -> some View {
        let next: AudioManager.PlaybackMode = {
            switch current {
            case .target: return .translation
            case .translation: return .both
            case .both: return .target
            }
        }()
        PlaybackModeIcon(next, langs: langs)
    }
    
    //
    private var oppositeLangShort: String {
        switch audioManager.playbackMode {
        case .target:       return lessonLangs.translationShort
        case .translation:  return lessonLangs.targetShort
        case .both:         // dual → show first lane’s opposite
            return audioManager.isPlayingPT ? lessonLangs.translationShort : lessonLangs.targetShort
        }
    }

    private var oppositeLangFull: String {
        switch audioManager.playbackMode {
        case .target:       return lessonLangs.translationName
        case .translation:  return lessonLangs.targetName
        case .both:         return audioManager.isPlayingPT ? lessonLangs.translationName : lessonLangs.targetName
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
                    headerTitle: currentLesson.title,
                    onTap: { segment in
                        if !isViewingActiveLesson {
                            audioManager.loadLesson(
                                folderName: currentLesson.folderName,
                                lessonTitle: currentLesson.title
                            )
                        }
                        if let idx = audioManager.segments.firstIndex(where: { $0.id == segment.originalID }) {
                            audioManager.playInContinuousLane(from: idx)
                        }
                    },
                    onParagraphVisible: { paragraphIndex in
                        mostVisibleParagraph = paragraphIndex
                    },
                    fontComfortMode: fontComfortMode,
                    isTargetChinese: isTargetChinese,
                    isTranslationChinese: isTranslationChinese,
                    
                    onShowKeywords: {                       // NEW
                        loadKeywordPairs(for: currentLesson.folderName)
                        showKeywords = true
                    }
                )
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
                        .accessibilityLabel(audioManager.isPlayingPT ? "Pause" : "Play")

                        Button {
                            audioManager.playOppositeOnce()
                        } label: {
                            if audioManager.playbackMode == .both {
                                // Dual mode → back-and-forth icon only
                                Image(systemName: "arrow.left.and.right.circle")
                                    .imageScale(.large)
                            } else {
                                // Single mode → pill with opposite language short code
                                Text(oppositeLangShort)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                        .buttonStyle(MinimalIconButtonStyle())
                        .accessibilityLabel(playOppositeAXLabel)


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
        .gesture(
            DragGesture()
                .onEnded { value in
                    // Swipe from right to left (negative translation.width)
                    if value.translation.width < -50 && abs(value.translation.height) < 100 {
                        loadKeywordPairs(for: currentLesson.folderName)
                        showKeywords = true
                    }
                }
        )
        .coordinateSpace(name: "lessonScroll")
        .onAppear {
            let base = audioManager.previewSegments(for: currentLesson.folderName)
            displaySegments = makeDisplaySegments(from: base, explode: shouldExplode)
            lessonLangs = LessonLanguageResolver.resolve(for: currentLesson)
            
            audioManager.segmentDelay = storedDelay
            audioManager.requestNextLesson = { [weak audioManager] in
                DispatchQueue.main.async {
                    goToNextLessonAndPlay()
                    audioManager?.didFinishLesson = false
                }
            }
        }
        .onChange(of: generator.isBusy, initial: false) { _, isBusy in
            guard !isBusy else { return }
            let status = generator.status.lowercased()

            if let id = generator.lastLessonID,
               let lesson = store.lessons.first(where: { $0.id == id || $0.folderName == id }) {
                withAnimation(.spring()) {
                    showToast(message: "Lesson created: \(lesson.title). Tap to open.", success: true)
                }
            } else if status.hasPrefix("error") {
                withAnimation(.spring()) { showToast(message: "Generation failed. Tap to review.", success: false) }
            } else if status.contains("cancelled") {
                withAnimation(.spring()) { showToast(message: "Generation cancelled.", success: false) }
            }
        }
        
        .onChange(of: currentLessonIndex, initial: false) { _, _ in
            let base = audioManager.previewSegments(for: currentLesson.folderName)
            displaySegments = makeDisplaySegments(from: base, explode: shouldExplode)
            lessonLangs = LessonLanguageResolver.resolve(for: currentLesson)
        }

        .onChange(of: audioManager.currentLessonFolderName, initial: false) { _, newFolder in
            if let folder = newFolder,
               let idx = lessons.firstIndex(where: { $0.folderName == folder }) {
                currentLessonIndex = idx
                let base = audioManager.previewSegments(for: folder)
                displaySegments = makeDisplaySegments(from: base, explode: shouldExplode)
                lessonLangs = LessonLanguageResolver.resolve(for: currentLesson)
            }
        }

        .onChange(of: storedDelay, initial: false) { _, newValue in
            audioManager.segmentDelay = newValue
        }

        .overlay(alignment: .top) {
            if let message = toastMessage {
                ToastBanner(message: message, isSuccess: toastIsSuccess) {
                    if let id = generator.lastLessonID {
                        if let idxInLocal = lessons.firstIndex(where: { $0.id == id || $0.folderName == id }) {
                            // Open locally
                            currentLessonIndex = idxInLocal
                            let base = audioManager.previewSegments(for: lessons[idxInLocal].folderName)
                            displaySegments = makeDisplaySegments(from: base, explode: shouldExplode)
                            lessonLangs = LessonLanguageResolver.resolve(for: lessons[idxInLocal])
                        } else {
                            // Not in local list → tell Selection to open it, then leave this screen
                            NotificationCenter.default.post(name: .openGeneratedLesson,
                                                            object: nil,
                                                            userInfo: ["id": id])
                            dismiss()
                        }
                    }
                    withAnimation { toastMessage = nil }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        //.navigationBarBackButtonHidden(true)   // hide system back button

        // MARK: - Toolbar
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                ToolbarChips(
                    fontComfortModeRaw: $fontComfortModeRaw,
                    storedDelay: $storedDelay,
                    textDisplayModeRaw: $textDisplayModeRaw,
                    delayPresets: delayPresets,
                    secondsString: secondsString,
                    showDelaySheet: $showDelaySheet,
                    langs: lessonLangs,
                    measuredWidth: chipMeasuredWidth,
                    playbackAXLabel: playbackAXLabel,
                    textModeAXLabel: textModeAXLabel,
                    textModeChipContent: textModeChipContent,
                    playbackChipContent: playbackChipContent,
                    onTogglePlayback: {
                        let next: AudioManager.PlaybackMode = {
                            switch audioManager.playbackMode {
                            case .target: return .translation
                            case .translation: return .both
                            case .both: return .target
                            }
                        }()
                        audioManager.setPlaybackMode(next)
                        audioManager.playInContinuousLane(from: audioManager.currentIndex)
                    }
                )
                // keep your width measuring
                .onPreferenceChange(WidthPrefKey.self) { newMax in
                    Task { @MainActor in
                        let minW: CGFloat = 100  // slightly smaller so more likely to fit
                        let maxW: CGFloat = 150
                        let clamped = min(max(newMax, minW), maxW)
                        if abs(clamped - chipMeasuredWidth) > 0.5 {
                            chipMeasuredWidth = clamped
                        }
                    }
                }
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
        
        .sheet(isPresented: $showKeywords) {
            NavigationStack {
                KeywordsView(
                    titleTarget: lessonLangs.targetShort,
                    titleTrans: lessonLangs.translationShort,
                    pairs: loadedKeywordPairs,
                    targetParagraph: mostVisibleParagraph
                )
            }
        }
    }
}

private struct ToolbarChips: View {
    // bindings & values from ContentView
    @Binding var fontComfortModeRaw: Int
    @Binding var storedDelay: Double
    @Binding var textDisplayModeRaw: Int
    let delayPresets: [Double]
    let secondsString: (Double) -> String
    @Binding var showDelaySheet: Bool

    let langs: LessonLanguages
    let measuredWidth: CGFloat

    // playback bits
    let playbackAXLabel: String
    let textModeAXLabel: String
    let textModeChipContent: AnyView
    let playbackChipContent: AnyView
    let onTogglePlayback: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Wide — show all four chips
            HStack(spacing: CHIP_GAP) {
                ComfortToggleChip(mode: $fontComfortModeRaw, measuredWidth: measuredWidth)
                DelayMenuChip(delay: $storedDelay,
                              presets: delayPresets,
                              measuredWidth: measuredWidth,
                              secondsString: secondsString,
                              showSheet: $showDelaySheet)
                TextModeChip(textDisplayModeRaw: $textDisplayModeRaw,
                             langs: langs,
                             measuredWidth: measuredWidth,
                             content: textModeChipContent,
                             axLabel: textModeAXLabel)
                PlaybackChip(measuredWidth: measuredWidth,
                             content: playbackChipContent,
                             axLabel: playbackAXLabel,
                             onTap: onTogglePlayback)
            }

            // Medium — keep two most-used, put the rest in a menu
            HStack(spacing: CHIP_GAP) {
                TextModeChip(textDisplayModeRaw: $textDisplayModeRaw,
                             langs: langs,
                             measuredWidth: measuredWidth,
                             content: textModeChipContent,
                             axLabel: textModeAXLabel)
                PlaybackChip(measuredWidth: measuredWidth,
                             content: playbackChipContent,
                             axLabel: playbackAXLabel,
                             onTap: onTogglePlayback)

                // --- MEDIUM fallback
                Menu {
                    // TEXT APPEARANCE — simple button
                    let current = FontComfortMode(rawValue: fontComfortModeRaw) ?? .standard
                    Button(current == .standard ? "Enable Comfy text" : "Disable Comfy text") {
                        var m = current; m.toggle(); fontComfortModeRaw = m.rawValue
                    }

                    // PLAYBACK PAUSE — submenu
                    Menu {
                        Text("Set the pause between segments")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .disabled(true)

                        Picker("Pause", selection: $storedDelay) {
                            ForEach(delayPresets, id: \.self) { v in
                                Text(secondsString(v)).tag(v)
                            }
                        }
                        Button("Custom…") { showDelaySheet = true }
                    } label: {
                        Label("Playback pause", systemImage: "hourglass")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.large)
                }


            }

            // --- NARROW fallback (single Menu) ---
            Menu {
                // QUICK ACTIONS
                Section {
                    Button(textModeAXLabel) { textDisplayModeRaw = (textDisplayModeRaw + 1) % 3 }
                    Button(playbackAXLabel) { onTogglePlayback() }
                }

                // TEXT APPEARANCE — simple button
                let current = FontComfortMode(rawValue: fontComfortModeRaw) ?? .standard
                Button(current == .standard ? "Enable Comfy text" : "Disable Comfy text") {
                    var m = current; m.toggle(); fontComfortModeRaw = m.rawValue
                }

                // PLAYBACK PAUSE — submenu
                Menu {
                    Text("Set the pause between segments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .disabled(true)

                    Picker("Pause", selection: $storedDelay) {
                        ForEach(delayPresets, id: \.self) { v in
                            Text(secondsString(v)).tag(v)
                        }
                    }
                    Button("Custom…") { showDelaySheet = true }
                } label: {
                    Label("Playback pause", systemImage: "hourglass")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
            }


        }
    }
}


// MARK: - Toolbar Chip Subviews (keep compiler happy)

private struct ComfortToggleChip: View {
    @Binding var mode: Int
    let measuredWidth: CGFloat

    var body: some View {
        let current = FontComfortMode(rawValue: mode) ?? .standard
        Button {
            var m = current
            m.toggle()
            mode = m.rawValue
        } label: {
            Chip(
                icon: "textformat.size",
                content: AnyView(
                    ZStack {
                        Text("A+").font(.callout).opacity(0)
                        Text(current == .standard ? "A" : "A+")
                            .font(.callout)
                            .fontWeight(.semibold)
                    }
                )
            )
            .frame(width: measuredWidth)
            .readWidth()
        }
        .accessibilityLabel(current == .standard ? "Enable comfy text" : "Disable comfy text")
        .accessibilityHint("Toggles slightly larger and bolder text")
    }
}

private struct DelayMenuChip: View {
    @Binding var delay: Double
    let presets: [Double]
    let measuredWidth: CGFloat
    let secondsString: (Double) -> String
    @Binding var showSheet: Bool
    var body: some View {
        Menu {
            Text("Pause between segments (seconds)")
                .font(.caption).foregroundStyle(.secondary).disabled(true)
            Divider()
            Picker("Pause Between Segments", selection: $delay) {
                ForEach(presets, id: \.self) { v in
                    Text(secondsString(v)).tag(v)
                }
            }
            Button("Custom…") { showSheet = true }
        } label: {
            Chip(
                icon: "hourglass",
                content: AnyView(
                    Text(secondsString(delay))
                        .font(.callout.monospacedDigit())
                        .lineLimit(1)
                )
            )
            .frame(width: measuredWidth)
            .contentShape(Rectangle())
            .readWidth()
        }
    }
}

private struct TextModeChip: View {
    @Binding var textDisplayModeRaw: Int
    let langs: LessonLanguages
    let measuredWidth: CGFloat
    let content: AnyView       // prebuilt (to reduce generic depth)
    let axLabel: String        // prebuilt (to reduce closures)
    var body: some View {
        Button {
            textDisplayModeRaw = (textDisplayModeRaw + 1) % 3
        } label: {
            Chip(icon: "captions.bubble", content: content)
                .frame(width: measuredWidth)
                .readWidth()
        }
        .accessibilityLabel(axLabel)
        .accessibilityHint("Cycles between both, target-only, and translation-only.")
    }
}

private struct PlaybackChip: View {
    let measuredWidth: CGFloat
    let content: AnyView       // prebuilt
    let axLabel: String        // prebuilt
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            Chip(icon: "speaker.wave.2.fill", content: content)
                .frame(width: measuredWidth)
                .readWidth()
        }
        .accessibilityLabel(axLabel)
        .accessibilityHint("Cycles between target, translation, and dual playback modes.")
    }
}


// MARK: - Transcript List & Rows

private struct SegmentRow: View {
    let segment: DisplaySegment
    let isPlaying: Bool
    let displayMode: TextDisplayMode
    let rowID: String
    let onTap: () -> Void
    let fontComfortMode: FontComfortMode
    let isTargetChinese: Bool
    let isTranslationChinese: Bool

    var body: some View {
        // Typography rules:
        // - Standard: (your current)
        //     Dual -> PT: .headline(.regular), EN: .subheadline(.regular)
        //     Single -> .headline(.medium) with a touch more line spacing
        // - Comfy: slightly larger + slightly bolder
        //     Dual -> PT: .title3(.medium), EN: .body(.regular)
        //     Single -> .title3(.medium) with a touch more line spacing
        let isSingleLanguage = (displayMode != .both)
        let comfy = (fontComfortMode == .comfy)

        // TARGET (always primary in dual mode)
        let _: Font = {
            if comfy {
                return isTargetChinese ? .title : .title3   // zh → title1, en → title3
            }
            return .headline
        }()
        
        let primaryWeight: Font.Weight = {
            // Single-language (targetOnly / translationOnly) → lighter
            if isSingleLanguage { return .regular }
            // Dual mode: comfy gets a touch more weight, standard stays regular
            return comfy ? .medium : .regular
        }()


        // Secondary base for dual-mode translation
        let secondaryFont: Font = comfy ? .body : .subheadline
        let secondaryWeight: Font.Weight = .regular

        HStack(spacing: 0) {
            /*
            Rectangle()
                .fill(isPlaying ? Color.accentColor : .clear)
                .frame(width: 3)
                .cornerRadius(2)
            */

            VStack(alignment: .leading, spacing: 5) {

                // Target text
                if displayMode != .translationOnly {
                    let targetFont: Font = {
                        if comfy {
                            return isTargetChinese ? .title : .title3
                        }
                        return .headline
                    }()

                    Text(segment.pt_text)
                        .font(targetFont.weight(primaryWeight))
                        .foregroundColor(.primary)
                        .lineSpacing(isSingleLanguage ? (comfy ? 8 : 6) : 5)
                }

                // Translation text (promote when shown alone, but lighter weight)
                if displayMode != .targetOnly {
                    let isPrimaryTranslation = (displayMode == .translationOnly)

                    let translationFont: Font = {
                        if comfy {
                            return isTranslationChinese ? .title : .title3
                        }
                        return .headline
                    }()

                    Text(segment.en_text)
                        .font(
                            isPrimaryTranslation
                            ? translationFont.weight(primaryWeight)      // translation-only → bump if zh
                            : secondaryFont.weight(secondaryWeight)      // dual mode → secondary style
                        )
                        .foregroundStyle(isPrimaryTranslation ? .primary : .secondary)
                        .lineSpacing(isPrimaryTranslation ? (comfy ? 8 : 6) : 5)
                }
            }

        }
        .padding(.top, 5)
        .padding(.bottom, 5)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isPlaying ? Color.selectionAccent : Color.surface)
        /*
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.hairline.opacity(0.15), lineWidth: 1)
        )
         */
        .clipShape(RoundedRectangle(cornerRadius: 0, style: .continuous))
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
    let fontComfortMode: FontComfortMode
    let isTargetChinese: Bool
    let isTranslationChinese: Bool
    
    var body: some View {
        // padding values used for the colored strips
        let verticalPad: CGFloat = 10
        let isFirstPlaying = (group.segments.first?.originalID == playingSegmentID)
        let isLastPlaying  = (group.segments.last?.originalID  == playingSegmentID)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(group.segments) { seg in
                SegmentRow(
                    segment: seg,
                    isPlaying: playingSegmentID == seg.originalID,
                    displayMode: displayMode,
                    rowID: "\(folderName)#\(seg.originalID)",
                    onTap: { onTap(seg) },
                    fontComfortMode: fontComfortMode,
                    isTargetChinese: isTargetChinese,
                    isTranslationChinese: isTranslationChinese
                )
            }
        }
        .padding(.top, verticalPad)
        .padding(.bottom, verticalPad)
        .overlay(alignment: .top) {
            if isFirstPlaying {
                // Fill the top padding with the playing color
                Color.selectionAccent
                    .frame(height: verticalPad)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if isLastPlaying {
                // Fill the bottom padding with the playing color
                Color.selectionAccent
                    .frame(height: verticalPad)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

// --- Minimal keywords list view ---
private struct KeywordsView: View {
    let titleTarget: String    // e.g., "PT-BR"
    let titleTrans: String     // e.g., "EN"
    let pairs: [KeywordPair]
    let targetParagraph: Int   // paragraph to scroll to based on lesson view
    @Environment(\.dismiss) private var dismiss
    
    // Group keywords by paragraph
    private var groupedKeywords: [(Int, [KeywordPair])] {
        let groups = Dictionary(grouping: pairs, by: { $0.paragraph })
        return groups.sorted { $0.key < $1.key }
    }

    var body: some View {
        ScrollViewReader { proxy in
            keywordsList
                .onAppear {
                    // Scroll to the paragraph that corresponds to the most visible paragraph in the lesson
                    if let targetGroup = groupedKeywords.first(where: { $0.0 == targetParagraph }),
                       let firstKeyword = targetGroup.1.first {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo("keyword_\(firstKeyword.id)", anchor: UnitPoint.top)
                            }
                        }
                    }
                }
                .gesture(swipeToDismissGesture)
        }
    }
    
    // Extracted keywords list view
    @ViewBuilder
    private var keywordsList: some View {
        List {
            ForEach(groupedKeywords, id: \.0) { paragraphIndex, paragraphPairs in
                Section {
                    ForEach(paragraphPairs) { pair in
                        keywordRow(pair)
                    }
                } header: {
                    sectionHeader(for: paragraphIndex)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Keywords & Phrases")
    }
    
    // Extracted keyword row view
    @ViewBuilder
    private func keywordRow(_ pair: KeywordPair) -> some View {
        HStack(alignment: .top, spacing: 16) {
            // LEFT: target phrase
            Text(pair.target)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            // RIGHT: translation
            Text(pair.translation)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .id("keyword_\(pair.id)")
    }
    
    // Extracted section header view
    @ViewBuilder
    private func sectionHeader(for paragraphIndex: Int) -> some View {
        if paragraphIndex == 0 {
            // Show column headers only for the first paragraph
            HStack(spacing: 16) {
                Text(titleTarget).font(.caption.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(titleTrans).font(.caption.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // Show paragraph number for subsequent paragraphs
            Text("Paragraph \(paragraphIndex + 1)")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
    }
    
    // Extracted swipe gesture
    private var swipeToDismissGesture: some Gesture {
        DragGesture()
            .onEnded { value in
                // Swipe from left to right (positive translation.width)
                if value.translation.width > 50 && abs(value.translation.height) < 100 {
                    dismiss()
                }
            }
    }
}




// Old config with more space and line
/*

 private struct SegmentRow: View {
     let segment: DisplaySegment
     let isPlaying: Bool
     let displayMode: TextDisplayMode
     let rowID: String
     let onTap: () -> Void

     var body: some View {
         // In single-language modes, use a lighter (regular) weight.
         let isSingleLanguage = (displayMode != .both)
         let primaryWeight: Font.Weight = isSingleLanguage ? .regular : .semibold

         HStack(spacing: 10) {
             Rectangle()
                 .fill(isPlaying ? Color.accentColor : .clear)
                 .frame(width: 3)
                 .cornerRadius(2)

             VStack(alignment: .leading, spacing: 5) {

                 // Target text
                 if displayMode != .translationOnly {
                     Text(segment.pt_text)
                         .font(.headline.weight(primaryWeight))
                         .foregroundColor(.primary)
                         .lineSpacing(2)
                 }

                 // Translation text (promote when shown alone, but lighter weight)
                 if displayMode != .targetOnly {
                     let isPrimaryTranslation = (displayMode == .translationOnly)
                     Text(segment.en_text)
                         .font(isPrimaryTranslation
                               ? .headline.weight(primaryWeight)  // primary but lighter in single-language mode
                               : .subheadline)                     // secondary in dual mode
                         .foregroundStyle(isPrimaryTranslation ? .primary : .secondary)
                         .lineSpacing(2)
                 }
             }
         }
         .padding(10)
         .frame(maxWidth: .infinity, alignment: .leading)
         .background(isPlaying ? Color.selectionAccent : Color.surface)
         /*
         .overlay(
             RoundedRectangle(cornerRadius: 10, style: .continuous)
                 .stroke(Color.hairline.opacity(0.15), lineWidth: 1)
         )
          */
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

 */

private struct TranscriptList: View {
    let groups: [ParaGroup]
    let folderName: String
    let displayMode: TextDisplayMode
    let playingSegmentID: Int?
    let headerTitle: String?
    let onTap: (DisplaySegment) -> Void
    let onParagraphVisible: (Int) -> Void
    let fontComfortMode: FontComfortMode
    let isTargetChinese: Bool
    let isTranslationChinese: Bool
    let onShowKeywords: () -> Void

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
                        onTap: onTap,
                        fontComfortMode: fontComfortMode,
                        isTargetChinese: isTargetChinese,
                        isTranslationChinese: isTranslationChinese
                    )
                    .background(
                        // Track paragraph visibility
                        GeometryReader { geometry in
                            Color.clear
                                .preference(key: ParagraphVisibilityPreferenceKey.self, 
                                           value: [ParagraphVisibilityData(
                                               paragraphIndex: group.id,
                                               frame: geometry.frame(in: .named("scroll"))
                                           )])
                        }
                    )
                }
                
                // Footer button: open the keywords/phrases view
                Button {
                    onShowKeywords()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle.portrait")
                        Text("Show keywords & phrases")
                            .font(.callout.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.bottom, 10)
            }
            .id(folderName)           // reset layout identity on lesson change
            .padding(.horizontal)     // only horizontal padding
            .padding(.bottom, 26)     // leave air above bottom bar
        }
        .scrollIndicators(.hidden)
        .background(Color.appBackground)
        .coordinateSpace(name: "scroll")
        .onPreferenceChange(ParagraphVisibilityPreferenceKey.self) { visibilityData in
            // Find the most visible paragraph
            let visibleParagraphs = visibilityData.filter { data in
                let frame = data.frame
                // Check if paragraph is significantly visible (more than 50% in view)
                return frame.minY < 400 && frame.maxY > 200 // Approximate screen bounds
            }
            
            if let mostVisible = visibleParagraphs.max(by: { data1, data2 in
                // Choose the paragraph with the most visible area
                let area1 = min(data1.frame.maxY, 400) - max(data1.frame.minY, 200)
                let area2 = min(data2.frame.maxY, 400) - max(data2.frame.minY, 200)
                return area1 < area2
            }) {
                onParagraphVisible(mostVisible.paragraphIndex)
            }
        }
    }
}

private extension NLLanguage {
    init(_ identifier: String) {
        self = NLLanguage(rawValue: identifier)
    }
}
