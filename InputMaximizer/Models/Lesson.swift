//
//  Lesson.swift
//  InputMaximizer
//
//  Created by Robin Geske on 01.09.25.
//

import Foundation

struct Lesson: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let folderName: String
    
    // NEW (optional to keep old lessons decoding fine)
    var targetLanguage: String?          // e.g., "Portuguese (Brazil)"
    var translationLanguage: String?     // e.g., "English"
    var targetLangCode: String?          // e.g., "pt-BR" or "zh-Hans"
    var translationLangCode: String?     // e.g., "en", "es-419"
}

// convenience for ForEach with custom id use
extension Lesson { var _id: String { id } }
