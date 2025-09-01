//
//  GeneratorView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 27.08.25.
//

import SwiftUI

struct GeneratorView: View {
    @EnvironmentObject private var lessonStore: LessonStore
    @Environment(\.dismiss) private var dismiss   // optional, if you want to auto-close the screen
    
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
    @State private var sentencesPerSegment = 1
    @State private var isBusy = false
    @State private var status = ""

    // Auto-filled from model output
    @State private var lessonID: String = "Lesson001"
    @State private var title: String = ""          // filled from generated PT title

    @State private var genLanguage: String = "Portuguese"
    @State private var transLanguage: String = "English"
    
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
    
    // MARK: - Random topic source
    private let interests: [String] = [
        // (… keep your long list as-is …)
        "diários de viagem em cidades que lembram a Ba Sing Se"
    ]

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

            if mode == .prompt {
                Section("Prompt") {
                    TextEditor(text: $userPrompt)
                        .frame(minHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                        .padding(.vertical, 2)
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

                // Completely hide the stepper when using Paragraphs (as requested)
                if segmentation == .sentences {
                    Stepper(
                        "Sentences per segment: \(sentencesPerSegment)",
                        value: $sentencesPerSegment,
                        in: 1...3
                    )
                }
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
                    Task { await generate() }
                } label: {
                    HStack {
                        if isBusy { ProgressView() }
                        Text(isBusy ? "Generating..." : "Generate Lesson")
                    }
                }
                .disabled(apiKey.isEmpty || isBusy || (mode == .prompt && userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

                if !status.isEmpty {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Generator")
        .listStyle(.insetGrouped) // <- ensures separate white cards with system background between
    }

    // MARK: - Models
    struct Seg: Codable {
        let id: Int
        let pt_text: String
        let en_text: String
        let pt_file: String
        let en_file: String
        let paragraph: Int?
    }
    
    struct LessonEntry: Codable, Identifiable, Hashable {
        let id: String; let title: String; let folderName: String
    }

    // MARK: - Utils
    func slugify(_ input: String) -> String {
        // remove diacritics, keep alphanumerics, dash, underscore; replace spaces with underscores
        var s = input.folding(options: .diacriticInsensitive, locale: .current)
        s = s.replacingOccurrences(of: " ", with: "_")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        s = String(s.unicodeScalars.filter { allowed.contains($0) })
        if s.isEmpty { s = "Lesson_" + String(Int(Date().timeIntervalSince1970)) }
        return s
    }

    func save(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    
    /// If the title is ALL CAPS, convert it to Title Case (locale-aware).
    func normalizeTitleCaseIfAllCaps(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return t }
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let isAllCaps = !letters.isEmpty && letters.allSatisfy { CharacterSet.uppercaseLetters.contains($0) }
        return isAllCaps ? t.lowercased(with: .current).capitalized(with: .current) : t
    }

    // MARK: - LLM prompts
    func generateText(topic: String, targetLang: String, wordCount: Int) async throws -> String {
        let prompt = """
        Write a short, clear, factual text (~\(wordCount) words) in \(targetLang) about: \(topic).

        Rules:
        1) First line: TITLE only (no quotes).
        2) Blank line.
        3) Body in short sentences.
        4) Include exactly one plausible numeric detail in the body.
        """
        let body: [String:Any] = [
            "model": "gpt-5-nano",
            "messages": [
                ["role":"system","content":"Be clear, concrete, and factual."],
                ["role":"user","content": prompt]
            ],
        ]
        return try await chat(body: body)
    }

    func refinePrompt(_ raw: String, targetLang: String, wordCount: Int) async throws -> String {
        let meta = """
        You are a prompt refiner. Transform the user's instruction, input text, or theme into a clear, actionable writing brief that will produce a high-quality text.

        Keep the user's original intent, named entities, facts, references, and requested form (e.g., essay, article, story, poem) intact.
        Do NOT add new information; only clarify, structure, and make constraints explicit.

        Constraints to enforce:
        - Language: \(targetLang)
        - Target length: ≈ \(wordCount) words (flexible ±15%)

        Your refined prompt must:
        - State the primary purpose (inform / explain / explore / persuade / narrate / summarize / report).
        - Specify audience and voice/register if provided; otherwise insert placeholders like [audience] and [voice].
        - Define a simple paragraph structure with sentences which are not too long.
        - List must-cover points and requirements derived from the user’s material.

        Return ONLY the refined prompt text, nothing else.

        User instruction or material:
        \(raw)
        """
        
        let body: [String:Any] = [
            "model": "gpt-5-nano",
            "messages": [
                ["role":"system","content":"Refine prompts faithfully; elevate without drifting from user intent."],
                ["role":"user","content": meta]
            ],
        ]
        return try await chat(body: body)
    }
    
    func generateFromElevatedPrompt(_ elevated: String, targetLang: String, wordCount: Int) async throws -> String {
        let writerSystem = """
        You are a world-class writer. Follow the user's prompt meticulously.
        Write in \(targetLang). Aim for ~\(wordCount) words total.
        Output format:
        1) First line: short TITLE only (no quotes)
        2) Blank line
        3) Body text
        """
        let body: [String:Any] = [
            "model": "gpt-5-nano",
            "messages": [
                ["role":"system","content": writerSystem],
                ["role":"user","content": elevated]
            ],
        ]
        return try await chat(body: body)
    }

    func translate(_ text: String, to targetLang: String) async throws -> String {
        let body: [String:Any] = [
            "model":"gpt-5-nano",
            "messages":[
                ["role":"system","content":"Translate naturally and idiomatically."],
                ["role":"user","content":"Translate into \(targetLang):\n\n\(text)"]
            ],
        ]
        return try await chat(body: body)
    }

    func chat(body: [String:Any]) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let j = try JSONSerialization.jsonObject(with: data) as! [String:Any]
        let content = (((j["choices"] as? [[String:Any]])?.first?["message"] as? [String:Any])?["content"] as? String) ?? ""
        return content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    func tts(_ text:String, filename:String, folder:URL) async throws -> URL {
        let url = URL(string: "https://api.openai.com/v1/audio/speech")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String:Any] = [
            "model": "gpt-4o-mini-tts",
            "voice": "shimmer",
            "input": text,
            "format": "mp3"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let out = folder.appendingPathComponent(filename)
        try save(data, to: out)
        return out
    }

    func languageSlug(_ name: String) -> String {
        let s = slugify(name).lowercased()
        // keep it short but unique-ish
        return String(s.prefix(6))   // e.g., "portug", "englis", "deutsc"
    }
    
    // MARK: - Generate
    func generate() async {
        isBusy = true
        defer { isBusy = false }

        do {
            // 1) Build text (title + body) depending on mode
            let fullText: String
            switch mode {
            case .random:
                let topic = interests.randomElement() ?? "capoeira rodas ao amanhecer"
                status = "Generating… (Random)\nTopic: \(topic)\nLang: \(genLanguage) • ~\(lengthPreset.words) words"
                fullText = try await generateText(topic: topic, targetLang: genLanguage, wordCount: lengthPreset.words)
                 
            case .prompt:
                let cleaned = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { status = "Please enter a prompt."; return }
                status = "Elevating prompt…"
                let elevated = try await refinePrompt(cleaned, targetLang: genLanguage, wordCount: lengthPreset.words)
                #if DEBUG
                print("=== Elevated Prompt ===\n\(elevated)\n========================")
                #endif

                // For creative freedom:
                status = "Generating… (Prompt)\nLang: \(genLanguage) • ~\(lengthPreset.words) words"
                fullText = try await generateFromElevatedPrompt(elevated, targetLang: genLanguage, wordCount: lengthPreset.words)
            } // <-- CLOSES switch

            // 2) Parse title + body from the model output
            let lines = fullText.split(separator: "\n", omittingEmptySubsequences: false)
            let rawTitle = lines.first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "Sem Título"
            let generatedTitle = normalizeTitleCaseIfAllCaps(rawTitle)
            let bodyPrimary = lines.dropFirst().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            self.title = generatedTitle
            var folder = slugify(generatedTitle)

            let baseRoot = FileManager.docsLessonsDir
            var base = baseRoot.appendingPathComponent(folder, isDirectory: true)
            if (try? base.checkResourceIsReachable()) == true {
                folder += "_" + String(Int(Date().timeIntervalSince1970))
                base = baseRoot.appendingPathComponent(folder, isDirectory: true)
            }
            self.lessonID = folder

            status = "Translating to \(transLanguage)…\nTítulo: \(generatedTitle)"

            // Avoid translating into the same language
            let secondaryText: String
            if genLanguage.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                == transLanguage.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
                secondaryText = bodyPrimary
            } else {
                secondaryText = try await translate(bodyPrimary, to: transLanguage)
            }

            func paragraphs(_ txt: String) -> [String] {
                var s = txt.replacingOccurrences(of: "\r\n", with: "\n")
                           .replacingOccurrences(of: "\r", with: "\n")
                while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }

                return s
                    .components(separatedBy: "\n\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { p in
                        let trimmed = p
                        if trimmed.last.map({ ".!?".contains($0) }) == true { return trimmed }
                        return trimmed + "."
                    }
            }

            func sentences(_ txt: String) -> [String] {
                txt.split(whereSeparator: { ".!?".contains($0) })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { s in
                        if s.hasSuffix(".") || s.hasSuffix("!") || s.hasSuffix("?") { return s }
                        return s + "."
                    }
            }
            
            func sentencesPerParagraph(_ txt: String) -> [Int] {
                let ps = paragraphs(txt)
                return ps.map { sentences($0).count }
            }
            
            func chunk<T>(_ array: [T], size: Int) -> [[T]] {
                guard size > 0 else { return [] }
                return stride(from: 0, to: array.count, by: size).map { i in
                    Array(array[i..<min(i + size, array.count)])
                }
            }

            var segsPrimary: [String] = []
            var segsSecondary: [String] = []
            var segmentParagraphIndex: [Int] = []

            switch segmentation {
            case .sentences:
                let sentPrimary = sentences(bodyPrimary)
                let sentSecondary = sentences(secondaryText)

                let pChunks = chunk(sentPrimary, size: sentencesPerSegment).map { $0.joined(separator: " ") }
                let sChunks = chunk(sentSecondary, size: sentencesPerSegment).map { $0.joined(separator: " ") }
                let count = min(pChunks.count, sChunks.count)

                segsPrimary = Array(pChunks.prefix(count))
                segsSecondary = Array(sChunks.prefix(count))

                // Compute paragraph index for each segment
                let perPara = sentencesPerParagraph(bodyPrimary) // [3,2,4] etc.
                var sentToPara: [Int:Int] = [:]
                var running = 0
                for (pIdx, c) in perPara.enumerated() {
                    for s in running ..< running + c {
                        sentToPara[s] = pIdx
                    }
                    running += c
                }
                segmentParagraphIndex = (0..<count).map { seg in
                    let firstSentenceIndex = seg * sentencesPerSegment
                    return sentToPara[firstSentenceIndex] ?? 0
                }

                status = "Preparing audio… \(segsPrimary.count) segments × \(sentencesPerSegment) sentences"

            case .paragraphs:
                let pParas = paragraphs(bodyPrimary)
                let sParas = paragraphs(secondaryText)
                let count = min(pParas.count, sParas.count)

                segsPrimary = Array(pParas.prefix(count))
                segsSecondary = Array(sParas.prefix(count))

                // In paragraph mode each seg *is* a paragraph
                segmentParagraphIndex = Array(0..<count)

                status = "Preparing audio… \(segsPrimary.count) paragraph segments"
            }

            let count = min(segsPrimary.count, segsSecondary.count)
            let ptSegs = Array(segsPrimary.prefix(count))
            let enSegs = Array(segsSecondary.prefix(count))

            // 6) Create folder and TTS
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

            var rows: [Seg] = []

            let src = languageSlug(genLanguage)
            let dst = languageSlug(transLanguage)

            for i in 0..<count {
                status = "TTS \(i+1)/\(count) \(genLanguage)…"
                let ptFile = "\(src)_\(lessonID)_\(i+1).mp3"
                _ = try await tts(ptSegs[i], filename: ptFile, folder: base)

                status = "TTS \(i+1)/\(count) \(transLanguage)…"
                let enFile = "\(dst)_\(lessonID)_\(i+1).mp3"
                _ = try await tts(enSegs[i], filename: enFile, folder: base)

                rows.append(.init(
                    id: i+1,
                    pt_text: segsPrimary[i],
                    en_text: segsSecondary[i],
                    pt_file: ptFile,
                    en_file: enFile,
                    paragraph: segmentParagraphIndex[i]
                ))
            }

            // 7) segments_<lesson>.json
            let segJSON = base.appendingPathComponent("segments_\(lessonID).json")
            let segData = try JSONEncoder().encode(rows)
            try save(segData, to: segJSON)

            // 8) update lessons.json in Documents
            struct Manifest: Codable { var id:String; var title:String; var folderName:String }
            let manifestURL = FileManager.docsLessonsDir.appendingPathComponent("lessons.json")
            var list: [Manifest] = []
            if let d = try? Data(contentsOf: manifestURL) {
                list = (try? JSONDecoder().decode([Manifest].self, from: d)) ?? []
                list.removeAll { $0.id == lessonID }
            }
            list.append(.init(id: lessonID, title: title, folderName: lessonID))
            let out = try JSONEncoder().encode(list)
            try save(out, to: manifestURL)

            await MainActor.run {
                lessonStore.load()
                // dismiss()
            }

            status = "Done. Open the lesson list and pull to refresh."
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }
}

