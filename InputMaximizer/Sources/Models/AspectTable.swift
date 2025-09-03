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

// Defaults stay the same; no need to pass isActive because it defaults to true.
extension AspectTable {
    static func defaults() -> AspectTable {
        AspectTable(
            title: "Style Aspects",
            rows: [
                AspectRow(title: "Perspective", options: [
                    AspectOption(label: "First-person"),
                    AspectOption(label: "Second-person"),
                    AspectOption(label: "Third-person")
                ]),
                AspectRow(title: "Tone", options: [
                    AspectOption(label: "Reflective"),
                    AspectOption(label: "Exploratory"),
                    AspectOption(label: "Instructional"),
                    AspectOption(label: "Poetic")
                ]),
                AspectRow(title: "Register", options: [
                    AspectOption(label: "Casual"),
                    AspectOption(label: "Neutral"),
                    AspectOption(label: "Formal")
                ]),
                AspectRow(title: "Form", options: [
                    AspectOption(label: "Field notes"),
                    AspectOption(label: "Essay"),
                    AspectOption(label: "Vignette"),
                    AspectOption(label: "How-to")
                ]),
                AspectRow(title: "Tense", options: [
                    AspectOption(label: "Present"),
                    AspectOption(label: "Past")
                ])
            ]
        )
    }

    static func defaultInterestsRow() -> AspectRow {
        AspectRow(title: "Interest", options: [
            AspectOption(label: "capoeira ao amanhecer"),
            AspectOption(label: "kuzushi no cotidiano"),
            AspectOption(label: "parkour meditativo"),
            AspectOption(label: "songlines como mapas"),
            AspectOption(label: "auroras boreais"),
            AspectOption(label: "tradições ama"),
            AspectOption(label: "corvídeos e trocas"),
            AspectOption(label: "migração de renas"),
            AspectOption(label: "danças de baleias"),
            AspectOption(label: "faróis e guardiões"),
            AspectOption(label: "cerimônias do chá"),
            AspectOption(label: "bibliotecas vivas")
        ])
    }
}
