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
    
    @Published var nextPromptSuggestions: [String] = []
    
    // Track keyword extraction per lesson
    @Published var extractingKeywordsForLesson: String? = nil

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
    
    // NEW: precomputed suggestions (kept hidden until generation completes)
    private var nextPromptSuggestionsBuffer: [String] = []

    // NEW: background work that prepares suggestions early
    private var suggestionsWork: Task<Void, Never>?

    
    struct Request: Equatable, Sendable {
        enum GenerationMode: String { case random, prompt }
        enum Segmentation: String { case sentences, paragraphs }
        enum SpeechSpeed: String { case regular, slow }
        enum LanguageLevel: String, Codable, CaseIterable { case A1, A2, B1, B2, C1, C2 }
        
        enum TranslationStyle: String, Codable, CaseIterable { case literal, idiomatic }

        
        var languageLevel: LanguageLevel = .B1   // sensible default

        var mode: GenerationMode
        var userPrompt: String

        var genLanguage: String
        var transLanguage: String

        var segmentation: Segmentation
        var lengthWords: Int
        var speechSpeed: SpeechSpeed = .regular
        
        var translationStyle: TranslationStyle = .idiomatic
        
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

        nextPromptSuggestions = []

        // NEW: reset and precompute suggestions in the background (hidden for now)
        nextPromptSuggestionsBuffer = []
        suggestionsWork?.cancel()
        suggestionsWork = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let ideas = (try? await Self.suggestNextPrompts(from: req)) ?? []
            // Store in buffer only; UI will reveal after generation completes
            self.nextPromptSuggestionsBuffer = ideas
        }

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

                // NEW: reveal the already-precomputed suggestions without waiting
                self.nextPromptSuggestions = self.nextPromptSuggestionsBuffer
                self.nextPromptSuggestionsBuffer = []
                self.suggestionsWork = nil

            } catch is CancellationError {
                // NEW: stop background suggestions; clear buffer on cancel
                self.suggestionsWork?.cancel()
                self.suggestionsWork = nil
                self.nextPromptSuggestionsBuffer = []
                self.nextPromptSuggestions = []

                self.status = "Cancelled."
                self.isBusy = false
            } catch {
                // NEW: stop background suggestions; clear buffer on failure
                self.suggestionsWork?.cancel()
                self.suggestionsWork = nil
                self.nextPromptSuggestionsBuffer = []
                self.nextPromptSuggestions = []    // keep UI clean on failure

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

        // NEW: stop background suggestions; clear buffer
        suggestionsWork?.cancel()
        suggestionsWork = nil
        nextPromptSuggestionsBuffer = []

        
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
    
    // Simple chat for brainstorming - uses its own job
    func chatViaProxySimple(_ prompt: String) async throws -> String {
        let deviceId = DeviceID.current
        let (jobId, jobToken) = try await Self.proxy.jobStart(deviceId: deviceId, amount: 1, ttlSeconds: 600)
        
        defer {
            Task {
                await Self.proxy.jobCancel(deviceId: deviceId, jobId: jobId)
            }
        }
        
        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": "You are a helpful, friendly assistant helping users brainstorm creative lesson ideas for language learning. Be concise and engaging."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.7,
            "max_tokens": 300
        ]
        
        return try await Self.chatViaProxy(body, jobId: jobId, jobToken: jobToken)
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
            do { 
                return try await op() 
            }
            catch is CancellationError { 
                throw NetError.timedOut  // respect cancellation
            }
            catch let error as URLError {
                // Handle specific network errors
                lastError = error
                
                // Don't retry on certain errors
                switch error.code {
                case .badURL, .unsupportedURL, .badServerResponse:
                    throw error  // Not transient, don't retry
                case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                    // Transient errors - retry with backoff
                    if i < attempts - 1 {
                        print("⚠️ Network error (\(error.code.rawValue)), retrying in \(delay)s... (attempt \(i + 1)/\(attempts))")
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        delay *= factor
                        continue
                    }
                default:
                    // Unknown error - retry once
                    if i < attempts - 1 {
                        print("⚠️ Unknown network error (\(error.code.rawValue)), retrying...")
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        delay *= factor
                        continue
                    }
                }
            }
            catch {
                lastError = error
                // For non-URLErrors (like server errors), retry with backoff
                if i < attempts - 1 {
                    print("⚠️ Request error: \(error.localizedDescription), retrying in \(delay)s...")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay *= factor
                    continue
                }
            }
        }
        throw lastError ?? NetError.timedOut
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
    /// Chat via proxy with background-capable session (continues when app is backgrounded)
    static func chatViaProxy(_ body: [String:Any], jobId: String, jobToken: String) async throws -> String {
        let json = try await retry(attempts: 3, initialDelay: 1.0) {
            try await withTimeout(90) {  // Increased timeout for background resilience
                try await proxy.chatBackground(deviceId: DeviceID.current, jobId: jobId, jobToken: jobToken, body: body)
            }
        }
        let content = (((json["choices"] as? [[String:Any]])?.first?["message"] as? [String:Any])?["content"] as? String) ?? ""
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// TTS via proxy with background-capable session (continues when app is backgrounded)
    static func ttsViaProxy(text: String, language: String, speed: Request.SpeechSpeed, jobId: String, jobToken: String) async throws -> Data {
        try await retry(attempts: 3, initialDelay: 1.0) {
            try await withTimeout(120) {   // Increased timeout for background resilience
                try await proxy.ttsBackground(deviceId: DeviceID.current, jobId: jobId, jobToken: jobToken, text: text, language: language, speed: speed.rawValue)
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
            .map { ensureTerminalPunctuationKeepingClosing($0) }   // <- use helper from above
    }

    static func sentences(_ text: String) -> [String] {
        // Sentence enders, then optional closing quotes/brackets
        // Handles ., !, ?, …, and clusters like ?! — keeps trailing ” ’ " » ) ]
        let pattern = #"(.*?)([\.!?…]+[\"“”'’»\)\]]*)\s+"#
        let ns = text as NSString
        let rx = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])

        var result: [String] = []
        var idx = 0

        for m in rx.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            let r = NSRange(location: idx, length: m.range.upperBound - idx)
            let s = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { result.append(s) }
            idx = m.range.upperBound
        }

        // Tail (if any) – trim; if non-empty and not punctuated, add a period *before* closing quotes
        let tail = ns.substring(from: idx).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            result.append(ensureTerminalPunctuationKeepingClosing(tail))
        }
        return result
    }
    
    // —— Quote-aware sentence splitter for validation (keeps end marks + closers) ——
    static func sentenceSplitKeepingClosers(_ text: String) -> [String] {
        let pattern = #"(.*?)([\.!?…]+[\"“”'’»\)\]]*)(\s+|$)"#
        let ns = text as NSString
        let rx = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])

        var out: [String] = []
        var i = 0
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let r = NSRange(location: i, length: m.range.upperBound - i)
            let s = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            i = m.range.upperBound
        }
        let tail = ns.substring(from: i).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }
    
    // MARK: - Dialogue formatting helpers

    static func leadingSpeakerLabelAndRest(_ s: String) -> (label: String, rest: String)? {
        // Optional leading quotes/dashes/spaces, then a short name up to colon, then the utterance.
        let pattern = #"^\s*[\"“”'’«»—-]*\s*([^\n:]{1,24}):\s*(.*)$"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 3 else { return nil }
        let label = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest  = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (label, rest)
    }


    // Strip ONE outer pair of quotes if present (handles “ ”, " ", « », ‚ ‘, etc.)
    private static func stripOneOuterQuotePair(_ s: String) -> String {
        let opens = "“\"«‚‘„‹‘"
        let closes = "”\"»’’“›’"
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, let last = trimmed.last else { return trimmed }
        let oidx = opens.firstIndex(of: first)
        let cidx = closes.firstIndex(of: last)
        if oidx != nil && cidx != nil && trimmed.count >= 2 {
            let inner = trimmed.dropFirst().dropLast()
            return String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    // Convert any remaining *inner* double quotes to single quotes to avoid nested “ ”
    private static func normalizeInnerQuotesToSingles(_ s: String) -> String {
        var t = s
        // straight double → straight single
        t = t.replacingOccurrences(of: "\"", with: "'")
        // smart double → smart single
        t = t.replacingOccurrences(of: "“", with: "‘")
             .replacingOccurrences(of: "”", with: "’")
             .replacingOccurrences(of: "«", with: "‘")
             .replacingOccurrences(of: "»", with: "’")
        return t
    }

    // Wrap once in smart double quotes; ensure end punctuation inside the quotes.
    static func ensureQuoted(_ content: String) -> String {
        // 1) remove one outer layer if it exists
        let unwrapped = stripOneOuterQuotePair(content)
        // 2) normalize any remaining inner double quotes to singles
        let inner = normalizeInnerQuotesToSingles(unwrapped)
        // 3) ensure sentence-final punctuation, then wrap
        let punctuated = ensureTerminalPunctuationKeepingClosing(inner)
        return "“\(punctuated)”"
    }

    // Decide if a paragraph is dialogue: at least 1 sentence has a speaker label
    static func isDialogueParagraph(_ sentences: [String]) -> Bool {
        sentences.contains { leadingSpeakerLabelAndRest($0) != nil }
    }

    /// Normalize a whole text:
    /// - Dialogue paragraphs (any sentence with a leading `Name:`) are grouped by speaker:
    ///     Name: “sent 1. sent 2.”   // one line per speaker block, label outside, smart quotes
    /// - Prose paragraphs (no speaker labels) keep a single-space flow (no newlines inside).
    static func normalizeDialoguePresentation(_ text: String) -> String {
        let paras = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")

        var out: [String] = []

        for p in paras {
            let trimmedP = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedP.isEmpty { continue }

            // Split into sentences, keep punctuation/closers
            let ss = sentenceSplitKeepingClosers(trimmedP).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if ss.isEmpty { continue }

            // Decide: dialogue vs prose
            let hasDialogue = ss.contains { leadingSpeakerLabelAndRest($0) != nil }
            if !hasDialogue {
                // PROSE: single spaced; ensure terminal punctuation
                let joined = ss.map { ensureTerminalPunctuationKeepingClosing($0) }.joined(separator: " ")
                out.append(joined)
                continue
            }

            // DIALOGUE: group consecutive sentences by current speaker
            var lines: [String] = []
            var currentLabel: String? = nil
            var buffer: [String] = []   // sentences (without label) for the current speaker

            func flush() {
                guard let lab = currentLabel else { return }
                // join speaker’s sentences with a single space, then quote once
                let merged = buffer.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                let quoted = ensureQuoted(merged)
                lines.append("\(lab): \(quoted)")
                buffer.removeAll(keepingCapacity: true)
            }

            for s in ss {
                if let (lab, rest) = leadingSpeakerLabelAndRest(s) {
                    // New speaker block
                    if currentLabel != nil { flush() }
                    currentLabel = lab
                    // strip any accidental label residue in `rest`, tidy punctuation, but DO NOT wrap yet
                    let core = stripAnyLeadingSpeakerLabel(rest).trimmingCharacters(in: .whitespacesAndNewlines)
                    buffer = [ensureTerminalPunctuationKeepingClosing(core)]
                } else {
                    // Continuation: if we have a current speaker, append; else treat as narration line
                    if currentLabel != nil {
                        buffer.append(ensureTerminalPunctuationKeepingClosing(s))
                    } else {
                        // Narration inside a dialogue paragraph — keep as its own (unlabeled) line
                        lines.append(ensureTerminalPunctuationKeepingClosing(s))
                    }
                }
            }
            // Flush last speaker block
            if currentLabel != nil { flush() }

            out.append(lines.joined(separator: "\n"))
        }

        return out.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }



    static func sentenceCount(_ s: String) -> Int {
        sentenceSplitKeepingClosers(s).count
    }
    
    // --- Speaker-label utilities (per-sentence) ---

    // Find a leading speaker label like `Ana:` at the very start of a sentence.
    static func extractLeadingSpeakerLabel(_ text: String) -> String? {
        // Optional quotes/dash, then a short name (≤24 chars) followed by a colon.
        let pattern = #"^\s*[\"“”'’«»—-]*\s*([^:\n]{1,24}):\s+"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = rx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Remove *any* leading `Something:` label (used on target to prevent duplicates).
    static func stripAnyLeadingSpeakerLabel(_ text: String) -> String {
        let pattern = #"^\s*[\"“”'’«»—-]*\s*([^:\n]{1,24}):\s+"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let r = NSRange(location: 0, length: ns.length)
        return rx.stringByReplacingMatches(in: text, range: r, withTemplate: "")
    }

    // Ensure per-sentence labels mirror the source (supports multiple speakers in one paragraph).
    static func enforcePerSentenceSpeakerLabels(source: String, target: String) -> String {
        let src = sentenceSplitKeepingClosers(source)
        var dst = sentenceSplitKeepingClosers(target)
        guard src.count == dst.count, !src.isEmpty else { return target }

        for i in 0..<src.count {
            let srcLabel = extractLeadingSpeakerLabel(src[i])
            let cleaned = stripAnyLeadingSpeakerLabel(dst[i]).trimmingCharacters(in: .whitespaces)
            if let lab = srcLabel {
                dst[i] = "\(lab): " + cleaned         // keep the same label verbatim
            } else {
                dst[i] = cleaned                       // remove any spurious label
            }
        }
        return dst.joined(separator: " ")
    }



    // Adds '.' before closing quotes/brackets if missing
    private static func ensureTerminalPunctuationKeepingClosing(_ s: String) -> String {
        let closers = CharacterSet(charactersIn: "\"“”'’»)]")
        let trims = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trims.unicodeScalars.last else { return trims }
        if CharacterSet(charactersIn: ".!?…").contains(last) { return trims }
        // If last char is a closer, insert '.' before the trailing closer run
        if closers.contains(last) {
            var scalars = Array(trims.unicodeScalars)
            var i = scalars.count - 1
            while i >= 0, closers.contains(scalars[i]) { i -= 1 }
            if i >= 0, !CharacterSet(charactersIn: ".!?…").contains(scalars[i]) {
                scalars.insert(".", at: i + 1)
            }
            return String(String.UnicodeScalarView(scalars))
        }
        return trims + "."
    }


    static func sentencesPerParagraph(_ txt: String) -> [Int] {
        let ps = Self.paragraphs(txt)
        return ps.map { sentences($0).count }
    }
    
    // Generate three diverse next prompts in the *helper* language using Structured Outputs
    static func suggestNextPrompts(from req: Request) async throws -> [String] {
        // Start a separate job for suggestions (low priority, separate from main generation)
        let deviceId = DeviceID.current
        let (jobId, jobToken) = try await proxy.jobStart(deviceId: deviceId, amount: 1, ttlSeconds: 600)
        
        defer {
            // Always cancel the job when done (best-effort, async)
            Task {
                await proxy.jobCancel(deviceId: deviceId, jobId: jobId)
            }
        }

        // --- Seed we want to move away from ---
        let seed: String = {
            switch req.mode {
            case .prompt:
                return req.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            case .random:
                let t = (req.userChosenTopic ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? "(no topic provided)" : t
            }
        }()

        // --- Ask for 3 prompts in helper language (transLanguage), not target ---
        func llmAsk(diversityBooster: String) async throws -> [String] {
            let user = """
            You create short, self-contained WRITING PROMPTS for language-learning text generation.

            Output language: \(req.transLanguage)   // helper language ONLY
            Count: exactly 3 prompts.
            Length per prompt: one sentence, ≤ 22–25 words.

            Diversity requirements (very important):
                        • The FIRST prompt must be a natural continuation or extension of the user's previous seed, keeping its tone, theme, and style consistent.
                        • The SECOND and THIRD prompts must take distinctly different directions from both the seed and each other.
                        • Change at least TWO of these axes per prompt (for prompts 2–3): purpose (inform/explain/persuade/narrate), genre/form, setting/place, time/era, perspective/POV, audience, tone/register.
                        • Avoid reusing the same key nouns/verbs/themes from the seed in prompts 2–3 unless necessary for sense.
            • No meta-instructions, no references to "the previous prompt/seed".

                        User's previous seed (to continue/diverge from):
            \(seed)

            \(diversityBooster)
            """

            // Define JSON Schema for structured output
            let jsonSchema: [String: Any] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "prompt_suggestions",
                    "description": "Three diverse writing prompts for language learning",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "prompts": [
                                "type": "array",
                                "description": "Array of exactly 3 writing prompts",
                                "items": [
                                    "type": "string",
                                    "description": "A short writing prompt (one sentence, 22-25 words)"
                                ],
                                "minItems": 3,
                                "maxItems": 3
                            ]
                        ],
                        "required": ["prompts"],
                        "additionalProperties": false
                    ]
                ]
            ]

            let body: [String: Any] = [
                "model": "gpt-5-nano",
                "messages": [
                    ["role": "system", "content": "Generate three SHORT, highly distinct prompts in the requested language."],
                    ["role": "user",   "content": user]
                ],
                "response_format": jsonSchema
            ]

            let raw = try await chatViaProxy(body, jobId: jobId, jobToken: jobToken)

            // Parse the structured JSON response
            guard let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let prompts = json["prompts"] as? [String] else {
                throw NSError(domain: "Generator", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to parse prompt suggestions JSON"])
            }

            return prompts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }

        // --- Lightweight lexical overlap check to enforce diversity ---
        func tokenize(_ s: String) -> Set<String> {
            let lowered = s.lowercased()
            let comps = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)
            let stop: Set<String> = ["the","a","an","and","or","but","so","to","in","on","of","for","with","by","at","from","as","is","are","be","was","were","that","this","it","its","into","about","over","under","through"]
            return Set(comps.filter { !$0.isEmpty && !stop.contains($0) })
        }

        func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
            if a.isEmpty && b.isEmpty { return 0 }
            let inter = a.intersection(b).count
            let union = a.union(b).count
            return union == 0 ? 0 : Double(inter) / Double(union)
        }

        // Filter prompts that are too similar to the seed or to each other
        func enforceDiversity(_ prompts: [String], seedTokens: Set<String>, maxOverlapSeed: Double = 0.35, maxOverlapPeer: Double = 0.5) -> [String] {
            var picked: [String] = []
            var pickedTokens: [Set<String>] = []

            for p in prompts {
                let t = tokenize(p)
                // far enough from seed?
                guard jaccard(t, seedTokens) <= maxOverlapSeed else { continue }
                // far enough from already picked prompts?
                let tooClose = pickedTokens.contains { jaccard(t, $0) > maxOverlapPeer }
                if !tooClose { picked.append(p); pickedTokens.append(t) }
                if picked.count == 3 { break }
            }
            return picked
        }

        // --- Try once; if too similar, try a stronger instruction once more ---
        let seedTokens = tokenize(seed)

        let first = try await llmAsk(diversityBooster:
            "Push strongly into different directions for each prompt. Prefer NEW settings/genres/purposes not implied by the seed."
        )
        
        var filtered = enforceDiversity(first,
                                        seedTokens: seedTokens,
                                        maxOverlapSeed: 0.30,
                                        maxOverlapPeer: 0.40)

        if filtered.count < 3 {
            let second = try await llmAsk(diversityBooster:
                "Your previous set was not diverse enough. Now generate three NEW prompts that are RADICALLY different from both the seed and typical variations. Change genre, purpose, and setting simultaneously."
            )
            // Merge and re-filter
            filtered = enforceDiversity(first + second, seedTokens: seedTokens)
        }

        // Ensure we return exactly 3 if possible
        return Array(filtered.prefix(3))
    }


    
    
    // MARK: - The whole pipeline, headless
    /// Returns the `lessonID` written to disk.
    static func runGeneration(
        req: GeneratorService.Request,
        progress: @MainActor @Sendable (String) async -> Void   // main-actor, non-async
    ) async throws -> String {

        // ---------- Local helpers ----------
        
        func refinePrompt(_ raw: String, targetLang: String, wordCount: Int, jobId: String, jobToken: String) async throws -> String {
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
            - List must-cover points and requirements derived from the user's material.
            - Include explicit CEFR guidance that the writer should obey:
            \(CEFRGuidance.guidance(level: req.languageLevel, targetLanguage: targetLang))

            User instruction or material:
            \(raw)
            """

            let jsonSchema: [String: Any] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "refined_prompt",
                    "description": "A refined writing prompt for lesson generation",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "refined_prompt": [
                                "type": "string",
                                "description": "The refined writing prompt with all requirements and guidance"
                            ]
                        ],
                        "required": ["refined_prompt"],
                        "additionalProperties": false
                    ]
                ]
            ]

            let body: [String:Any] = [
                "model": "gpt-5-nano",
                "messages": [
                    ["role":"system","content":"Refine prompts faithfully; elevate without drifting from user intent."],
                    ["role":"user","content": meta]
                ],
                "response_format": jsonSchema
            ]
            
            let raw = try await chatViaProxy(body, jobId: jobId, jobToken: jobToken)
            guard let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let refinedPrompt = json["refined_prompt"] as? String else {
                throw NSError(domain: "Generator", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to parse refined prompt JSON"])
            }
            return refinedPrompt
        }
        
        
        /*
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
        */


        func generateFromElevatedPrompt(_ elevated: String, targetLang: String, wordCount: Int, jobId: String, jobToken: String) async throws -> String {
            let system = """
            You are a world-class writer. Follow the user's prompt meticulously.
            Write in \(targetLang). Aim for ~\(wordCount) words total.
            Write at CEFR level \(req.languageLevel.rawValue).
            Follow these constraints:
            \(CEFRGuidance.guidance(level: req.languageLevel, targetLanguage: targetLang))
            
            Format requirements:
            • Title: short title (no quotes)
            • Body: main text content
            • Use normal sentence punctuation (. ! ? …). If a sentence ends with a quote or bracket, put the punctuation BEFORE the closing mark, e.g., "…".
            • Line breaks in body:
              - For REGULAR prose: do NOT insert newlines inside a paragraph; separate sentences with a single space only.
              - For DIALOGUE (sentences that begin with a speaker label like Ana: or Bruno:): put each speaker's sentence on its own line, label outside the quotes, e.g., Ana: "…".
              - Separate paragraphs with exactly one blank line.
            """

            let jsonSchema: [String: Any] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "generated_text",
                    "description": "A generated text with title and body for language learning",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "title": [
                                "type": "string",
                                "description": "Short title for the text (no quotes)"
                            ],
                            "body": [
                                "type": "string",
                                "description": "The main body text with proper paragraph formatting"
                            ]
                        ],
                        "required": ["title", "body"],
                        "additionalProperties": false
                    ]
                ]
            ]

            let body: [String:Any] = [
                "model": "gpt-5-nano",
                "messages": [
                    ["role":"system","content": system],
                    ["role":"user","content": elevated]
                ],
                "response_format": jsonSchema
            ]
            
            let raw = try await chatViaProxy(body, jobId: jobId, jobToken: jobToken)
            guard let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = json["title"] as? String,
                  let bodyText = json["body"] as? String else {
                throw NSError(domain: "Generator", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to parse generated text JSON"])
            }
            
            // Return in the original format: title on first line, blank line, then body
            return "\(title)\n\n\(bodyText)"
        }

        /// Ensure text is written in the expected language; rewrite inconsistent parts.
        func enforceLanguageConsistency(_ text: String, expectedLanguage: String, roleDescription: String, jobId: String, jobToken: String) async throws -> String {
            let system = """
            You are a language verifier. Task: detect if the given text is written in the EXPECTED language. If parts are in a different language, rewrite them into the EXPECTED language while preserving meaning.

            Hard requirements:
            • Keep the original paragraph and sentence boundaries; do not add or remove sentences.
            • Keep proper nouns, brand names, and established international terms as-is if appropriate.
            • Return ONLY the corrected text in the EXPECTED language.
            """

            let user = """
            Expected language (\(roleDescription)): \(expectedLanguage)

            Text to verify and correct:
            \(text)
            """

            let jsonSchema: [String: Any] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "language_verify_consistency",
                    "description": "Text corrected to the expected language if inconsistencies were found",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "clean_text": [
                                "type": "string",
                                "description": "Text rewritten into the expected language"
                            ]
                        ],
                        "required": ["clean_text"],
                        "additionalProperties": false
                    ]
                ]
            ]

            let body: [String: Any] = [
                "model": "gpt-5-nano",
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user",   "content": user]
                ],
                "response_format": jsonSchema
            ]

            let raw = try await chatViaProxy(body, jobId: jobId, jobToken: jobToken)
            guard let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let clean = json["clean_text"] as? String else {
                throw NSError(domain: "Generator", code: 11, userInfo: [NSLocalizedDescriptionKey: "Failed to parse language consistency JSON"])
            }
            return clean.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // --- Keyword extractor (target → helper language) ---
        // Uses Structured Outputs to return reliable JSON with keyword pairs
        func extractKeywordPairs(targetText: String,
                                        targetLang: String,
                                        translationLang: String,
                                        jobId: String,
                                        jobToken: String) async throws -> String {
            let system = """
            Extract the most relevant KEYWORDS and SHORT PHRASES from the user's TARGET-LANGUAGE text,
            then provide a concise translation into the requested helper language.

            - Exclude words that are identical or nearly identical in both languages (cognates).
            - Exclude names of people, places, and other proper nouns.
            - Focus on words and phrases that are important for understanding the meaning and are not obvious to a beginner.
            - Prefer verbs, nouns, and adjectives.
            - Include both single keywords and a few useful collocations.
            - Deduplicate entries.
            - Prefer 1–4 word spans (or compact characters for CJK). Avoid full sentences.
            - Aim for 24–40 pairs for a ~300–500 word text; scale proportionally if much shorter/longer.
            """

            let user = """
            Target language name: \(targetLang)
            Translation language name: \(translationLang)

            Text to analyze (target language):
            \(targetText)
            """

            // Define JSON Schema for structured output
            let jsonSchema: [String: Any] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "keyword_extraction",
                    "description": "A list of keyword pairs with target language words/phrases and their translations",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "pairs": [
                                "type": "array",
                                "description": "Array of keyword pairs from the text",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "target": [
                                            "type": "string",
                                            "description": "The keyword or phrase in the target language"
                                        ],
                                        "translation": [
                                            "type": "string",
                                            "description": "The translation in the helper language"
                                        ]
                                    ],
                                    "required": ["target", "translation"],
                                    "additionalProperties": false
                                ]
                            ]
                        ],
                        "required": ["pairs"],
                        "additionalProperties": false
                    ]
                ]
            ]

            let body: [String: Any] = [
                "model": "gpt-5-nano",
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user",   "content": user]
                ],
                "response_format": jsonSchema
            ]

            let raw = try await chatViaProxy(body, jobId: jobId, jobToken: jobToken)
            
            // Parse the JSON response
            guard let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pairs = json["pairs"] as? [[String: Any]] else {
                throw NSError(domain: "Generator", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to parse keyword pairs JSON"])
            }
            
            // Convert to tab-separated format for compatibility with existing file format
            let lines = pairs.compactMap { pair -> String? in
                guard let target = pair["target"] as? String,
                      let translation = pair["translation"] as? String else {
                    return nil
                }
                return "\(target)\t\(translation)"
            }
            
            return lines.joined(separator: "\n")
        }

        
        func translateParagraphs(_ text: String, to targetLang: String, style: Request.TranslationStyle, jobId: String, jobToken: String) async throws -> String {
            let ps = Self.paragraphs(text)
            if ps.isEmpty { return "" }

            var results = Array(repeating: "", count: ps.count)
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for (i, p) in ps.enumerated() {
                    group.addTask {
                        let t = try await translate(p, to: targetLang, style: style, jobId: jobId, jobToken: jobToken)
                        return (i, t.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                for try await (i, t) in group { results[i] = t }
            }
            return results.joined(separator: "\n\n")
        }
        
        func verifyAndFixTranslation(
            source: String,
            draft: String,
            targetLang: String,
            style: Request.TranslationStyle,
            jobId: String,
            jobToken: String
        ) async throws -> String {

            // Keep the same alignment rules you already enforce.
            let system = """
            You are a bilingual proofreader.
            Task: Check the draft translation for untranslated or stray source-language words
            (e.g., function words like 'and/because', common content words, or phrases).
            If any are present, replace them with natural equivalents in the target language.

            Hard requirements:
            • Keep EXACT sentence alignment with the source (same number and order of sentences).
            • Do NOT merge, split, add, or drop sentences.

            When it is correct to keep a token in the source language (proper nouns, brand names,
            code, established loanwords), leave it as-is.

            Translation style to respect: \(style == .idiomatic ? "idiomatic/natural" : "literal/faithful").
            """

            let user = """
            Target language: \(targetLang)

            Source (SENTENCE-BOUNDARIES MUST BE PRESERVED):
            \(source)

            Draft translation (to check and correct if needed; KEEP the SAME sentence count/order):
            \(draft)
            """

            let jsonSchema: [String: Any] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "corrected_translation",
                    "description": "Corrected translation with same sentence alignment",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "translation": [
                                "type": "string",
                                "description": "The corrected translation text"
                            ]
                        ],
                        "required": ["translation"],
                        "additionalProperties": false
                    ]
                ]
            ]

            let body: [String: Any] = [
                "model": "gpt-5-nano",
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user",   "content": user]
                ],
                "response_format": jsonSchema
            ]

            let raw = try await chatViaProxy(body, jobId: jobId, jobToken: jobToken)
            guard let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let translation = json["translation"] as? String else {
                throw NSError(domain: "Generator", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to parse corrected translation JSON"])
            }
            return translation.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        
        func translate(_ text: String, to targetLang: String, style: Request.TranslationStyle, jobId: String, jobToken: String) async throws -> String {
            // First pass (asks the model to keep boundaries)
            let draft = try await firstPassTranslate(text, to: targetLang, style: style, jobId: jobId, jobToken: jobToken)

            // Validate sentence counts per paragraph. If off, repair.
            let srcN = GeneratorService.sentenceCount(text)
            let dstN = GeneratorService.sentenceCount(draft)

            let aligned: String
            if srcN != dstN {
                aligned = try await repairSentenceAlignment(
                    source: text,
                    targetLang: targetLang,
                    style: style,
                    expectedSentenceCount: srcN,
                    badDraft: draft,
                    jobId: jobId,
                    jobToken: jobToken
                )
            } else {
                aligned = draft
            }

            // After verifyAndFixTranslation:
            let fixed = try await verifyAndFixTranslation(
                source: text,
                draft: aligned,
                targetLang: targetLang,
                style: style,
                jobId: jobId,
                jobToken: jobToken
            )

            // NEW: per-sentence label enforcement (handles multiple speakers inside one paragraph)
            let labeled = GeneratorService.enforcePerSentenceSpeakerLabels(source: text, target: fixed)
            return labeled

        }

        func firstPassTranslate(_ text: String, to targetLang: String, style: Request.TranslationStyle, jobId: String, jobToken: String) async throws -> String {
            let system: String = (style == .literal)
            ? """
              Translate as literally as possible.
              KEEP EXACT sentence alignment (same number and order as the source).
              Within a paragraph, NEVER insert newlines; separate sentences with a single space only.
              If a closing quote/bracket is followed by a comma and more text (e.g., "…?",), CONTINUE the SAME sentence.
              Speaker labels: If a source sentence begins with a speaker label like "Ana:", include the SAME label (verbatim) exactly once at the start of the corresponding target sentence. If the source sentence has no label, do NOT add one.
              """
            : """
              Translate naturally and idiomatically.
              KEEP EXACT sentence alignment (same number and order as the source).
              Within a paragraph, NEVER insert newlines; separate sentences with a single space only.
              If a closing quote/bracket is followed by a comma and more text (e.g., "…?",), CONTINUE the SAME sentence.
              Speaker labels: If a source sentence begins with a speaker label like "Ana:", include the SAME label (verbatim) exactly once at the start of the corresponding target sentence. If the source sentence has no label, do NOT add one.
              """

            let user = """
            Target language: \(targetLang)
            Translate the text below. Preserve sentence boundaries exactly (1 target sentence per source sentence, same order).

            \(text)
            """

            let jsonSchema: [String: Any] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "translation",
                    "description": "Translation with preserved sentence alignment",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "translation": [
                                "type": "string",
                                "description": "The translated text"
                            ]
                        ],
                        "required": ["translation"],
                        "additionalProperties": false
                    ]
                ]
            ]

            let body: [String:Any] = [
                "model": "gpt-5-nano",
                "messages": [
                    ["role":"system","content": system],
                    ["role":"user","content": user]
                ],
                "response_format": jsonSchema
            ]
            
            let raw = try await GeneratorService.chatViaProxy(body, jobId: jobId, jobToken: jobToken)
            guard let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let translation = json["translation"] as? String else {
                throw NSError(domain: "Generator", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to parse first pass translation JSON"])
            }
            return translation
        }

        func repairSentenceAlignment(
            source: String,
            targetLang: String,
            style: Request.TranslationStyle,
            expectedSentenceCount: Int,
            badDraft: String,
            jobId: String,
            jobToken: String
        ) async throws -> String {

            // Number the source sentences to give hard boundaries
            let srcSentences = GeneratorService.sentenceSplitKeepingClosers(source)
            let numbered = srcSentences.enumerated()
                .map { "[\($0.offset+1)] \($0.element)" }
                .joined(separator: " ")

            let system = """
            ALIGN the translation to the SOURCE sentence boundaries.
            Output MUST contain EXACTLY \(expectedSentenceCount) sentences, same order and meaning.
            Speaker labels: mirror labels sentence-by-sentence — keep the same label (verbatim) at the start if present; never add labels where the source has none.
            Do NOT omit content. No newlines inside the paragraph; separate sentences with a single SPACE.
            If a quoted question/exclamation is followed by a comma and more text, keep it in the SAME sentence.
            Translation style: \(style == .idiomatic ? "idiomatic/natural" : "literal/faithful")
            """

            let user = """
            Source (numbered for boundaries):
            \(numbered)

            Problematic draft (wrong boundaries):
            \(badDraft)

            Produce a corrected translation with EXACTLY \(expectedSentenceCount) sentences.
            """

            let jsonSchema: [String: Any] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "aligned_translation",
                    "description": "Translation with corrected sentence alignment",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            "translation": [
                                "type": "string",
                                "description": "The translation with exact sentence alignment"
                            ]
                        ],
                        "required": ["translation"],
                        "additionalProperties": false
                    ]
                ]
            ]

            let body: [String:Any] = [
                "model":"gpt-5-nano",
                "messages":[
                    ["role":"system","content": system],
                    ["role":"user","content": user]
                ],
                "response_format": jsonSchema
            ]
            
            let raw = try await GeneratorService.chatViaProxy(body, jobId: jobId, jobToken: jobToken)
            guard let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let translation = json["translation"] as? String else {
                throw NSError(domain: "Generator", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed to parse aligned translation JSON"])
            }
            return translation
        }



        // ---------- Two-phase credit hold (reserve → commit/cancel) ----------
        let deviceId = DeviceID.current
        let (jobId, jobToken) = try await Self.proxy.jobStart(deviceId: deviceId, amount: 1, ttlSeconds: 1800)

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
                let elevated = try await refinePrompt(topic, targetLang: req.genLanguage, wordCount: req.lengthWords, jobId: jobId, jobToken: jobToken)
                //await progress("Generating… \(elevated)\nLang: \(req.genLanguage) • ~\(req.lengthWords) words")
                await progress("Generating… \n\nLang: \(req.genLanguage) • ~\(req.lengthWords) words")
                fullText = try await generateFromElevatedPrompt(elevated, targetLang: req.genLanguage, wordCount: req.lengthWords, jobId: jobId, jobToken: jobToken)

            case .prompt:
                let cleaned = req.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { throw NSError(domain: "Generator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty prompt"]) }
                await progress("Elevating prompt…")
                let elevated = try await refinePrompt(cleaned, targetLang: req.genLanguage, wordCount: req.lengthWords, jobId: jobId, jobToken: jobToken)
                await progress("Generating…\n\nLang: \(req.genLanguage) • ~\(req.lengthWords) words")
                fullText = try await generateFromElevatedPrompt(elevated, targetLang: req.genLanguage, wordCount: req.lengthWords, jobId: jobId, jobToken: jobToken)
            }

            // ---- Parse title/body ----
            let (rawTitle0, bodyPrimary0) = extractRawTitleAndBody(from: fullText)

            // Normalize "ALL CAPS" → Title Case if needed
            let normalized = normalizeTitleCaseIfAllCaps(rawTitle0)

            // Enforce short, tidy title (e.g., ≤48 chars and ≤8 words)
            let generatedTitle = shortenTitle(normalized, maxChars: 48, maxWords: 8)

            // Ensure the TARGET-language body is actually in the expected target language
            await progress("Verifying target language…")
            let verifiedTarget = try await enforceLanguageConsistency(
                bodyPrimary0,
                expectedLanguage: req.genLanguage,
                roleDescription: "TARGET",
                jobId: jobId,
                jobToken: jobToken
            )

            // Use the verified body, then normalize dialogue/prose presentation
            let bodyPrimary = normalizeDialoguePresentation(verifiedTarget)

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

            var rawSecondary: String = sameLang
                ? bodyPrimary
                : try await translateParagraphs(bodyPrimary, to: req.transLanguage, style: req.translationStyle, jobId: jobId, jobToken: jobToken)

            if !sameLang {
                await progress("Verifying helper language…")
                rawSecondary = try await enforceLanguageConsistency(
                    rawSecondary,
                    expectedLanguage: req.transLanguage,
                    roleDescription: "HELPER",
                    jobId: jobId,
                    jobToken: jobToken
                )
            }

            // Ensure the HELPER-language text is actually in the expected helper language
            if !sameLang {
                await progress("Verifying helper language…")
                rawSecondary = try await enforceLanguageConsistency(
                    rawSecondary,
                    expectedLanguage: req.transLanguage,
                    roleDescription: "HELPER",
                    jobId: jobId,
                    jobToken: jobToken
                )
            }

            let secondaryText: String = normalizeDialoguePresentation(rawSecondary)

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
                let ptData = try await ttsViaProxy(text: ptSegs[i], language: req.genLanguage, speed: req.speechSpeed, jobId: jobId, jobToken: jobToken)
                try save(ptData, to: base.appendingPathComponent(ptFile))

                try Task.checkCancellation()
                await progress("TTS \(i+1)/\(count) \(req.transLanguage)…")
                let enFile = "\(dst)_\(lessonID)_\(i+1).mp3"
                let enData = try await ttsViaProxy(text: enSegs[i], language: req.transLanguage, speed: req.speechSpeed, jobId: jobId, jobToken: jobToken)
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



