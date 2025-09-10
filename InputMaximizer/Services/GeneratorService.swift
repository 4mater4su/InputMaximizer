//
//  GeneratorService.swift
//  InputMaximizer
//
//  Created by Robin Geske on 01.09.25.
//

import SwiftUI

/// A long-lived service that performs lesson generation even if views change.
/// Owns the async Task so navigation doesn't cancel it.
@MainActor
final class GeneratorService: ObservableObject {

    // Public progress for UI
    @Published var isBusy = false
    @Published var status = ""
    @Published var lastLessonID: String?

    // Current running task
    private var currentTask: Task<Void, Never>?
    private let background = BackgroundActivityManager()

    struct Request: Equatable, Sendable {
        enum GenerationMode: String { case random, prompt }
        enum Segmentation: String { case sentences, paragraphs }
        enum SpeechSpeed: String { case regular, slow }
        enum LanguageLevel: String, Codable, CaseIterable { case A1, A2, B1, B2, C1, C2 }
        
        var languageLevel: LanguageLevel = .B1   // sensible default

        var apiKey: String
        var mode: GenerationMode
        var userPrompt: String

        var genLanguage: String
        var transLanguage: String

        var segmentation: Segmentation
        var lengthWords: Int
        var speechSpeed: SpeechSpeed = .regular
        
        // Random topic inputs from the UI
        var userChosenTopic: String? = nil         // if user pressed “Randomize” we pass it here
        var topicPool: [String]? = nil             // the interests array to sample from

    }

    /// Start a generation job. If one is running, ignore.
    func start(_ req: Request, lessonStore: LessonStore) {
        guard !isBusy else { return }
        guard !req.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isBusy = true
        status = "Starting…"
        lastLessonID = nil

        // Hold a background task token so iOS gives us time if the app goes to background.
        let bgToken = background.begin()

        // Detach so it outlives the view that triggered it.
        currentTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let lessonID = try await Self.runGeneration(req: req) { [weak self] message in
                    await MainActor.run { self?.status = message }
                }

                await MainActor.run {
                    self.lastLessonID = lessonID
                    self.status = "Done. Open the lesson list and pull to refresh."
                    self.isBusy = false
                    lessonStore.load() // refresh visible lists anywhere
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.status = "Cancelled."
                    self.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self.status = "Error: \(error.localizedDescription)"
                    self.isBusy = false
                }
            }

            self.background.end(bgToken)
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isBusy = false
        status = "Cancelled."
    }
}

// MARK: - The worker (non-UI code)

private extension GeneratorService {
    
    /// Very lightweight language check. You can expand this list anytime.
    static func isCJKLanguage(_ name: String) -> Bool {
        let s = name.lowercased()
        return s.contains("chinese") || s.contains("japanese") || s.contains("korean")
    }

    // Add this helper:
    static func isChineseLanguage(_ name: String) -> Bool {
        let s = name.lowercased()
        return s.contains("chinese")
            || s.contains("mandarin")
            || s.contains("中文")
            || s.contains("简体")
            || s.contains("繁體")
    }
    
