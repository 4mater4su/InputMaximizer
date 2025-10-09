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
    @StateObject private var seriesStore = SeriesMetadataStore()
    
    // Generation queue (created after dependencies)
    @StateObject private var generationQueue: GenerationQueue
    
    init() {
        // Initialize dependent stores first
        let lessonStore = LessonStore()
        let folderStore = FolderStore()
        let generator = GeneratorService()
        let seriesStore = SeriesMetadataStore()
        
        _lessonStore = StateObject(wrappedValue: lessonStore)
        _folderStore = StateObject(wrappedValue: folderStore)
        _generator = StateObject(wrappedValue: generator)
        _seriesStore = StateObject(wrappedValue: seriesStore)
        _audioManager = StateObject(wrappedValue: AudioManager())
        _purchases = StateObject(wrappedValue: PurchaseManager())
        
        // Create queue with dependencies
        _generationQueue = StateObject(wrappedValue: GenerationQueue(
            generator: generator,
            lessonStore: lessonStore,
            seriesStore: seriesStore,
            folderStore: folderStore
        ))
    }

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
                .environmentObject(seriesStore)
                .environmentObject(generationQueue)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}
