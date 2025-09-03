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

struct AspectRow: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var options: [AspectOption]
    var pickOne: Bool = true
}

struct AspectTable: Equatable, Codable {
    var title: String = "Style Aspects"
    var rows: [AspectRow] = []

    mutating func enableAll() {
        for i in rows.indices {
            for j in rows[i].options.indices {
                rows[i].options[j].enabled = true
            }
        }
    }
    mutating func disableAll() {
        for i in rows.indices {
            for j in rows[i].options.indices {
                rows[i].options[j].enabled = false
            }
        }
    }

    func randomSelection() -> [(row: AspectRow, picked: [AspectOption])] {
        rows.map { row in
            let enabled = row.options.filter { $0.enabled }
            guard !enabled.isEmpty else { return (row, []) }
            if row.pickOne {
                return (row, [enabled.randomElement()!])
            } else {
                let count = Int.random(in: 1...enabled.count)
                return (row, Array(enabled.shuffled().prefix(count)))
            }
        }
    }

    func renderSeed(from selection: [(row: AspectRow, picked: [AspectOption])]) -> String {
        selection
            .filter { !$0.picked.isEmpty }
            .map { pair in
                let joined = pair.picked.map { $0.label }.joined(separator: ", ")
                return "\(pair.row.title): \(joined)"
            }
            .joined(separator: " • ")
    }
}

extension AspectTable {
    static func defaults() -> AspectTable {
        AspectTable(
            title: "Style Aspects",
            rows: [
                AspectRow(title: "Perspective", options: [
                    AspectOption(label: "First-person"),
                    AspectOption(label: "Second-person"),
                    AspectOption(label: "Third-person")
                ], pickOne: true),
                AspectRow(title: "Tone", options: [
                    AspectOption(label: "Reflective"),
                    AspectOption(label: "Exploratory"),
                    AspectOption(label: "Instructional"),
                    AspectOption(label: "Poetic")
                ], pickOne: true),
                AspectRow(title: "Register", options: [
                    AspectOption(label: "Casual"),
                    AspectOption(label: "Neutral"),
                    AspectOption(label: "Formal")
                ], pickOne: true),
                AspectRow(title: "Form", options: [
                    AspectOption(label: "Field notes"),
                    AspectOption(label: "Essay"),
                    AspectOption(label: "Vignette"),
                    AspectOption(label: "How-to")
                ], pickOne: true),
                AspectRow(title: "Tense", options: [
                    AspectOption(label: "Present"),
                    AspectOption(label: "Past")
                ], pickOne: true)
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
        ], pickOne: true)
    }
}