    /// A language-aware CEFR guidance string that avoids Euro-centric cues for CJK.
    static func cefrGuidance(_ level: Request.LanguageLevel, targetLanguage: String) -> String {
        if isCJKLanguage(targetLanguage) {
            // CJK baseline (language-agnostic)
            switch level {
            case .A1:
                return """
                Use very simple, short sentences. Use the most common everyday vocabulary. Avoid idioms, figurative language, and complex grammar or nested clauses. Prefer basic statements and simple connectors (e.g., and, but, because).
                """
            case .A2:
                return """
                Use short, clear sentences. Everyday vocabulary with simple topic terms. Use basic connectors (and, but, because, so). Avoid rare expressions and advanced patterns. Keep morphology/particles/markers simple and consistent.
                """
            case .B1:
                var text = """
                Use clear sentences of moderate length. Employ common connectors and limited subordination. Allow some topic-specific vocabulary, but keep explanations concrete. Maintain straightforward clause order and avoid heavy embedding.
                """
                if isChineseLanguage(targetLanguage) {
                    text += """
                    
                    Note for Chinese: Use aspect/phase markers naturally and only when needed (e.g., 了 for completed actions, 过 for past experiences, 在/正在 for ongoing actions). Avoid over-marking in simple statements.
                    """
                }
                return text
            case .B2:
                var text = """
                Use varied sentence patterns with natural connectors and some subordinate clauses. Introduce more abstract vocabulary and explanations while keeping clarity. Use cohesive devices appropriately without overcomplicating.
                """
                if isChineseLanguage(targetLanguage) {
                    text += """
                    
                    Note for Chinese: Keep aspect usage idiomatic (了 for completion/result, 过 for experience, 在/正在 for progressive). Prefer natural distribution over mechanical repetition; don’t add markers where context suffices.
                    """
                }
                return text
            case .C1:
                var text = """
                Use complex structures and nuanced vocabulary with precise register. Employ idiomatic or set phrases when natural. Vary clause patterns and show clear cohesion across paragraphs while maintaining natural flow.
                """
                if isChineseLanguage(targetLanguage) {
                    text += """
                    
                    Note for Chinese: Use aspect markers with native-like subtlety; let discourse context license omission or inclusion. Balance 了/过/在(正在) with resultative complements and discourse particles as appropriate.
                    """
                }
                return text
            case .C2:
                var text = """
                Use native-like, sophisticated language with precise nuance and flexible syntax. Idiomatic usage, advanced cohesion devices, and subtle register shifts are appropriate. Keep discourse highly natural.
                """
                if isChineseLanguage(targetLanguage) {
                    text += """
                    
                    Note for Chinese: Demonstrate idiomatic control of aspect and Aktionsart (e.g., 了/过/在(正在)) with pragmatically appropriate omission, including sensitivity to information structure and discourse flow.
                    """
                }
                return text
            }
        } else {
            // General (non-CJK) guidance
            switch level {
            case .A1:
                return """
                Use very simple, short sentences. Stick to the most common 1000 words. Avoid idioms, figurative language, and complex tenses or nested clauses.
                """
            case .A2:
                return """
                Use short, clear sentences. Everyday vocabulary. Simple connectors (and, but, because). Avoid uncommon expressions and advanced grammar. Limit subordinate clauses.
                """
            case .B1:
                return """
                Use clear sentences of moderate length. Common connectors (but, because, so). Limited subordinate clauses. Everyday and some topic vocabulary. Keep explanations concrete.
                """
            case .B2:
                return """
                Use varied sentence patterns with natural connectors and some subordinate clauses. Introduce abstract vocabulary but keep clarity high. Ensure good cohesion.
                """
            case .C1:
                return """
                Use complex structures and nuanced vocabulary, with precise register and hedging. Vary clause patterns while maintaining coherence and precision.
                """
            case .C2:
                return """
                Use highly natural, sophisticated language with precise nuance. Flexible syntax, idiomatic usage, and advanced cohesion devices appropriate for native-like mastery.
                """
            }
        }
    }


    
    // You can keep these helpers here, or move to a separate utility file.
    static func slugify(_ input: String) -> String {
        var s = input.folding(options: .diacriticInsensitive, locale: .current)
        s = s.replacingOccurrences(of: " ", with: "_")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        s = String(s.unicodeScalars.filter { allowed.contains($0) })
        if s.isEmpty { s = "Lesson_" + String(Int(Date().timeIntervalSince1970)) }
        return s
    }

    static func save(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func normalizeTitleCaseIfAllCaps(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return t }
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let isAllCaps = !letters.isEmpty && letters.allSatisfy { CharacterSet.uppercaseLetters.contains($0) }
        return isAllCaps ? t.lowercased(with: .current).capitalized(with: .current) : t
    }

    static func languageSlug(_ name: String) -> String {
        let s = slugify(name).lowercased()
        return String(s.prefix(6))
    }

