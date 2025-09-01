// input_maximizerApp.swift

import SwiftUI

@main
struct input_maximizerApp: App {
    @StateObject private var audioManager = AudioManager()
    @StateObject private var lessonStore = LessonStore()
    @StateObject private var folderStore = FolderStore()

    var body: some Scene {
        WindowGroup {
            LessonSelectionView()
                .environmentObject(audioManager)
                .environmentObject(lessonStore)
                .environmentObject(folderStore)
        }
    }
}


