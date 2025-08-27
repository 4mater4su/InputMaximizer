//
//  FileManager+Lessons.swift
//  InputMaximizer
//
//  Created by Robin Geske on 27.08.25.
//

import Foundation

extension FileManager {
    /// Path to the app's Documents directory
    static var appDocs: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// Path to the Lessons folder inside Documents
    static var docsLessonsDir: URL {
        appDocs.appendingPathComponent("Lessons", isDirectory: true)
    }

    /// Ensure Lessons folder exists in Documents
    static func ensureLessonsDir() {
        try? FileManager.default.createDirectory(
            at: docsLessonsDir,
            withIntermediateDirectories: true
        )
    }
}
