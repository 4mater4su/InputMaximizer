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

    // MARK: - Length preset
    enum LengthPreset: Int, CaseIterable, Identifiable {
        case veryShort, short, medium, long, veryLong
        
        var id: Int { rawValue }
        
        var label: String {
            switch self {
            case .veryShort: return "Very Short"
            case .short:     return "Short"
            case .medium:    return "Medium"
            case .long:      return "Long"
            case .veryLong:  return "Very Long"
            }
        }
        
        var words: Int {
            switch self {
            case .veryShort: return 100   // ~100 words
            case .short:     return 200   // ~200 words
            case .medium:    return 300   // ~300 words
            case .long:      return 600   // ~600 words
            case .veryLong:  return 1000  // ~1000 words
            }
        }
    }

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
    
    @State private var randomTopic: String?

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
        case random = "Random"
        case prompt = "Prompt"
        var id: String { rawValue }
    }
    @State private var mode: GenerationMode = .random
    @State private var userPrompt: String = ""

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
        if let interest = interestSeed { parts.append("Interest: \(interest)") }

        if parts.isEmpty { return "Interest: capoeira ao amanhecer" } // final fallback
        return parts.joined(separator: " • ")
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

    private var lengthIndexBinding: Binding<Double> {
        Binding<Double>(
            get: { Double(lengthPreset.rawValue) },
            set: { newValue in
                if let v = LengthPreset(rawValue: Int(newValue.rounded())) {
                    lengthPreset = v
                }
            }
        )
    }
    
    private var lengthMaxIndex: Double {
        Double(LengthPreset.allCases.count - 1)
    }

    private var lengthTitleText: String {
        let label = lengthPreset.label
        let words = lengthPreset.words
        return "\(label) · ~\(words) words"
    }
    
    private var allSupportedLanguages: [String] { supportedLanguages }
    
    @ViewBuilder private func modeSection() -> some View {
        Section("Mode") {
            let allModes: [GenerationMode] = Array(GenerationMode.allCases)
            Picker("Generation Mode", selection: $mode) {
                ForEach(allModes, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder private func randomTopicSection() -> some View {
        if mode == .random {
            Section("Random Topic") {
                Text(randomTopic ?? "Tap Randomize to pick from your aspect table")
                    .font(.callout).foregroundStyle(.secondary)

                HStack {
                    Button("Randomize") { randomTopic = buildRandomTopic() }
                    Spacer(minLength: 12)
                    Button { showConfigurator = true } label: {
                        Label("Configure", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder private func promptSection() -> some View {
        if mode == .prompt {
            Section("Prompt") {
                TextEditor(text: $userPrompt)
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                    .padding(.vertical, 2)
                    .focused($promptIsFocused)
                Text("Describe instructions, a theme, or paste a source text.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func segmentationSection() -> some View {
        Section("Segmentation") {
            let allSegs: [Segmentation] = Array(Segmentation.allCases)
            Picker("Segment by", selection: $segmentation) {
                ForEach(allSegs, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder private func lengthSection() -> some View {
        Section("Length") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Length")
                    Spacer()
                    Text(lengthTitleText)
                        .foregroundStyle(.secondary)
                }
                Slider(value: lengthIndexBinding, in: 0...lengthMaxIndex, step: 1)
                HStack {
                    Text("Short")
                    Spacer()
                    Text("Very Long")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
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

    @ViewBuilder private func languagesSection() -> some View {
        Section("Languages") {
            Picker("Generate in", selection: $genLanguage) {
                ForEach(allSupportedLanguages, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)

            Picker("Translate to", selection: $transLanguage) {
                ForEach(allSupportedLanguages, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder private func actionSection() -> some View {
        Section {
            Button {
                // No local debit here; proxy debits per request.
                if mode == .random && (randomTopic ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                    userChosenTopic: randomTopic,
                    topicPool: nil
                )

                generator.start(req, lessonStore: lessonStore)
            } label: {
                HStack { if generator.isBusy { ProgressView() }
                    Text(generator.isBusy ? "Generating..." : "Generate Lesson")
                }
            }
            .disabled(generator.isBusy || (mode == .prompt && userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))


            Text("Credits (server): \(serverBalance)")
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
        Form {
                modeSection()
                randomTopicSection()
                promptSection()
                segmentationSection()
                lengthSection()
                speechSpeedSection()
                levelSection()
                languagesSection()
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
        .onChange(of: mode) { newValue in
            promptIsFocused = (newValue == .prompt)
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
        }
        .onChange(of: mode)            { _ in saveGeneratorSettings() }
        .onChange(of: segmentation)    { _ in saveGeneratorSettings() }
        .onChange(of: lengthPreset)    { _ in saveGeneratorSettings() }
        .onChange(of: genLanguage)     { _ in saveGeneratorSettings() }
        .onChange(of: transLanguage)   { _ in saveGeneratorSettings() }
        .onChange(of: languageLevel)   { _ in saveGeneratorSettings() }
        .onChange(of: speechSpeed)     { _ in saveGeneratorSettings() }

        .onChange(of: styleTable) { newValue in
            styleTableJSON = saveTable(newValue)
        }
        .onChange(of: interestRow) { newValue in
            interestRowJSON = saveRow(newValue)
        }
        // Detect when a new lesson is appended to the LessonStore
        .onChange(of: lessonStore.lessons) { newLessons in
            // Find lessons that are truly new (by id)
            let added = newLessons.filter { !knownLessonIDs.contains($0.id) }

            // Prefer the last added (typical "append" behavior)
            if let lesson = added.last {
                newlyCreatedLesson = lesson

                // Cancel any existing hide task before showing a new toast
                toastHideWork?.cancel()

                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    showToast = true
                }

                // Schedule a cancelable auto-hide
                let work = DispatchWorkItem {
                    withAnimation(.easeInOut) {
                        showToast = false
                    }
                }

                toastHideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
            }

            // Update the snapshot of known IDs
            knownLessonIDs = Set(newLessons.map { $0.id })
        }
        
        .onChange(of: generator.outOfCredits) { needs in
            if needs {
                showBuyCredits = true
                generator.outOfCredits = false  // reset latch
            }
        }

        .navigationTitle("Generator")
        .listStyle(.insetGrouped)
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

        .onChange(of: generator.lastLessonID) { _ in
            Task { await refreshServerBalance() }
        }


    }
}

