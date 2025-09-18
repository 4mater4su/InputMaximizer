//
//  LessonLanguages.swift
//  InputMaximizer
//
//  Created by Robin Geske on 18.09.25.
//

import Foundation

struct LessonLanguages {
    let targetName: String
    let translationName: String
    let targetCode: String
    let translationCode: String
    let targetShort: String
    let translationShort: String
}

enum LessonLanguageResolver {
    // Maps user-facing language names to codes used for TTS/files.
    static func languageCode(for displayName: String) -> String {
        switch displayName {
        case "Afrikaans": return "af"
        case "Arabic": return "ar"
        case "Armenian": return "hy"
        case "Azerbaijani": return "az"
        case "Belarusian": return "be"
        case "Bosnian": return "bs"
        case "Bulgarian": return "bg"
        case "Catalan": return "ca"
        case "Chinese (Simplified)": return "zh-Hans"
        case "Chinese (Traditional)": return "zh-Hant"
        case "Croatian": return "hr"
        case "Czech": return "cs"
        case "Danish": return "da"
        case "Dutch": return "nl"
        case "English": return "en"
        case "Estonian": return "et"
        case "Finnish": return "fi"
        case "French", "French (Canada)": return "fr"
        case "Galician": return "gl"
        case "German": return "de"
        case "Greek": return "el"
        case "Hebrew": return "he"
        case "Hindi": return "hi"
        case "Hungarian": return "hu"
        case "Icelandic": return "is"
        case "Indonesian": return "id"
        case "Italian": return "it"
        case "Japanese": return "ja"
        case "Kannada": return "kn"
        case "Kazakh": return "kk"
        case "Korean": return "ko"
        case "Latvian": return "lv"
        case "Lithuanian": return "lt"
        case "Macedonian": return "mk"
        case "Malay": return "ms"
        case "Marathi": return "mr"
        case "Maori": return "mi"
        case "Nepali": return "ne"
        case "Norwegian": return "no"
        case "Persian": return "fa"
        case "Polish": return "pl"
        case "Portuguese (Portugal)", "Portuguese (Brazil)": return "pt"
        case "Romanian": return "ro"
        case "Russian": return "ru"
        case "Serbian": return "sr"
        case "Slovak": return "sk"
        case "Slovenian": return "sl"
        case "Spanish", "Spanish (Latinoamérica)", "Spanish (Mexico)": return "es"
        case "Swahili": return "sw"
        case "Swedish": return "sv"
        case "Tagalog": return "tl"
        case "Tamil": return "ta"
        case "Thai": return "th"
        case "Turkish": return "tr"
        case "Ukrainian": return "uk"
        case "Urdu": return "ur"
        case "Vietnamese": return "vi"
        case "Welsh": return "cy"
        default:
            return displayName
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
        }
    }

    /// Short label for UI (safe fallback to display name itself).
    static func shortLabel(for displayName: String) -> String {
        switch displayName {
        case "Afrikaans": return "AF"
        case "Arabic": return "AR"
        case "Armenian": return "HY"
        case "Azerbaijani": return "AZ"
        case "Belarusian": return "BE"
        case "Bosnian": return "BS"
        case "Bulgarian": return "BG"
        case "Catalan": return "CA"
        case "Chinese (Simplified)": return "ZH-Hans"
        case "Chinese (Traditional)": return "ZH-Hant"
        case "Croatian": return "HR"
        case "Czech": return "CS"
        case "Danish": return "DA"
        case "Dutch": return "NL"
        case "English": return "EN"
        case "Estonian": return "ET"
        case "Finnish": return "FI"
        case "French", "French (Canada)": return "FR"
        case "Galician": return "GL"
        case "German": return "DE"
        case "Greek": return "EL"
        case "Hebrew": return "HE"
        case "Hindi": return "HI"
        case "Hungarian": return "HU"
        case "Icelandic": return "IS"
        case "Indonesian": return "ID"
        case "Italian": return "IT"
        case "Japanese": return "JA"
        case "Kannada": return "KN"
        case "Kazakh": return "KK"
        case "Korean": return "KO"
        case "Latvian": return "LV"
        case "Lithuanian": return "LT"
        case "Macedonian": return "MK"
        case "Malay": return "MS"
        case "Marathi": return "MR"
        case "Maori": return "MI"
        case "Nepali": return "NE"
        case "Norwegian": return "NO"
        case "Persian": return "FA"
        case "Polish": return "PL"
        case "Portuguese (Portugal)", "Portuguese (Brazil)": return "PT"
        case "Romanian": return "RO"
        case "Russian": return "RU"
        case "Serbian": return "SR"
        case "Slovak": return "SK"
        case "Slovenian": return "SL"
        case "Spanish", "Spanish (Latinoamérica)", "Spanish (Mexico)": return "ES"
        case "Swahili": return "SW"
        case "Swedish": return "SV"
        case "Tagalog": return "TL"
        case "Tamil": return "TA"
        case "Thai": return "TH"
        case "Turkish": return "TR"
        case "Ukrainian": return "UK"
        case "Urdu": return "UR"
        case "Vietnamese": return "VI"
        case "Welsh": return "CY"
        default:
            return displayName.uppercased()
        }
    }

    
    static func resolve(for lesson: Lesson) -> LessonLanguages {
        let folderURL = FileManager.docsLessonsDir.appendingPathComponent(lesson.folderName, isDirectory: true)
        let metaURL = folderURL.appendingPathComponent("lesson_meta.json")

        // 1) Prefer per-lesson meta
        if let data = try? Data(contentsOf: metaURL),
           let meta = try? JSONDecoder().decode(GeneratorService.LessonMeta.self, from: data) {
            return .init(
                targetName: meta.targetLanguage,
                translationName: meta.translationLanguage,
                targetCode: meta.targetLangCode,
                translationCode: meta.translationLangCode,
                targetShort: meta.targetShort,
                translationShort: meta.translationShort
            )
        }

        // 2) Then use optional fields from lessons.json if present
        if let t = lesson.targetLanguage, let u = lesson.translationLanguage {
            let tCode = lesson.targetLangCode ?? LessonLanguageResolver.languageCode(for: t)
            let uCode = lesson.translationLangCode ?? LessonLanguageResolver.languageCode(for: u)
            return .init(
                targetName: t,
                translationName: u,
                targetCode: tCode,
                translationCode: uCode,
                targetShort: LessonLanguageResolver.shortLabel(for: t),
                translationShort: LessonLanguageResolver.shortLabel(for: u)
            )
        }

        // 3) Last resort for very old content: assume PT ↔ EN
        return .init(
            targetName: "Portuguese (Brazil)",
            translationName: "English",
            targetCode: "pt-BR",
            translationCode: "en",
            targetShort: "PT-BR",
            translationShort: "EN"
        )
    }
}

