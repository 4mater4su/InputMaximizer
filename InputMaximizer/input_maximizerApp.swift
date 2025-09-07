//
// input_maximizerApp.swift
//  InputMaximizer
//
//  Created by Robin Geske on 01.09.25.
//

import SwiftUI

@main
struct input_maximizerApp: App {
    @StateObject private var audioManager = AudioManager()
    @StateObject private var lessonStore = LessonStore()
    @StateObject private var folderStore = FolderStore()
    @StateObject private var generator = GeneratorService()
    @StateObject private var purchases = PurchaseManager()

    // Saved appearance choice (defaults to System)
    @AppStorage("appearancePreference") private var appearanceRaw: String = AppearancePreference.system.rawValue
    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .system
    }
    
    var body: some Scene {
        WindowGroup {
            LessonSelectionView()
                .environmentObject(audioManager)
                .environmentObject(lessonStore)
                .environmentObject(folderStore)
                .environmentObject(generator)
                .environmentObject(purchases)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}
