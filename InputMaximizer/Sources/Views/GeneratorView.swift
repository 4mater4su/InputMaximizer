//
//  GeneratorView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 27.08.25.
//

import SwiftUI
import Foundation

// MARK: - Generator View

struct GeneratorView: View {
    @EnvironmentObject private var lessonStore: LessonStore
    @EnvironmentObject private var generator: GeneratorService
    @Environment(\.dismiss) private var dismiss

    // Persistence for aspect selections
    @AppStorage("styleTableJSON") private var styleTableJSON: Data = Data()
    @AppStorage("interestRowJSON") private var interestRowJSON: Data = Data()

    // MARK: - Length preset
    enum LengthPreset: Int, CaseIterable, Identifiable {
        case short, medium, long, veryLong
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .short: return "Short"
            case .medium: return "Medium"
            case .long: return "Long"
            case .veryLong: return "Very Long"
            }
        }
        var words: Int {
            switch self {
            case .short: return 100
            case .medium: return 300
            case .long: return 600
            case .veryLong: return 1000
            }
        }
    }
    @State private var lengthPreset: LengthPreset = .medium

    // MARK: - State
    @State private var apiKey: String = "" // store/retrieve from Keychain in real use

    // Auto-filled from model output
    @State private var lessonID: String = "Lesson001"
    @State private var title: String = ""          // filled from generated PT title

    @State private var genLanguage: String = "Portuguese"
    @State private var transLanguage: String = "English"

    @State private var randomTopic: String?

    // NEW: aspect states
    @State private var styleTable: AspectTable = .defaults()
    @State private var interestRow: AspectRow = AspectTable.defaultInterestsRow()
    @State private var showConfigurator = false

    @FocusState private var promptIsFocused: Bool

    private let supportedLanguages: [String] = [
        "Afrikaans","Arabic","Armenian","Azerbaijani","Belarusian","Bosnian","Bulgarian","Catalan","Chinese","Croatian",
        "Czech","Danish","Dutch","English","Estonian","Finnish","French","Galician","German","Greek","Hebrew","Hindi",
        "Hungarian","Icelandic","Indonesian","Italian","Japanese","Kannada","Kazakh","Korean","Latvian","Lithuanian",
        "Macedonian","Malay","Marathi","Maori","Nepali","Norwegian","Persian","Polish","Portuguese","Romanian","Russian",
        "Serbian","Slovak","Slovenian","Spanish","Swahili","Swedish","Tagalog","Tamil","Thai","Turkish","Ukrainian",
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

    // Build a topic from selected aspects + one interest
    private func buildRandomTopic() -> String {
        let styleSel = styleTable.randomSelection()
        let styleSeed = styleTable.renderSeed(from: styleSel)
        let enabledInterests = interestRow.options.filter { $0.enabled }
        let interestSeed = enabledInterests.randomElement()?.label ?? "capoeira ao amanhecer"
        return styleSeed.isEmpty ? "Interest: \(interestSeed)"
                                 : "\(styleSeed) • Interest: \(interestSeed)"
    }

    // MARK: - Persistence helpers
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

    // MARK: - UI
    var body: some View {
        Form {
            // OpenAI
            Section("OpenAI") {
                SecureField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            }

            // Mode
            Section("Mode") {
                Picker("Generation Mode", selection: $mode) {
                    ForEach(GenerationMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }

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

            // === Options split into three separate cards ===

            // 1) Segmentation card
            Section("Segmentation") {
                Picker("Segment by", selection: $segmentation) {
                    ForEach(Segmentation.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
            }

            // 2) Length card
            Section("Length") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Length")
                        Spacer()
                        Text("\(lengthPreset.label) · ~\(lengthPreset.words) words")
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(lengthPreset.rawValue) },
                            set: { lengthPreset = LengthPreset(rawValue: Int($0.rounded())) ?? .medium }
                        ),
                        in: 0...Double(LengthPreset.allCases.count - 1),
                        step: 1
                    )
                    HStack {
                        Text("Short")
                        Spacer()
                        Text("Very Long")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            // 3) Languages card
            Section("Languages") {
                Picker("Generate in", selection: $genLanguage) {
                    ForEach(supportedLanguages, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)

                Picker("Translate to", selection: $transLanguage) {
                    ForEach(supportedLanguages, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }

            // Action
            Section {
                Button {
                    if mode == .random && (randomTopic ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        randomTopic = buildRandomTopic()
                    }

                    let req = GeneratorService.Request(
                        apiKey: apiKey,
                        mode: (mode == .prompt ? .prompt : .random),
                        userPrompt: userPrompt,
                        genLanguage: genLanguage,
                        transLanguage: transLanguage,
                        segmentation: (segmentation == .paragraphs ? .paragraphs : .sentences),
                        lengthWords: lengthPreset.words,
                        userChosenTopic: randomTopic,
                        topicPool: nil
                    )
                    generator.start(req, lessonStore: lessonStore)
                } label: {
                    HStack {
                        if generator.isBusy { ProgressView() }
                        Text(generator.isBusy ? "Generating..." : "Generate Lesson")
                    }
                }
                .disabled(apiKey.isEmpty || generator.isBusy || (mode == .prompt && userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

                if !generator.status.isEmpty {
                    Text(generator.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
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
            // hydrate from persistence (or seed defaults)
            let loadedTable = loadTable(from: styleTableJSON, fallback: styleTable)
            let loadedRow = loadRow(from: interestRowJSON, fallback: interestRow)
            styleTable = loadedTable
            interestRow = loadedRow
            if styleTableJSON.isEmpty { styleTableJSON = saveTable(styleTable) }
            if interestRowJSON.isEmpty { interestRowJSON = saveRow(interestRow) }
        }
        .onChange(of: styleTable) { newValue in
            styleTableJSON = saveTable(newValue)
        }
        .onChange(of: interestRow) { newValue in
            interestRowJSON = saveRow(newValue)
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
    }
}

/// Simple wrap layout for chips using alignment guides
private struct WrapLayout<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { geo in
            self.generateContent(in: geo.size)
        }
        .frame(minHeight: 10)
    }

    private func generateContent(in size: CGSize) -> some View {
        var width: CGFloat = 0
        var height: CGFloat = 0
        return ZStack(alignment: .topLeading) {
            content
                .alignmentGuide(.leading) { d in
                    if (width + d.width) > size.width {
                        width = 0
                        height -= d.height
                    }
                    let result = width
                    width += d.width
                    return result
                }
                .alignmentGuide(.top) { d in
                    let result = height
                    return result
                }
        }
    }
}

