//
//  CEFRGuidance.swift
//  InputMaximizer
//
//  Extracted to make language-specific guidance easier to extend.
//

import Foundation

enum CEFRGuidance {

    /// Returns language-aware CEFR guidance text that can be embedded in prompts.
    static func guidance(level: GeneratorService.Request.LanguageLevel, targetLanguage: String) -> String {
        if isCJKLanguage(targetLanguage) {
            // CJK baseline (language-agnostic)
            switch level {
            case .A1:
                return """
                Use VERY short sentences (3–8 words; one clause). Use only very common, everyday words. Avoid idioms and figurative language. Prefer present-tense, concrete statements with a stable pattern.

                Guidance for beginners:
                • Keep one idea per sentence; no subordinate clauses.
                • Use simple connectors only (and, but, because).
                • Repeat key nouns instead of pronouns to keep reference clear.
                • Avoid rare characters, archaic forms, or literary style.
                • Keep particles/markers minimal and highly conventional.
                • Prefer SVO-like basic patterns and straightforward word order.
                • Use numbers and names in the simplest possible way.
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
                Use VERY short sentences (4–10 words; one clause). Stick to high‑frequency vocabulary. Avoid idioms, phrasal verbs, figurative language, and any complex tense or passive voice.

                Guidance for beginners:
                • One idea per sentence; no subordination or relative clauses.
                • Prefer present tense, active voice, SVO order.
                • Use simple connectors only (and, but, because).
                • Repeat key nouns instead of pronouns to keep reference clear.
                • Prefer concrete nouns and everyday actions.
                • Use only true cognates; avoid false friends.
                • Keep punctuation and capitalization standard and simple.
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

    // MARK: - Language family helpers (expandable)

    static func isCJKLanguage(_ name: String) -> Bool {
        let s = name.lowercased()
        return s.contains("chinese") || s.contains("japanese") || s.contains("korean")
    }

    static func isChineseLanguage(_ name: String) -> Bool {
        let s = name.lowercased()
        return s.contains("chinese")
            || s.contains("mandarin")
            || s.contains("中文")
            || s.contains("简体")
            || s.contains("繁體")
    }
}


