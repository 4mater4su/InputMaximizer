//
//  GeneratorView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 27.08.25.
//

import SwiftUI
import Foundation

// MARK: - Generator View

extension GeneratorService.Request.SpeechSpeed: Identifiable {
    public var id: String { rawValue }
}

typealias LanguageLevel = GeneratorService.Request.LanguageLevel

extension GeneratorService.Request.LanguageLevel: Identifiable {
    public var id: String { rawValue }
}

// MARK: - Persisted settings

private struct GeneratorSettings: Codable, Equatable {
    var mode: String
    var segmentation: String
    var lengthPresetRaw: Int
    var genLanguage: String
    var transLanguage: String
    var languageLevel: String
    var speechSpeed: String
}

private extension GeneratorSettings {
    static func fromViewState(
        mode: GeneratorView.GenerationMode,
        segmentation: GeneratorView.Segmentation,
        lengthPreset: GeneratorView.LengthPreset,
        genLanguage: String,
        transLanguage: String,
        languageLevel: LanguageLevel,
        speechSpeed: GeneratorView.SpeechSpeed
    ) -> GeneratorSettings {
        .init(
            mode: mode.rawValue,
            segmentation: segmentation.rawValue,
            lengthPresetRaw: lengthPreset.rawValue,
            genLanguage: genLanguage,
            transLanguage: transLanguage,
            languageLevel: languageLevel.rawValue,
            speechSpeed: speechSpeed.rawValue
        )
    }
}

struct GeneratorView: View {
    @EnvironmentObject private var purchases: PurchaseManager
    @State private var showBuyCredits = false
    
    @EnvironmentObject private var lessonStore: LessonStore
    @EnvironmentObject private var generator: GeneratorService
    @Environment(\.dismiss) private var dismiss

    // Persistence for aspect selections
    @AppStorage("styleTableJSON") private var styleTableJSON: Data = Data()
    @AppStorage("interestRowJSON") private var interestRowJSON: Data = Data()
    
    // Persist all generator knobs in one blob
    @AppStorage("generatorSettingsV1") private var generatorSettingsData: Data = Data()
    
    @AppStorage("generatorPromptV1") private var userPrompt: String = ""
    @AppStorage("generatorRandomTopicV1") private var randomTopic: String = ""

    // Persisted toggle for the Advanced dropdown
    @AppStorage("generatorAdvancedExpandedV1") private var advancedExpandedStore: Bool = false

    // Local binding that connects @AppStorage to the environment
    private var advancedExpandedBinding: Binding<Bool> {
        Binding(
            get: { advancedExpandedStore },
            set: { advancedExpandedStore = $0 }
        )
    }
    
    @Environment(\.horizontalSizeClass) private var hSize
    
    // MARK: - Length preset
    enum LengthPreset: Int, CaseIterable, Identifiable {
        case short, medium, long
        
        var id: Int { rawValue }
        
        var label: String {
            switch self {
            case .short:     return "Short"
            case .medium:    return "Medium"
            case .long:      return "Long"
            }
        }
        
        var words: Int {
            switch self {
            case .short:     return 100
            case .medium:    return 200
            case .long:      return 300
            }
        }
    }

    @State private var showSegmentationInfo = false
    @State private var showModeInfo = false
    
    @State private var lengthPreset: LengthPreset = .medium

    // MARK: - State
    // Present one sheet at a time, from the root (not on the Button).
    private enum ActiveSheet: Identifiable {
        case buyCredits
        var id: String { String(describing: self) }
    }

    @State private var activeSheet: ActiveSheet?

    @State private var serverBalance: Int = 0
    @State private var balanceError: String?

    private func refreshServerBalance() async {
        do {
            serverBalance = try await GeneratorService.fetchServerBalance()
            balanceError = nil
        } catch {
            balanceError = error.localizedDescription
        }
    }
    
    // Auto-filled from model output
    @State private var lessonID: String = "Lesson001"
    @State private var title: String = ""          // filled from generated PT title

    @State private var genLanguage: String = "Portuguese (Brazil)"
    @State private var transLanguage: String = "English"

    @State private var languageLevel: LanguageLevel = .B1

    // NEW: aspect states
    @State private var styleTable: AspectTable = .defaults()
    @State private var interestRow: AspectRow = AspectTable.defaultInterestsRow()
    @State private var showConfigurator = false

