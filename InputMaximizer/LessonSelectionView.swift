//
//  LessonSelectionView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 18.08.25.
//

import SwiftUICore
import SwiftUI

struct LessonSelectionView: View {
    @State private var selectedLesson: Lesson?
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(availableLessons) { lesson in
                        Button(action: {
                            selectedLesson = lesson
                        }) {
                            Text(lesson.title)
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(12)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding()
            }
            .navigationTitle("Select a Lesson")
            .background(
                NavigationLink(
                    destination: ContentView(selectedLesson: selectedLesson ?? availableLessons.first!),
                    isActive: Binding<Bool>(
                        get: { selectedLesson != nil },
                        set: { if !$0 { selectedLesson = nil } }
                    )
                ) {
                    EmptyView()
                }
            )
        }
    }
}
