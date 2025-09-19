//
//  AspectTable.swift
//  InputMaximizer
//
//  Created by Robin Geske on 03.09.25.
//

import Foundation

struct AspectOption: Identifiable, Hashable, Codable {
    var id = UUID()
    var label: String
    var enabled: Bool = true
}

// NEW: single include switch per row
struct AspectRow: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var options: [AspectOption]
    var isActive: Bool = true

    // Back-compat: if old data had pickOne or mode, map them into isActive.
    enum CodingKeys: String, CodingKey { case id, title, options, isActive, pickOne, mode }

    init(id: UUID = UUID(), title: String, options: [AspectOption], isActive: Bool = true) {
        self.id = id
        self.title = title
        self.options = options
        self.isActive = isActive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id      = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title   = try c.decode(String.self, forKey: .title)
        options = try c.decode([AspectOption].self, forKey: .options)

        if let active = try c.decodeIfPresent(Bool.self, forKey: .isActive) {
            isActive = active
        } else if let mode = try c.decodeIfPresent(String.self, forKey: .mode) {
            // any mode except "off" is treated as active
            isActive = mode != "off"
        } else {
            // if old data only had pickOne, assume it was active
            _ = try c.decodeIfPresent(Bool.self, forKey: .pickOne)
            isActive = true
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(options, forKey: .options)
        try c.encode(isActive, forKey: .isActive)
    }
}

struct AspectTable: Equatable, Codable {
    var title: String = "Style Aspects"
    var rows: [AspectRow] = []

    mutating func enableAll() {
        // Reassign rows so SwiftUI sees a new value
        rows = rows.map { row in
            var r = row
            r.isActive = true
            r.options = r.options.map { opt in
                var o = opt; o.enabled = true; return o
            }
            return r
        }
    }

    mutating func disableAll() {
        rows = rows.map { row in
            var r = row
            r.isActive = false
            r.options = r.options.map { opt in
                var o = opt; o.enabled = false; return o
            }
            return r
        }
    }

    /// Picks exactly ONE enabled option per active row. Skips inactive or empty rows.
    func randomSelection() -> [(row: AspectRow, picked: [AspectOption])] {
        rows.compactMap { row in
            guard row.isActive else { return nil }
            let enabled = row.options.filter { $0.enabled }
            guard let one = enabled.randomElement() else { return nil }
            return (row, [one])
        }
    }

    func renderSeed(from selection: [(row: AspectRow, picked: [AspectOption])]) -> String {
        selection.map { pair in
            let joined = pair.picked.map(\.label).joined(separator: ", ")
            return "\(pair.row.title): \(joined)"
        }
        .joined(separator: " • ")
    }
}

// MARK: - Richer default pool for Random mode
extension AspectTable {
    /// A compact but powerful default table for varied random generation.
    /// Roughly 10x10x5x5 combos across archetype/tone/perspective/mood before structure/purpose/constraints multiply it further.
    static func defaults() -> AspectTable {
        AspectTable(
            title: "Style Aspects",
            rows: [
                // WHAT it is
                AspectRow(title: "Archetype", options: [
                    AspectOption(label: "Short story"),
                    AspectOption(label: "Poem"),
                    AspectOption(label: "Joke or riddle"),
                    AspectOption(label: "News article"),
                    AspectOption(label: "Letter / diary entry"),
                    AspectOption(label: "Review"),
                    AspectOption(label: "Speech / manifesto")
                ]),

                // HOW it feels
                AspectRow(title: "Tone / Style", options: [
                    AspectOption(label: "Humorous / ironic"),
                    AspectOption(label: "Dramatic / emotional"),
                    AspectOption(label: "Inspirational / motivational"),
                    AspectOption(label: "Neutral / factual"),
                    AspectOption(label: "Suspenseful / mysterious"),
                    AspectOption(label: "Whimsical / surreal"),
                    AspectOption(label: "Persuasive / opinionated")
                ]),

                // VOICE & FEEL
                AspectRow(title: "Perspective", options: [
                    AspectOption(label: "First-person"),
                    AspectOption(label: "Second-person"),
                    AspectOption(label: "Third-person"),
                    AspectOption(label: "Stream of consciousness")
                ]),

                // A little spice for surprise
                AspectRow(title: "Constraint", options: [
                    AspectOption(label: "Start in medias res"),
                    AspectOption(label: "Include a twist ending"),
                    AspectOption(label: "Use a recurring motif"),
                    AspectOption(label: "End with a question"),
                ])
            ]
        )
    }

    static func defaultInterestsRow() -> AspectRow {
        AspectRow(title: "Interests", options: [
            AspectOption(label: "Morning routines"),
            AspectOption(label: "Cooking experiments"),
            AspectOption(label: "Street food adventures"),
            AspectOption(label: "Urban gardening"),
            AspectOption(label: "Coffee rituals"),
            AspectOption(label: "Fitness hacks"),
            AspectOption(label: "Minimalist living"),
            AspectOption(label: "Learning a new language"),
            AspectOption(label: "Parenting challenges"),
            AspectOption(label: "Work-life balance"),
            AspectOption(label: "Hiking trails"),
            AspectOption(label: "Ocean waves"),
            AspectOption(label: "Desert sunsets"),
            AspectOption(label: "Star gazing"),
            AspectOption(label: "Rainforest sounds"),
            AspectOption(label: "Bird watching"),
            AspectOption(label: "Mountain climbing"),
            AspectOption(label: "Gardening in small spaces"),
            AspectOption(label: "Seasons changing"),
            AspectOption(label: "Camping under the stars"),
            AspectOption(label: "Painting with colors of memory"),
            AspectOption(label: "Street photography"),
            AspectOption(label: "DIY crafts"),
            AspectOption(label: "Writing poetry"),
            AspectOption(label: "Playing an instrument"),
            AspectOption(label: "Calligraphy"),
            AspectOption(label: "Theater performances"),
            AspectOption(label: "Storytelling traditions"),
            AspectOption(label: "Fashion as self-expression"),
            AspectOption(label: "Architecture of cities"),
            AspectOption(label: "Ancient ruins"),
            AspectOption(label: "Local markets"),
            AspectOption(label: "Train journeys"),
            AspectOption(label: "Festivals of light"),
            AspectOption(label: "Street musicians"),
            AspectOption(label: "Castles and legends"),
            AspectOption(label: "Nomadic lifestyles"),
            AspectOption(label: "Cultural food rituals"),
            AspectOption(label: "Hidden alleyways"),
            AspectOption(label: "Futuristic cities"),
            AspectOption(label: "Space exploration"),
            AspectOption(label: "Artificial intelligence"),
            AspectOption(label: "Climate change solutions"),
            AspectOption(label: "Renewable energy"),
            AspectOption(label: "Virtual reality adventures"),
            AspectOption(label: "Time travel paradoxes"),
            AspectOption(label: "Philosophy of happiness"),
            AspectOption(label: "Mindfulness practices"),
            AspectOption(label: "Myths vs. science"),
            AspectOption(label: "The future of work")
        ])
    }
}