    // MARK: - Networking (same logic you already have, but parameterized)
    static func chat(apiKey: String, body: [String:Any]) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let j = try JSONSerialization.jsonObject(with: data) as! [String:Any]
        let content = (((j["choices"] as? [[String:Any]])?.first?["message"] as? [String:Any])?["content"] as? String) ?? ""
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tts(
        apiKey: String,
        text: String,
        filename: String,
        folder: URL,
        language: String,
        speed: Request.SpeechSpeed
    ) async throws -> URL {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        req.httpMethod = "POST"
        req.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let instruction: String
        switch speed {
        case .regular:
            instruction = "Speak naturally in \(language)."
        case .slow:
            instruction = "Speak naturally and slowly in \(language)."
        }

        let body: [String:Any] = [
            "model": "gpt-4o-mini-tts",
            "voice": "shimmer",
            "input": text,
            "format": "mp3",
            "instructions": instruction
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        let out = folder.appendingPathComponent(filename)
        try save(data, to: out)
        return out
    }

    // MARK: - The whole pipeline, headless
    /// Returns the `lessonID` written to disk.
    static func runGeneration(
        req: GeneratorService.Request,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> String {

        func refinePrompt(_ raw: String, targetLang: String, wordCount: Int) async throws -> String {
            let meta = """
            You are a prompt refiner. Transform the user's instruction, input text, or theme into a clear, actionable writing brief that will produce a high-quality text.

            Keep the user's original intent, named entities, facts, references, and requested form (e.g., essay, article, story, poem) intact.

            Constraints to enforce:
            - Language: \(targetLang)
            - Target length: ≈ \(wordCount) words (flexible ±15%)
            - CEFR level: \(req.languageLevel.rawValue)

            Your refined prompt must:
            - State the primary purpose (inform / explain / explore / persuade / narrate / summarize / report).
            - Specify audience and voice/register if provided.
            - Define a simple paragraph structure with sentences which are not too long.
            - Include explicit CEFR guidance that the writer should obey:
            \(cefrGuidance(req.languageLevel, targetLanguage: targetLang))

            Return ONLY the refined prompt text, nothing else.

            User instruction or material:
            \(raw)
            """
            
            let body: [String:Any] = [
                "model": "gpt-5",
                "messages": [
                    ["role":"system","content":"Refine prompts faithfully; elevate without drifting from user intent."],
                    ["role":"user","content": meta]
                ],
            ]
            return try await chat(apiKey: req.apiKey, body: body)
        }


        func generateFromElevatedPrompt(_ elevated: String, targetLang: String, wordCount: Int) async throws -> String {
            let system = """
            You are a world-class writer. Follow the user's prompt meticulously.
            Write in \(targetLang). Aim for ~\(wordCount) words total.
            Write at CEFR level \(req.languageLevel.rawValue).
            Follow these constraints:
            \(cefrGuidance(req.languageLevel, targetLanguage: targetLang))
            Output format:
            1) First line: short TITLE only (no quotes)
            2) Blank line
            3) Body text
            4) Only use a full stops '.' to indicate the end of a sentence.

            """

            let body: [String:Any] = [
                "model": "gpt-5",
                "messages": [
                    ["role":"system","content": system],
                    ["role":"user","content": elevated]
                ],
            ]
            return try await chat(apiKey: req.apiKey, body: body)
        }

        func translate(_ text: String, to targetLang: String) async throws -> String {
            let body: [String:Any] = [
                "model":"gpt-5",
                "messages":[
                    ["role":"system","content":"Translate naturally and idiomatically."],
                    ["role":"user","content":"Translate into \(targetLang):\n\n\(text)"]
                ],
            ]
            return try await chat(apiKey: req.apiKey, body: body)
        }

        // ---- Generate text ----
        let fullText: String
        switch req.mode {
        case .random:
            // Pick a topic:
            // 1) use userChosenTopic if provided and non-empty
            // 2) else pick from topicPool if available
            // 3) else use a safe default
            let topic: String = {
                if let t = req.userChosenTopic?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    return t
                }
                if let pool = req.topicPool, let pick = pool.randomElement() {
                    return pick
                }
                return "capoeira rodas ao amanhecer"
            }()

            await progress("Elevating prompt… (Random)\nTopic: \(topic)\nLang: \(req.genLanguage) • ~\(req.lengthWords) words")
            let elevated = try await refinePrompt(topic, targetLang: req.genLanguage, wordCount: req.lengthWords)
            await progress("Generating… \(elevated)\nLang: \(req.genLanguage) • ~\(req.lengthWords) words")
            fullText = try await generateFromElevatedPrompt(elevated, targetLang: req.genLanguage, wordCount: req.lengthWords)

        case .prompt:
            let cleaned = req.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw NSError(domain: "Generator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty prompt"]) }
            await progress("Elevating prompt…")
            let elevated = try await refinePrompt(cleaned, targetLang: req.genLanguage, wordCount: req.lengthWords)
            await progress("Generating… \(elevated)\nLang: \(req.genLanguage) • ~\(req.lengthWords) words")
            fullText = try await generateFromElevatedPrompt(elevated, targetLang: req.genLanguage, wordCount: req.lengthWords)
        }

        // ---- Parse title/body ----
        let lines = fullText.split(separator: "\n", omittingEmptySubsequences: false)
        let rawTitle = lines.first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Sem Título"
        let generatedTitle = normalizeTitleCaseIfAllCaps(rawTitle)
        let bodyPrimary = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        var folder = slugify(generatedTitle)
        let baseRoot = FileManager.docsLessonsDir
        var base = baseRoot.appendingPathComponent(folder, isDirectory: true)
        if (try? base.checkResourceIsReachable()) == true {
            folder += "_" + String(Int(Date().timeIntervalSince1970))
            base = baseRoot.appendingPathComponent(folder, isDirectory: true)
        }
        let lessonID = folder

        await progress("Translating to \(req.transLanguage)…\nTítulo: \(generatedTitle)")

