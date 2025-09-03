//
//  GeneratorView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 27.08.25.
//

import SwiftUI

struct GeneratorView: View {
    @EnvironmentObject private var lessonStore: LessonStore
    @EnvironmentObject private var generator: GeneratorService
    @Environment(\.dismiss) private var dismiss   // optional, if you want to auto-close the screen
    
    @AppStorage("styleMatrixJSON") private var styleMatrixJSON: Data = Data()
    @AppStorage("interestMatrixJSON") private var interestMatrixJSON: Data = Data()
    
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
    @State private var isBusy = false
    @State private var status = ""

    // Auto-filled from model output
    @State private var lessonID: String = "Lesson001"
    @State private var title: String = ""          // filled from generated PT title

    @State private var genLanguage: String = "Portuguese"
    @State private var transLanguage: String = "English"
    
    @State private var randomTopic: String?
    
    @State private var styleMatrix: SelectableMatrix = .defaultStyle()
    @State private var interestMatrix: SelectableMatrix = .defaultInterests()
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
    
    private func buildRandomTopic() -> String {
        let s = styleMatrix.randomCell()
        let i = interestMatrix.randomCell()
        guard let s, let i else { return "capoeira rodas ao amanhecer" }
        return "\(styleMatrix.label(for: s)) • \(interestMatrix.label(for: i))"
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
                    Text(randomTopic ?? "Tap Randomize to pick a topic from your matrices")
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
                    // ensure we always have a topic when random mode is active
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
                        topicPool: nil   // <- no longer used
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
        .navigationTitle("Generator")
        .listStyle(.insetGrouped)
        .sheet(isPresented: $showConfigurator) {
            MatrixConfiguratorView(styleMatrix: $styleMatrix, interestMatrix: $interestMatrix)
        }

    }
}