    // --- Add to GeneratorView state ---
    @State private var knownLessonIDs = Set<String>()
    @State private var newlyCreatedLesson: Lesson?     // lesson to show in the toast
    @State private var showToast: Bool = false
    @State private var navTargetLesson: Lesson?        // drives navigationDestination
    @State private var toastHideWork: DispatchWorkItem?
    
    @FocusState private var promptIsFocused: Bool

    private let supportedLanguages: [String] = [
        "Afrikaans","Arabic","Armenian","Azerbaijani","Belarusian","Bosnian","Bulgarian","Catalan","Chinese (Simplified)","Chinese (Traditional)","Croatian",
        "Czech","Danish","Dutch","English","Estonian","Finnish","French", "French (Canada)","Galician","German","Greek","Hebrew","Hindi",
        "Hungarian","Icelandic","Indonesian","Italian","Japanese","Kannada","Kazakh","Korean","Latvian","Lithuanian",
        "Macedonian","Malay","Marathi","Maori","Nepali","Norwegian","Persian","Polish","Portuguese (Portugal)","Portuguese (Brazil)","Romanian","Russian",
        "Serbian","Slovak","Slovenian","Spanish","Spanish (Latinoamérica)","Spanish (Mexico)","Swahili","Swedish","Tagalog","Tamil","Thai","Turkish","Ukrainian",
        "Urdu","Vietnamese","Welsh"
    ]

    // Modes
    enum GenerationMode: String, CaseIterable, Identifiable {
        case prompt = "Prompt"
        case random = "Random"
        var id: String { rawValue }
    }
    @State private var mode: GenerationMode = .prompt
    
    // MARK: - Segmentation
    enum Segmentation: String, CaseIterable, Identifiable {
        case sentences = "Sentences"
        case paragraphs = "Paragraphs"
        var id: String { rawValue }
    }
    @State private var segmentation: Segmentation = .sentences

    // Reuse the same enum so there’s no mismatch.
    typealias SpeechSpeed = GeneratorService.Request.SpeechSpeed

    @State private var speechSpeed: SpeechSpeed = .regular

    
    // MARK: - Prompt categories (I Ching trigrams)

    enum PromptCategory: String, CaseIterable, Identifiable {
        case all = "All"
        case heaven = "Heaven ☰"
        case earth = "Earth ☷"
        case thunder = "Thunder ☳"
        case wind = "Wind ☴"
        case water = "Water ☵"
        case fire = "Fire ☲"
        case mountain = "Mountain ☶"
        case lake = "Lake ☱"

        var id: String { rawValue }
    }

    @State private var selectedPromptCategory: PromptCategory = .all

