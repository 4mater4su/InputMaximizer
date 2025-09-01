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
}
