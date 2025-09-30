//
//  GeneratorService.swift
//  InputMaximizer
//
//  Created by Robin Geske on 01.09.25.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

/// A long-lived service that performs lesson generation even if views change.
/// Owns the async Task so navigation doesn't cancel it.
@MainActor
final class GeneratorService: ObservableObject {

    // Inside GeneratorService (top of the class)
    static let proxy = ProxyClient(
        baseURL: URL(string: "https://inputmax-proxy.inputmax.workers.dev")!
    )

    // Public progress for UI
    @Published var isBusy = false
    @Published var status = ""
    @Published var lastLessonID: String?
    
    @Published var outOfCredits = false

    static func fetchServerBalance() async throws -> Int {
        try await proxy.balance(deviceId: DeviceID.current)
    }
    
    // Helper
    static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    
    // Current running task
    private var currentTask: Task<Void, Never>?
    private let background = BackgroundActivityManager()
    
    private var currentBgTaskId: UIBackgroundTaskIdentifier = .invalid
    
    struct Request: Equatable, Sendable {
        enum GenerationMode: String { case random, prompt }
        enum Segmentation: String { case sentences, paragraphs }
        enum SpeechSpeed: String { case regular, slow }
        enum LanguageLevel: String, Codable, CaseIterable { case A1, A2, B1, B2, C1, C2 }
        
        var languageLevel: LanguageLevel = .B1   // sensible default

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

        isBusy = true
        status = "Starting…"
        lastLessonID = nil

        background.end(currentBgTaskId)
        currentBgTaskId = background.begin(name: "LessonGeneration")
        
        // Inherit @MainActor so capturing `self` is legal in Swift 6.
        currentTask = Task(priority: .userInitiated) { @MainActor [weak self] in
            guard let self else { return }
            do {
                let lessonID = try await Self.runGeneration(
                    req: req,
                    progress: { [weak self] message in   // ← async by signature
                        self?.status = message           // safe on @MainActor
                    }
                )
                self.lastLessonID = lessonID
                self.status = "Done. Open the lesson list and select."
                self.isBusy = false
                lessonStore.load()
            } catch is CancellationError {
                self.status = "Cancelled."
                self.isBusy = false
            } catch {
                if let ns = error as NSError?, ns.domain == "Credits", ns.code == 402 {
                    self.outOfCredits = true
                }
                self.status = "Error: \(error.localizedDescription)"
                self.isBusy = false
            }
            // ALWAYS end the background task on completion/exit.
            self.background.end(self.currentBgTaskId)
            self.currentBgTaskId = .invalid
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isBusy = false
        status = "Cancelled."
        
        // Also end the background task if it’s still active.
        background.end(currentBgTaskId)
        currentBgTaskId = .invalid
    }
    
    // Helpers
    
    struct LessonMeta: Codable {
        let schemaVersion: Int
        let id: String
        let title: String
        let targetLanguage: String
        let translationLanguage: String
        let targetLangCode: String
        let translationLangCode: String
        let targetShort: String   // e.g. "PT-BR", "ZH-Hans", "EN"
        let translationShort: String
        let segmentation: String  // "sentences" | "paragraphs"
        let speechSpeed: String   // "regular" | "slow"
        let languageLevel: String // CEFR: A1..C2
        let createdAtISO: String
    }

}

// MARK: - The worker (non-UI code)

private extension GeneratorService {
    
    static func extractRawTitleAndBody(from fullText: String) -> (title: String, body: String) {
        // Use first *non-empty* line as title, ignore markdown headers (e.g. "# Title")
        let allLines = fullText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)

        var rawTitle: String = "Sem Título"
        var bodyLines: [Substring] = []

