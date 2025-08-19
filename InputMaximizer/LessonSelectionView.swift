//
//  LessonSelectionView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 18.08.25.
//

import SwiftUI

struct LessonSelectionView: View {
    @EnvironmentObject private var audioManager: AudioManager
    @StateObject private var store = LessonStore()
    @State private var selectedLesson: Lesson?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    if store.lessons.isEmpty {
                        Text("No lessons found.\nAdd entries to Lessons/lessons.json.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                            .padding(.top, 40)
                    } else {
                        ForEach(store.lessons) { lesson in
                            Button {
                                audioManager.stop()
                                selectedLesson = lesson
                            } label: {
                                Text(lesson.title)
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Select a Lesson")
            .background(
                NavigationLink(
                    destination: ContentView(
                        selectedLesson: selectedLesson ?? store.lessons.first!,
                        lessons: store.lessons
                    )
                    .environmentObject(audioManager),
                    isActive: Binding(
                        get: { selectedLesson != nil },
                        set: { if !$0 { selectedLesson = nil } }
                    )
                ) { EmptyView() }
            )
        }
    }
}
