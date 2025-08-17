import SwiftUI

@main
struct InputMaximizerApp: App {
    @StateObject private var store = LessonStore()
    var body: some Scene {
        WindowGroup {
            LessonListView()
                .environmentObject(store)
        }
    }
}