        var foundTitle = false
        for line in allLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !foundTitle, !trimmed.isEmpty {
                // Drop markdown header marks and surrounding quotes
                rawTitle = trimmed
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#*>- ")).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”‘’'"))
                foundTitle = true
                continue
            }
            if foundTitle {
                bodyLines.append(line)
            }
        }

        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (rawTitle, body)
    }

    // Remove bracketed/parenthetical segments like "Title (Draft)" or "Name [v2]"
    static func stripBracketed(_ s: String) -> String {
        let patterns = [
            #"\s*\(.*?\)"#, #"\s*\[.*?\]"#, #"\s*\{.*?\}"#
        ]
        var out = s
        for p in patterns {
            if let rx = try? NSRegularExpression(pattern: p, options: []) {
                out = rx.stringByReplacingMatches(in: out, options: [], range: NSRange(out.startIndex..., in: out), withTemplate: "")
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Cut off common subtitle separators: "Main: Subtitle", "Main — Subtitle", "Main - Subtitle", "Main | Subtitle"
    static func dropSubtitle(_ s: String) -> String {
        let seps = [":", "—", "–", "-", "|", "·"]
        for sep in seps {
            if let r = s.range(of: sep) {
                let prefix = s[..<r.lowerBound]
                return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s
    }

    // Collapse internal whitespace
    static func collapseSpaces(_ s: String) -> String {
        let comps = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return comps.joined(separator: " ")
    }

    // Ensure short, tidy title
    static func shortenTitle(_ s: String, maxChars: Int = 48, maxWords: Int = 8) -> String {
        // 1) strip bracketed parts and subtitles
        var t = stripBracketed(dropSubtitle(s))
        // 2) collapse spaces
        t = collapseSpaces(t)

        // 3) hard limits: words then chars (preserving word boundaries)
        let words = t.split(separator: " ")
        if words.count > maxWords {
            t = words.prefix(maxWords).joined(separator: " ")
        }
        if t.count > maxChars {
            // Cut at the last space before maxChars if possible
            let idx = t.index(t.startIndex, offsetBy: maxChars)
            var clipped = String(t[..<idx])
            if let lastSpace = clipped.lastIndex(of: " ") {
                clipped = String(clipped[..<lastSpace])
            }
            t = clipped
        }

        // 4) trim leftover punctuation/quotes
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;!?\"“”‘’'|-—–"))

        // Fallback if empty
        if t.isEmpty { t = "Sem Título" }
        return t
    }

    
    // Timeout Handler
    enum NetError: Error { case timedOut }

    static func withTimeout<T>(_ seconds: Double, _ op: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NetError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    static func retry<T>(
        attempts: Int = 3,
        initialDelay: Double = 0.8,
        factor: Double = 2.0,
        _ op: @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        var delay = initialDelay
        for i in 0..<attempts {
            do { return try await op() }
            catch is CancellationError { throw NetError.timedOut } // respect cancellation
            catch {
                lastError = error
                if i < attempts - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay *= factor
                    continue
                }
            }
        }
        throw lastError ?? NetError.timedOut
    }

    
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
    static func chatViaProxy(_ body: [String:Any]) async throws -> String {
        let json = try await retry {
            try await withTimeout(60) {
                try await proxy.chat(deviceId: DeviceID.current, body: body)
            }
        }
        let content = (((json["choices"] as? [[String:Any]])?.first?["message"] as? [String:Any])?["content"] as? String) ?? ""
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func ttsViaProxy(text: String, language: String, speed: Request.SpeechSpeed) async throws -> Data {
        try await retry {
            try await withTimeout(90) {   // TTS can be slower than chat
                try await proxy.tts(deviceId: DeviceID.current, text: text, language: language, speed: speed.rawValue)
            }
        }
    }

    // ---- Segmentation helpers ----
    static func paragraphs(_ txt: String) -> [String] {
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

    static func sentences(_ txt: String) -> [String] {
        txt.split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { s in
                if s.hasSuffix(".") || s.hasSuffix("!") || s.hasSuffix("?") { return s }
                return s + "."
            }
    }

    static func sentencesPerParagraph(_ txt: String) -> [Int] {
        let ps = Self.paragraphs(txt)
        return ps.map { sentences($0).count }
    }
    
    // MARK: - The whole pipeline, headless
    /// Returns the `lessonID` written to disk.
    static func runGeneration(
        req: GeneratorService.Request,
        progress: @MainActor @Sendable (String) async -> Void   // main-actor, non-async
    ) async throws -> String {

        // ---------- Local helpers ----------
        /*
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
            - List must-cover points and requirements derived from the user’s material.
            - Include explicit CEFR guidance that the writer should obey:
            \(cefrGuidance(req.languageLevel, targetLanguage: targetLang))

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
            return try await chatViaProxy(body)
        }
        */
        func refinePrompt(_ raw: String, targetLang: String, wordCount: Int) async throws -> String {
            let meta = """
            You are a prompt compositor & refiner for a writing generator.

            The user provides a multi-line seed where each line is a Key: Value pair (e.g., "Archetype: Story", "Tone / Style: Dramatic / emotional", "Hexagram Archetype: ䷜ 29 · The Abysmal (Danger)", "Setting: Desert", etc.). The seed may also include a free-text instruction or pasted material.

            Your tasks:
            1) **Parse** the seed lines robustly (trim spaces; accept minor label variations or missing lines).
            2) **Preserve** all given intent, named entities, facts, references, and requested form (story, koan, letter, poem, myth, essay, etc.).
            3) **Weave** the parsed axes into one coherent writing brief that a model can follow directly.

            Hard constraints to enforce:
            - Language: \(targetLang)
            - Target length: ≈ \(wordCount) words (flexible ±15%)
            - CEFR level: \(req.languageLevel.rawValue)

            Map from the seed:
            - Form (from “Archetype”): the mode (Story/Myth/Dream-journey/Koan/Journal/Letter/Lyric Poem/Riddle/Lecture / essay).
            - Tone / Style: emotional color.
            - Perspective: voice (1st/2nd/3rd/Stream of consciousness).
            - Hexagram Archetype: use the hexagram’s core meaning as **theme**; do not add unrelated mysticism.
            - Setting: place/venue (e.g., Forest, City, Dreamscape).
            - Timeframe: era (Mythic past, Present, Near/Far future, Timeless).
            - Scale / Recursion: zoom level (Cosmic → Microcosmic; Elemental/Systemic/Abstract).
            - Interest: a vivid experiential seed; treat it as grounding material if present.

            If any axis is missing, default sensibly without inventing contradictions.

            Output format (return ONLY this brief; no headers, no explanations):
            - **Title**: a short working title in \(targetLang).
            - **Writing Task**: 1–2 sentences describing what to write, honoring the Form and Hexagram theme.
            - **Audience & Voice**: audience (if implied) and the requested Perspective & Tone.
            - **Context & Setting**: Setting, Timeframe, and Scale/Recursion (and Season/Weather if present); integrate Interest seed concretely if provided.
            - **Must-Cover Points**: 4–7 bullet points derived from the seed/material; include any named entities/facts the user gave.
            - **Structure**: simple paragraph plan (e.g., 3–5 paragraphs) with 1–2 clauses per paragraph about its focus; sentences not too long.
            - **Language Guidance (CEFR \(req.languageLevel.rawValue))**:
              \(cefrGuidance(req.languageLevel, targetLanguage: targetLang))
            - **Length**: aim for ≈ \(wordCount) words (±15%).

            Notes:
            - Keep the brief in \(targetLang).
            - Be faithful; do not drift from the user’s seed.
            - Do not include meta-commentary or analysis outside the brief.
            - If the seed includes extra free text after the Key: Value lines, treat it as user material that must be respected.

            User seed / material:
            \(raw)
            """

            let body: [String:Any] = [
                "model": "gpt-5-nano",
                "messages": [
                    ["role":"system","content":"Compose faithful, executable writing briefs from multi-line aspect seeds. Preserve intent; integrate all provided axes."],
                    ["role":"user","content": meta]
                ],
            ]
            return try await chatViaProxy(body)
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
                "model": "gpt-5-nano",
                "messages": [
                    ["role":"system","content": system],
                    ["role":"user","content": elevated]
                ],
            ]
            return try await chatViaProxy(body)
        }

        func translateParagraphs(_ text: String, to targetLang: String) async throws -> String {
            let ps = Self.paragraphs(text)
            if ps.isEmpty { return "" }

            var results = Array(repeating: "", count: ps.count)
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for (i, p) in ps.enumerated() {
                    group.addTask {
                        let t = try await translate(p, to: targetLang)
                        return (i, t.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                for try await (i, t) in group {
                    results[i] = t
                }
            }
            return results.joined(separator: "\n\n")
        }

        func translate(_ text: String, to targetLang: String) async throws -> String {
            let system = """
            Translate naturally and idiomatically into the requested language.

            Sentence alignment (must):
            • Keep a 1:1 mapping with the source: SAME number of sentences, SAME order.
            • Do not merge, split, add, or drop sentences.

            Formatting:
            • Return plain text only (no quotes, bullets, numbering, or metadata).
            • Use normal sentence punctuation for the target language.
            """

            let user = """
            Target language: \(targetLang)

            Translate the text below. Preserve the sentence boundaries exactly
            (one target sentence per source sentence, same order).

            \(text)
            """

            let body: [String: Any] = [
                "model": "gpt-5-nano",
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user]
                ]
            ]
            return try await chatViaProxy(body)
        }


        // ---------- Two-phase credit hold (reserve → commit/cancel) ----------
        let deviceId = DeviceID.current
        let jobId = try await Self.proxy.jobStart(deviceId: deviceId, amount: 1, ttlSeconds: 1800)

        do {
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

                await progress("Elevating prompt…\n\nTopic: \(topic)\n\nLang: \(req.genLanguage) • ~\(req.lengthWords) words")
                let elevated = try await refinePrompt(topic, targetLang: req.genLanguage, wordCount: req.lengthWords)
                //await progress("Generating… \(elevated)\nLang: \(req.genLanguage) • ~\(req.lengthWords) words")
                await progress("Generating… \n\nLang: \(req.genLanguage) • ~\(req.lengthWords) words")
                fullText = try await generateFromElevatedPrompt(elevated, targetLang: req.genLanguage, wordCount: req.lengthWords)

            case .prompt:
                let cleaned = req.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { throw NSError(domain: "Generator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty prompt"]) }
                await progress("Elevating prompt…")
                let elevated = try await refinePrompt(cleaned, targetLang: req.genLanguage, wordCount: req.lengthWords)
                await progress("Generating…\n\nLang: \(req.genLanguage) • ~\(req.lengthWords) words")
                fullText = try await generateFromElevatedPrompt(elevated, targetLang: req.genLanguage, wordCount: req.lengthWords)
            }

            // ---- Parse title/body ----
            let (rawTitle0, bodyPrimary0) = extractRawTitleAndBody(from: fullText)

            // Normalize "ALL CAPS" → Title Case if needed
            let normalized = normalizeTitleCaseIfAllCaps(rawTitle0)

            // Enforce short, tidy title (e.g., ≤48 chars and ≤8 words)
            let generatedTitle = shortenTitle(normalized, maxChars: 48, maxWords: 8)

            // Use the cleaned body
            let bodyPrimary = bodyPrimary0


            var folder = slugify(generatedTitle)
            let baseRoot = FileManager.docsLessonsDir
            var base = baseRoot.appendingPathComponent(folder, isDirectory: true)
            if (try? base.checkResourceIsReachable()) == true {
                folder += "_" + String(Int(Date().timeIntervalSince1970))
                base = baseRoot.appendingPathComponent(folder, isDirectory: true)
            }
            let lessonID = folder

            await progress("Translating to \(req.transLanguage)…\n\nTítulo: \(generatedTitle)")

            // Avoid translating into the same language
            let sameLang =
                req.genLanguage.lowercased()
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                ==
                req.transLanguage.lowercased()
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            let secondaryText: String = sameLang
                ? bodyPrimary
                : try await translateParagraphs(bodyPrimary, to: req.transLanguage)

            // ---- Build segments ----
            var segsPrimary: [String] = []
            var segsSecondary: [String] = []
            var segmentParagraphIndex: [Int] = []

            switch req.segmentation {
            case .sentences:
                // 1 sentence = 1 segment
                let sentPrimary = Self.sentences(bodyPrimary)
                let sentSecondary = Self.sentences(secondaryText)
                let count = min(sentPrimary.count, sentSecondary.count)

                segsPrimary = Array(sentPrimary.prefix(count))
                segsSecondary = Array(sentSecondary.prefix(count))

                // Map each sentence index to its paragraph index
                let perPara = Self.sentencesPerParagraph(bodyPrimary)
                var sentToPara: [Int:Int] = [:]
                var running = 0
                for (pIdx, c) in perPara.enumerated() {
                    for s in running ..< running + c { sentToPara[s] = pIdx }
                    running += c
                }
                segmentParagraphIndex = (0..<count).map { sentToPara[$0] ?? 0 }

                await progress("Preparing audio… \(segsPrimary.count) sentence segments")
            case .paragraphs:
                let pParas = Self.paragraphs(bodyPrimary)
                let sParas = Self.paragraphs(secondaryText)
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
                let ptData = try await ttsViaProxy(text: ptSegs[i], language: req.genLanguage, speed: req.speechSpeed)
                try save(ptData, to: base.appendingPathComponent(ptFile))

                try Task.checkCancellation()
                await progress("TTS \(i+1)/\(count) \(req.transLanguage)…")
                let enFile = "\(dst)_\(lessonID)_\(i+1).mp3"
                let enData = try await ttsViaProxy(text: enSegs[i], language: req.transLanguage, speed: req.speechSpeed)
                try save(enData, to: base.appendingPathComponent(enFile))

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

            let meta = LessonMeta(
                schemaVersion: 1,
                id: lessonID,
                title: generatedTitle,
                targetLanguage: req.genLanguage,
                translationLanguage: req.transLanguage,
                targetLangCode: LessonLanguageResolver.languageCode(for: req.genLanguage),
                translationLangCode: LessonLanguageResolver.languageCode(for: req.transLanguage),
                targetShort: LessonLanguageResolver.shortLabel(for: req.genLanguage),
                translationShort: LessonLanguageResolver.shortLabel(for: req.transLanguage),
                segmentation: req.segmentation.rawValue.lowercased(),
                speechSpeed: req.speechSpeed.rawValue,
                languageLevel: req.languageLevel.rawValue,
                createdAtISO: isoNow()
            )
            let metaURL = base.appendingPathComponent("lesson_meta.json")
            let metaData = try JSONEncoder().encode(meta)
            try save(metaData, to: metaURL)

            
            // update lessons.json in Documents
            // Replace the Manifest struct in runGeneration with:
            struct Manifest: Codable {
                var id: String
                var title: String
                var folderName: String
                var targetLanguage: String?
                var translationLanguage: String?
                var targetLangCode: String?
                var translationLangCode: String?
            }
            
            
            let manifestURL = FileManager.docsLessonsDir.appendingPathComponent("lessons.json")
            var list: [Manifest] = []
            if let d = try? Data(contentsOf: manifestURL) {
                list = (try? JSONDecoder().decode([Manifest].self, from: d)) ?? []
                list.removeAll { $0.id == lessonID }
            }
            let title = generatedTitle
            
            list.append(.init(
                id: lessonID,
                title: title,
                folderName: lessonID,
                targetLanguage: req.genLanguage,
                translationLanguage: req.transLanguage,
                targetLangCode: LessonLanguageResolver.languageCode(for: req.genLanguage),
                translationLangCode: LessonLanguageResolver.languageCode(for: req.transLanguage)
            ))
            
            let out = try JSONEncoder().encode(list)
            try save(out, to: manifestURL)

            // ---- Commit the credit hold only after success ----
            try await Self.proxy.jobCommit(deviceId: deviceId, jobId: jobId)

            return lessonID

        } catch {
            // On *any* failure or cancellation, release the hold (best-effort)
            await Self.proxy.jobCancel(deviceId: deviceId, jobId: jobId)
            throw error
        }
    }

}

// MARK: - Simple background activity manager

@MainActor
private final class BackgroundActivityManager {
    private var currentId: UIBackgroundTaskIdentifier = .invalid

    /// Begin a background task. The expiration handler ends whatever task id
    /// is currently tracked, avoiding capture-before-declare & mutation-after-capture issues.
    func begin(name: String = "LessonGeneration") -> UIBackgroundTaskIdentifier {
        #if os(iOS)
        let id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            guard let self else { return }
            let toEnd = self.currentId
            if toEnd != .invalid {
                UIApplication.shared.endBackgroundTask(toEnd)
            }
            self.currentId = .invalid
        }
        currentId = id
        return id
        #else
        return .invalid
        #endif
    }

    /// End a background task if valid. Also clears the tracked id when it matches.
    func end(_ id: UIBackgroundTaskIdentifier) {
        #if os(iOS)
        if id != .invalid {
            UIApplication.shared.endBackgroundTask(id)
        }
        if currentId == id { currentId = .invalid }
        #endif
    }
}