    private let promptsByCategory: [PromptCategory: [String]] = [

        // --- Heaven (creativity, vision, force) ---
        .heaven: [
            "Story: Begin with pure sky and describe what takes form beneath it.",
            "Myth: Tell of the first being who shaped order from chaos.",
            "Dream-journey: You climb endlessly upward—what do you find at the top?",
            "Koan: What does pure beginning look like?",
            "Journal entry: Today I felt the weight of leading—here is what I noticed.",
            "Letter: Write to someone who waits for your decision.",
            "Lyric poem: Six bright lines, each opening a path.",
            "Riddle: I move without hands, I build without tools. What am I?"
        ],

        // --- Earth (receptivity, nurture, yielding) ---
        .earth: [
            "Story: Describe a time when gentleness redirected something vast.",
            "Myth: A goddess of soil teaches humans how to receive.",
            "Dream-journey: You lie down and the ground begins to speak.",
            "Koan: How can yielding be stronger than force?",
            "Journal entry: A quiet moment taught me more than achievement.",
            "Letter: Write thanks to a place that steadies you.",
            "Lyric poem: Dark soil waits—every seed a secret.",
            "Riddle: I open to all, yet hold everything within. Who am I?"
        ],

        // --- Thunder (shock, arousal, breakthrough) ---
        .thunder: [
            "Story: A sudden event shakes a village—how do they respond?",
            "Myth: Tell how thunder first taught humans fear and courage.",
            "Dream-journey: Lightning splits the sky; what do you see revealed?",
            "Koan: What remains after a shock?",
            "Journal entry: Today I broke apart something old and found…",
            "Letter: Write to someone you woke suddenly from sleep.",
            "Lyric poem: Flash—then silence. The heart remembers.",
            "Lecture/essay: Explain why disruption is necessary for renewal."
        ],

        // --- Wind/Wood (influence, growth, guidance) ---
        .wind: [
            "Story: A whisper changes the course of events.",
            "Myth: The tree-spirit teaches slow growth and quiet influence.",
            "Dream-journey: A breeze carries you through many doors.",
            "Koan: What subtle influence shifts a life?",
            "Journal entry: Today a small act shaped my whole mood.",
            "Letter: Write to someone you guided without them knowing.",
            "Lyric poem: Soft wind shapes stone in time.",
            "Riddle: I am invisible, yet I bend forests. What am I?"
        ],

        // --- Water (flow, danger, endurance) ---
        .water: [
            "Story: Describe a journey down a dangerous river.",
            "Myth: The river god teaches endurance through trial.",
            "Dream-journey: You sink into depth—what rhythm carries you through?",
            "Koan: How does retreat open a way?",
            "Journal entry: I learned strength today in yielding to current.",
            "Letter: Write instructions for someone crossing dark waters.",
            "Lyric poem: Endless depth, voice of persistence.",
            "Lecture/essay: Analyze how endurance forms through repeated trials."
        ],

        // --- Fire (clarity, passion, illumination) ---
        .fire: [
            "Story: A flame spreads insight through a gathering.",
            "Myth: The sun-bird carries light across the sky.",
            "Dream-journey: You walk into a hall of mirrors lit by fire.",
            "Koan: What clears the air like thunder?",
            "Journal entry: Today I saw what was hidden in plain sight.",
            "Letter: Write to someone you wish to enlighten.",
            "Lyric poem: Spark into blaze, truth unveiled.",
            "Riddle: I consume, yet I reveal. What am I?"
        ],

        // --- Mountain (stillness, limits, reflection) ---
        .mountain: [
            "Story: A wanderer finds wisdom in silence at the peak.",
            "Myth: The mountain spirit teaches the value of waiting.",
            "Dream-journey: You sit so still the world begins to move around you.",
            "Koan: What is learned in stillness?",
            "Journal entry: Today I chose not to move, and I discovered…",
            "Letter: Write to someone about the boundary you keep.",
            "Lyric poem: Stone, unmoved, yet full of time.",
            "Lecture/essay: Explain why limits are essential for growth."
        ],

        // --- Lake (joy, openness, exchange) ---
        .lake: [
            "Story: A festival by the lake unites strangers in laughter.",
            "Myth: A water spirit teaches joy as a sacred duty.",
            "Dream-journey: You walk into a circle of voices and songs.",
            "Koan: How does joy multiply when shared?",
            "Journal entry: Today I allowed delight to enter—this is what followed.",
            "Letter: Write to someone who brings you laughter.",
            "Lyric poem: Ripples carry laughter across water.",
            "Riddle: I reflect all, yet sing my own song. What am I?"
        ]
    ]

    // Flattened pool that respects the selected category (All = union of all)
    private var promptPool: [String] {
        if selectedPromptCategory == .all {
            promptsByCategory.values.flatMap { $0 }
        } else {
            promptsByCategory[selectedPromptCategory] ?? []
        }
    }

    // Pick a random prompt from the current category (or All), replacing any previous text.
    private func pickRandomPresetPrompt() {
        let pool = promptPool
        guard !pool.isEmpty else { return }
        var choice = pool.randomElement()!
        if pool.count > 1 {
            var attempts = 0
            while choice == userPrompt && attempts < 5 {
                choice = pool.randomElement()!
                attempts += 1
            }
        }
        userPrompt = choice
    }
    
    // MARK: - Random Variables Topic Create
    
    // Build a topic from selected aspects + one interest
    private func buildRandomTopic() -> String {
        let styleSel = styleTable.randomSelection()           // only active rows with at least one enabled option
        let styleSeed = styleTable.renderSeed(from: styleSel)

        let enabledInterests = interestRow.options.filter { $0.enabled }
        let interestSeed: String? = (interestRow.isActive && !enabledInterests.isEmpty)
            ? enabledInterests.randomElement()!.label
            : nil

        var parts: [String] = []
        if !styleSeed.isEmpty { parts.append(styleSeed) }
        if let interest = interestSeed { parts.append("\n\(interest)") }    //      if let interest = interestSeed { parts.append("Interest: \(interest)") }

        if parts.isEmpty { return "Interest: capoeira ao amanhecer" }
        return parts.joined(separator: "\n")   // <-- instead of " • "

    }