        // Avoid translating into the same language
        let secondaryText: String
        if req.genLanguage.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            == req.transLanguage.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
            secondaryText = bodyPrimary
        } else {
            secondaryText = try await translate(bodyPrimary, to: req.transLanguage)
        }

        // ---- Segmentation helpers ----
        func paragraphs(_ txt: String) -> [String] {
            var s = txt.replacingOccurrences(of: "\r\n", with: "\n")
                       .replacingOccurrences(of: "\r", with: "\n")
            while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
            return s.components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { p in
                    if let last = p.last, ".!?".contains(last) { return p }
                    return p + "."
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

        // ---- Build segments ----
        var segsPrimary: [String] = []
        var segsSecondary: [String] = []
        var segmentParagraphIndex: [Int] = []

        switch req.segmentation {
        case .sentences:
            // 1 sentence = 1 segment
            let sentPrimary = sentences(bodyPrimary)
            let sentSecondary = sentences(secondaryText)
            let count = min(sentPrimary.count, sentSecondary.count)
            
            segsPrimary = Array(sentPrimary.prefix(count))
            segsSecondary = Array(sentSecondary.prefix(count))
            
            // Map each sentence index to its paragraph index
            let perPara = sentencesPerParagraph(bodyPrimary)
            var sentToPara: [Int:Int] = [:]
            var running = 0
            for (pIdx, c) in perPara.enumerated() {
                for s in running ..< running + c { sentToPara[s] = pIdx }
                    running += c
            }
            segmentParagraphIndex = (0..<count).map { sentToPara[$0] ?? 0 }
            
            await progress("Preparing audio… \(segsPrimary.count) sentence segments")
        case .paragraphs:
            let pParas = paragraphs(bodyPrimary)
            let sParas = paragraphs(secondaryText)
            let count = min(pParas.count, sParas.count)
            segsPrimary = Array(pParas.prefix(count))
            segsSecondary = Array(sParas.prefix(count))
            segmentParagraphIndex = Array(0..<count)
            await progress("Preparing audio… \(segsPrimary.count) paragraph segments")
        }

        let count = min(segsPrimary.count, segsSecondary.count)
        let ptSegs = Array(segsPrimary.prefix(count))
        let enSegs = Array(segsSecondary.prefix(count))

        // ---- Create folder & TTS ----
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        struct Seg: Codable {
            let id: Int
            let pt_text: String
            let en_text: String
            let pt_file: String
            let en_file: String
            let paragraph: Int?
        }

        var rows: [Seg] = []

        let src = languageSlug(req.genLanguage)
        let dst = languageSlug(req.transLanguage)

        for i in 0..<count {
            try Task.checkCancellation()
            await progress("TTS \(i+1)/\(count) \(req.genLanguage)…")
            let ptFile = "\(src)_\(lessonID)_\(i+1).mp3"
            _ = try await tts(
                apiKey: req.apiKey,
                text: ptSegs[i],
                filename: ptFile,
                folder: base,
                language: req.genLanguage,
                speed: req.speechSpeed
            )

            try Task.checkCancellation()
            await progress("TTS \(i+1)/\(count) \(req.transLanguage)…")
            let enFile = "\(dst)_\(lessonID)_\(i+1).mp3"
            _ = try await tts(
                apiKey: req.apiKey,
                text: enSegs[i],
                filename: enFile,
                folder: base,
                language: req.transLanguage,
                speed: req.speechSpeed
            )

            rows.append(.init(
                id: i+1,
                pt_text: segsPrimary[i],
                en_text: segsSecondary[i],
                pt_file: ptFile,
                en_file: enFile,
                paragraph: segmentParagraphIndex[i]
            ))
        }

        // segments_<lesson>.json
        let segJSON = base.appendingPathComponent("segments_\(lessonID).json")
        let segData = try JSONEncoder().encode(rows)
        try save(segData, to: segJSON)

        // update lessons.json in Documents
        struct Manifest: Codable { var id:String; var title:String; var folderName:String }
        let manifestURL = FileManager.docsLessonsDir.appendingPathComponent("lessons.json")
        var list: [Manifest] = []
        if let d = try? Data(contentsOf: manifestURL) {
            list = (try? JSONDecoder().decode([Manifest].self, from: d)) ?? []
            list.removeAll { $0.id == lessonID }
        }
        let title = generatedTitle
        list.append(.init(id: lessonID, title: title, folderName: lessonID))
        let out = try JSONEncoder().encode(list)
        try save(out, to: manifestURL)

        return lessonID
    }
}

// MARK: - Simple background activity manager

private final class BackgroundActivityManager {
    func begin() -> UIBackgroundTaskIdentifier {
        #if os(iOS)
        let id = UIApplication.shared.beginBackgroundTask(withName: "LessonGeneration") { }
        return id
        #else
        return .invalid
        #endif
    }

    func end(_ id: UIBackgroundTaskIdentifier) {
        #if os(iOS)
        if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
        #endif
    }
}
