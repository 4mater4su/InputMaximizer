import SwiftUI

@main
struct input_maximizerApp: App {
    @StateObject private var audioManager = AudioManager()
    
    var body: some Scene {
        WindowGroup {
            LessonSelectionView()
                .environmentObject(audioManager)
        }
    }
}