    // MARK: - Persistence helpers
    private func saveGeneratorSettings() {
        let payload = GeneratorSettings.fromViewState(
            mode: mode,
            segmentation: segmentation,
            lengthPreset: lengthPreset,
            genLanguage: genLanguage,
            transLanguage: transLanguage,
            languageLevel: languageLevel,
            speechSpeed: speechSpeed
        )
        if let data = try? JSONEncoder().encode(payload) {
            generatorSettingsData = data
        }
    }

    private func loadGeneratorSettings() {
        guard !generatorSettingsData.isEmpty,
              let payload = try? JSONDecoder().decode(GeneratorSettings.self, from: generatorSettingsData)
        else { return }

        // Mode
        if let m = GenerationMode(rawValue: payload.mode) { mode = m }

        // Segmentation
        if let s = Segmentation(rawValue: payload.segmentation) { segmentation = s }

        // Length preset (clamp to valid range)
        if let preset = LengthPreset(rawValue: payload.lengthPresetRaw) { lengthPreset = preset }

        // Languages (fallback to defaults if not supported)
        if supportedLanguages.contains(payload.genLanguage) { genLanguage = payload.genLanguage }
        if supportedLanguages.contains(payload.transLanguage) { transLanguage = payload.transLanguage }

        // CEFR & speech speed
        if let lvl = LanguageLevel(rawValue: payload.languageLevel) { languageLevel = lvl }
        if let spd = SpeechSpeed(rawValue: payload.speechSpeed) { speechSpeed = spd }
    }
    
    private func loadTable(from data: Data, fallback: AspectTable) -> AspectTable {
        guard !data.isEmpty, let decoded = try? JSONDecoder().decode(AspectTable.self, from: data) else {
            return fallback
        }
        return decoded
    }
    private func loadRow(from data: Data, fallback: AspectRow) -> AspectRow {
        guard !data.isEmpty, let decoded = try? JSONDecoder().decode(AspectRow.self, from: data) else {
            return fallback
        }
        return decoded
    }
    private func saveTable(_ table: AspectTable) -> Data {
        (try? JSONEncoder().encode(table)) ?? Data()
    }
    private func saveRow(_ row: AspectRow) -> Data {
        (try? JSONEncoder().encode(row)) ?? Data()
    }
    
    private var allSupportedLanguages: [String] { supportedLanguages }
    

    @ViewBuilder private func segmentationSection() -> some View {
        Section {
            let allSegs: [Segmentation] = Array(Segmentation.allCases)
            Picker("Segment by", selection: $segmentation) {
                ForEach(allSegs, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Segment by")
        } header: {
            HStack(spacing: 6) {
                Text("Segmentation")
                Button {
                    showSegmentationInfo = true
                } label: {
                    Image(systemName: "info.circle").imageScale(.medium)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About Segmentation")

                // iPad/regular width: anchored popover
                .modifier(RegularWidthPopover(isPresented: $showSegmentationInfo) {
                    SegmentationInfoCard()
                        .frame(maxWidth: 360)
                        .padding()
                })
                .sheet(isPresented: Binding(
                    get: { hSize == .compact && showSegmentationInfo },
                    set: { showSegmentationInfo = $0 }
                )) {
                    SegmentationInfoCard()
                        .presentationDetents([.fraction(0.4), .medium])
                        .presentationDragIndicator(.visible)
                }

                Spacer()
            }

        }
    }


    @ViewBuilder private func lengthSection() -> some View {
        Section {
            Picker("", selection: $lengthPreset) {
                ForEach(LengthPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } header: {
            HStack {
                Text("Length")
                Spacer()
                Text("~\(lengthPreset.words) words")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Approximately \(lengthPreset.words) words")
            }
        }
    }

    @ViewBuilder private func speechSpeedSection() -> some View {
        Section("Speech Speed") {
            Picker("Speech Speed", selection: $speechSpeed) {
                Text("Regular").tag(SpeechSpeed.regular)
                Text("Slow").tag(SpeechSpeed.slow)
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder private func levelSection() -> some View {
        Section("Language Level (CEFR)") {
            let levels: [LanguageLevel] = Array(LanguageLevel.allCases)
            Picker("Level", selection: $languageLevel) {
                ForEach(levels, id: \.self) { level in
                    Text(level.rawValue).tag(level)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder private func actionSection() -> some View {
        Section {
            Button {
                // No local debit here; proxy debits per request.
                if mode == .random && randomTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    randomTopic = buildRandomTopic()
                }

                let reqMode: GeneratorService.Request.GenerationMode = (mode == .prompt) ? .prompt : .random
                let reqSeg: GeneratorService.Request.Segmentation = (segmentation == .paragraphs) ? .paragraphs : .sentences

                let req = GeneratorService.Request(
                    languageLevel: languageLevel,
                    mode: reqMode,
                    userPrompt: userPrompt,
                    genLanguage: genLanguage,
                    transLanguage: transLanguage,
                    segmentation: reqSeg,
                    lengthWords: lengthPreset.words,
                    speechSpeed: speechSpeed,
                    userChosenTopic: randomTopic.isEmpty ? nil : randomTopic, // wrap to nil if empty
                    topicPool: nil
                )

                generator.start(req, lessonStore: lessonStore)
            } label: {
                HStack { if generator.isBusy { ProgressView() }
                    Text(generator.isBusy ? "Generating..." : "Generate Lesson")
                }
            }
            .disabled(generator.isBusy || (mode == .prompt && userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))


            Text("Credits: \(serverBalance)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            
            if !generator.status.isEmpty {
                Text(generator.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    
    // MARK: - UI
    var body: some View {
        
        // local alias so the body stays readable
        let advanced = advancedExpandedBinding
        
        Form {
            
            // --- Mode + Input as a single card ---
            Section {
                ModeCard(
                    mode: $mode,
                    userPrompt: $userPrompt,
                    selectedPromptCategory: $selectedPromptCategory,
                    randomTopic: $randomTopic,
                    showConfigurator: $showConfigurator,
                    pickRandomPresetPrompt: { pickRandomPresetPrompt() },
                    buildRandomTopic: { buildRandomTopic() },
                    promptFocus: $promptIsFocused,
                    showModeInfo: $showModeInfo
                )
            }
            .listRowInsets(EdgeInsets())            // edge-to-edge for the card
            .listRowBackground(Color.clear)
            
            // --- Advanced group as a single card ---
            Section {
                AdvancedCard(expanded: advanced, title: "Advanced options") {

                    AdvancedItem(
                        title: "Segmentation",
                        infoAction: { showSegmentationInfo = true }
                    ) {
                        Picker("Segment by", selection: $segmentation) {
                            ForEach(Array(Segmentation.allCases), id: \.self) { s in
                                Text(s.rawValue).tag(s)
                            }
                        }
                        .pickerStyle(.segmented)
                        .contentShape(Rectangle())     // keeps taps easy
                        .padding(.horizontal, 2)       // inside the segmented picker container
                        .accessibilityLabel("Segment by")
                    }

                    AdvancedSpacer()

                    AdvancedItem(
                        title: "Length",
                        trailing: "~\(lengthPreset.words) words"
                    ) {
                        Picker("", selection: $lengthPreset) {
                            ForEach(LengthPreset.allCases) { preset in
                                Text(preset.label).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                        .contentShape(Rectangle())     // keeps taps easy
                        .padding(.horizontal, 2)       // inside the segmented picker container
                        .labelsHidden()
                    }

                    AdvancedSpacer()

                    AdvancedItem(title: "Speech speed") {
                        Picker("Speech speed", selection: $speechSpeed) {
                            Text("Regular").tag(SpeechSpeed.regular)
                            Text("Slow").tag(SpeechSpeed.slow)
                        }
                        .pickerStyle(.segmented)
                        .contentShape(Rectangle())     // keeps taps easy
                        .padding(.horizontal, 2)       // inside the segmented picker container
                        .labelsHidden()
                    }

                    AdvancedSpacer()

                    AdvancedItem(title: "Language level (CEFR)") {
                        Picker("Level", selection: $languageLevel) {
                            ForEach(Array(LanguageLevel.allCases), id: \.self) { level in
                                Text(level.rawValue).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                        .contentShape(Rectangle())     // keeps taps easy
                        .padding(.horizontal, 2)       // inside the segmented picker container
                        .labelsHidden()
                    }
                }
                .modifier(RegularWidthPopover(isPresented: $showSegmentationInfo) {
                    SegmentationInfoCard()
                        .frame(maxWidth: 360)
                        .padding()
                })
                .sheet(isPresented: Binding(
                    get: { hSize == .compact && showSegmentationInfo },
                    set: { showSegmentationInfo = $0 }
                )) {
                    SegmentationInfoCard()
                        .presentationDetents([.fraction(0.4), .medium])
                        .presentationDragIndicator(.visible)
                }
            }
            .listRowInsets(EdgeInsets())               // removes the default insets
            .listRowBackground(Color.clear)            // removes the default grouped bg

            
            Section {
                LanguageCard(
                    genLanguage: $genLanguage,
                    transLanguage: $transLanguage,
                    allSupportedLanguages: allSupportedLanguages
                )

            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            
            actionSection()
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .background(
            TapToDismissKeyboard {
                if mode == .prompt { promptIsFocused = false }
            }
        )
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { promptIsFocused = false }
            }
        }
        // Remove this block OR replace with:
        .onChange(of: mode, initial: false) { _, _ in
            // keep keyboard hidden until user taps
            promptIsFocused = false
        }
        .onAppear {
            print("DeviceID.current = \(DeviceID.current)")
            // hydrate from persistence (or seed defaults)
            let loadedTable = loadTable(from: styleTableJSON, fallback: styleTable)
            let loadedRow = loadRow(from: interestRowJSON, fallback: interestRow)
            styleTable = loadedTable
            interestRow = loadedRow
            if styleTableJSON.isEmpty { styleTableJSON = saveTable(styleTable) }
            if interestRowJSON.isEmpty { interestRowJSON = saveRow(interestRow) }
            
            // Snapshot current lesson IDs so we can detect new ones later
            knownLessonIDs = Set(lessonStore.lessons.map { $0.id })
            
            // Load generator settings
            loadGeneratorSettings()
            promptIsFocused = false   // ensure keyboard is hidden on open
        }
        // Persist generator settings — keep one-liners
        .onChange(of: mode, initial: false)            { _, _ in saveGeneratorSettings() }
        .onChange(of: segmentation, initial: false)    { _, _ in saveGeneratorSettings() }
        .onChange(of: lengthPreset, initial: false)    { _, _ in saveGeneratorSettings() }
        .onChange(of: genLanguage, initial: false)     { _, _ in saveGeneratorSettings() }
        .onChange(of: transLanguage, initial: false)   { _, _ in saveGeneratorSettings() }
        .onChange(of: languageLevel, initial: false)   { _, _ in saveGeneratorSettings() }
        .onChange(of: speechSpeed, initial: false)     { _, _ in saveGeneratorSettings() }

        // Persist aspect table & interests
        .onChange(of: styleTable, initial: false) { _, newValue in
            styleTableJSON = saveTable(newValue)
        }
        .onChange(of: interestRow, initial: false) { _, newValue in
            interestRowJSON = saveRow(newValue)
        }

        // Detect newly added lessons to show the toast
        .onChange(of: lessonStore.lessons, initial: false) { _, newLessons in
            let added = newLessons.filter { !knownLessonIDs.contains($0.id) }
            if let lesson = added.last {
                newlyCreatedLesson = lesson
                toastHideWork?.cancel()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    showToast = true
                }
                let work = DispatchWorkItem {
                    withAnimation(.easeInOut) { showToast = false }
                }
                toastHideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
            }
            knownLessonIDs = Set(newLessons.map { $0.id })
        }
        
        // React to out-of-credits latch
        .onChange(of: generator.outOfCredits, initial: false) { _, needs in
            if needs {
                showBuyCredits = true
                generator.outOfCredits = false
            }
        }

        .navigationTitle("Generator")
        .listStyle(.insetGrouped)
        .environment(\.generatorAdvancedExpanded, advancedExpandedBinding)
        .sheet(isPresented: $showConfigurator) {
            AspectConfiguratorView(styleTable: $styleTable, interestRow: $interestRow)
                .onDisappear {
                    styleTableJSON = saveTable(styleTable)
                    interestRowJSON = saveRow(interestRow)
                }
        }
        // Destination for programmatic navigation from toast tap
        .navigationDestination(item: $navTargetLesson) { lesson in
            ContentView(selectedLesson: lesson, lessons: lessonStore.lessons)
        }
        // Overlay toast banner at top of GeneratorView
        .overlay(alignment: .top) {
            if showToast, let lesson = newlyCreatedLesson {
                ToastBanner(
                    message: "New lesson ready: \(lesson.title)",
                    isSuccess: true,
                    onTap: {
                        // Hide toast and navigate
                        toastHideWork?.cancel()
                        withAnimation(.easeInOut) { showToast = false }
                        navTargetLesson = lesson
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 6)
            }
        }
        .task {
            do {
                serverBalance = try await GeneratorService.fetchServerBalance()
            } catch {
                balanceError = error.localizedDescription
            }
        }

        .onReceive(NotificationCenter.default.publisher(for: .didPurchaseCredits)) { _ in
            Task {
                do { serverBalance = try await GeneratorService.fetchServerBalance() }
                catch { balanceError = error.localizedDescription }
            }
        }

        .sheet(isPresented: $showBuyCredits, onDismiss: {
            Task { await refreshServerBalance() }
        }) {
            NavigationStack {
                BuyCreditsView(presentation: .modal)
                    .environmentObject(purchases)
            }
        }

        // Refresh balance after a successful generation
        .onChange(of: generator.lastLessonID, initial: false) { _, _ in
            Task { await refreshServerBalance() }
        }


    }
}

// MARK: - Advanced options card

private struct AdvancedCard<Content: View>: View {
    @Binding var expanded: Bool
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                        .imageScale(.medium)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            // Divider between header and content
            if expanded {
                Divider()
                    .transition(.opacity)
            }

            // Body content
            if expanded {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            // Card background that adapts to light/dark
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .padding(.vertical, 6)
    }
}

// A lightweight inner group to give each advanced control its own mini-surface
private struct AdvancedItem<Content: View>: View {
    let title: String
    var trailing: String? = nil
    var infoAction: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let infoAction {
                    Button(action: infoAction) {
                        Image(systemName: "info.circle")
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About \(title)")
                }
            }

            content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.08), lineWidth: 1)
        )
    }
}

// A simple divider with extra breathing room between items
private struct AdvancedSpacer: View {
    var body: some View {
        Divider().opacity(0)      // invisible line
            .frame(height: 8)     // …acting as vertical spacer
    }
}


// MARK: - Mode + Input card

private struct ModeCard: View {
    @Binding var mode: GeneratorView.GenerationMode
    @Binding var userPrompt: String
    @Binding var selectedPromptCategory: GeneratorView.PromptCategory
    @Binding var randomTopic: String
    @Binding var showConfigurator: Bool
    var pickRandomPresetPrompt: () -> Void
    var buildRandomTopic: () -> String
    var promptFocus: FocusState<Bool>.Binding
    @Binding var showModeInfo: Bool

    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        // Outer card
        VStack(alignment: .leading, spacing: 20) {            // <<< more breathing room
            // Header
            HStack(spacing: 12) {
                Image(systemName: "square.and.pencil")
                Text("Mode").font(.headline)
                Spacer()
                Button { showModeInfo = true } label: {
                    Image(systemName: "info.circle").imageScale(.medium)
                }
                .buttonStyle(.plain)
                .modifier(RegularWidthPopover(isPresented: $showModeInfo) {
                    ModeInfoCard().frame(maxWidth: 360).padding()
                })
                .sheet(isPresented: Binding(
                    get: { hSize == .compact && showModeInfo },
                    set: { showModeInfo = $0 }
                )) {
                    ModeInfoCard()
                        .presentationDetents([.fraction(0.35), .medium])
                        .presentationDragIndicator(.visible)
                }
            }

            // Segmented control
            Picker("Generation Mode", selection: $mode) {
                Text(GeneratorView.GenerationMode.prompt.rawValue)
                    .tag(GeneratorView.GenerationMode.prompt)
                Text(GeneratorView.GenerationMode.random.rawValue)
                    .tag(GeneratorView.GenerationMode.random)
            }
            .pickerStyle(.segmented)

            Divider()                                       // <<< separates switch from content

            // Body switches by mode
            Group {
                if mode == .prompt {
                    // ---- PROMPT MODE ----
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Prompt")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        // Spacious text editor with soft background
                        TextEditor(text: $userPrompt)
                            .frame(minHeight: 140)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(uiColor: .systemGray6))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                            )
                            .focused(promptFocus)

                        HStack(spacing: 12) {
                            Button {
                                pickRandomPresetPrompt()
                            } label: {
                                Label("Random Prompt", systemImage: "die.face.5")
                            }
                            .buttonStyle(.bordered)

                            Spacer(minLength: 8)

                            Picker("", selection: $selectedPromptCategory) {
                                ForEach(GeneratorView.PromptCategory.allCases) { cat in
                                    Text(cat.rawValue).tag(cat)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        Text("Describe instructions, a theme, or paste a source text.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    // ---- RANDOM MODE ----
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Random Topic")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        // Render multi-line topic in a note-style box
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(randomTopic.split(whereSeparator: \.isNewline).map(String.init), id: \.self) {
                                Text($0).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(uiColor: .systemGray6))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                        )

                        HStack {
                            Button("Randomize") {
                                randomTopic = buildRandomTopic()
                            }
                            Spacer()
                            Button {
                                showConfigurator = true
                            } label: {
                                Label("Configure", systemImage: "slider.horizontal.3")
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 4)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(16)                                        // <<< generous inner padding
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .padding(.vertical, 6)
    }
}



private struct ModeInfoCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .imageScale(.large)
                Text("About Mode")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prompt")
                            .font(.subheadline.bold())
                        Text("You provide your own prompt or source text. Great for tailored lessons.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "text.cursor")
                        .font(.caption2)
                }

                Divider()

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Random")
                            .font(.subheadline.bold())
                        Text("The app generates a random topic based on your interests and style settings. Good for variety and surprise practice.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "die.face.5")
                        .font(.caption2)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(radius: 8, y: 4)
        )
    }
}


private struct SegmentationInfoCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "textformat")
                    .imageScale(.large)
                Text("About Segmentation")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sentences")
                            .font(.subheadline.bold())
                        Text("Splits the text into sentence-sized segments. Great for quicker call-and-response practice.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "circle.fill").font(.caption2) }

                Divider()

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Paragraphs")
                            .font(.subheadline.bold())
                        Text("Keeps multi-sentence blocks together for natural flow and context. Ideal for longer listening and shadowing.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "rectangle.3.offgrid").font(.caption2) }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(radius: 8, y: 4)
        )
    }
}

// MARK: - Languages card

private struct LanguageCard: View {
    @Binding var genLanguage: String
    @Binding var transLanguage: String
    let allSupportedLanguages: [String]

    var body: some View {
        VStack(spacing: 0) {
            // Header row with title + swap button
            HStack {
                Image(systemName: "globe")
                Text("Languages").font(.headline)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        swap(&genLanguage, &transLanguage)
                    }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Swap target and helper languages")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().opacity(0.15)

            // Compact rows
            VStack(spacing: 0) {
                // Target
                HStack {
                    Text("Target")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $genLanguage) {
                        ForEach(allSupportedLanguages, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Target language")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider().opacity(0.15)

                // Helper
                HStack {
                    Text("Helper")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $transLanguage) {
                        ForEach(allSupportedLanguages, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Helper language")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .padding(.vertical, 6)
        .onChange(of: genLanguage) { _, new in
            if new == transLanguage,
               let alt = allSupportedLanguages.first(where: { $0 != new }) {
                transLanguage = alt
            }
        }
    }
}



private struct RegularWidthPopover<PopupContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let popup: () -> PopupContent

    @Environment(\.horizontalSizeClass) private var hSize

    func body(content: Content) -> some View {
        content.popover(
            isPresented: Binding(
                get: { hSize != .compact && isPresented },
                set: { isPresented = $0 }
            ),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            popup()
        }
    }
}

// MARK: - Environment key for "Advanced options" expanded state

private struct GeneratorAdvancedExpandedKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    var generatorAdvancedExpanded: Binding<Bool> {
        get { self[GeneratorAdvancedExpandedKey.self] }
        set { self[GeneratorAdvancedExpandedKey.self] = newValue }
    }
}
