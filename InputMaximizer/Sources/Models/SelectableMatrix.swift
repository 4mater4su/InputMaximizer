//
//  SelectableMatrix.swift
//  InputMaximizer
//
//  Created by Robin Geske on 03.09.25.
//

import Foundation

struct MatrixCell: Hashable, Codable { let r: Int; let c: Int }

struct SelectableMatrix: Equatable, Codable {
    var title: String
    var rows: [String]
    var cols: [String]
    var enabled: Set<MatrixCell> = []

    mutating func enableAll() { enabled = allCells() }
    mutating func disableAll() { enabled.removeAll() }

    func allCells() -> Set<MatrixCell> {
        var s = Set<MatrixCell>()
        for r in rows.indices { for c in cols.indices { s.insert(.init(r: r, c: c)) } }
        return s
    }
    func randomCell() -> MatrixCell? {
        if !enabled.isEmpty { return enabled.randomElement() }
        let all = allCells()
        return all.isEmpty ? nil : all.randomElement()
    }
    func label(for cell: MatrixCell) -> String {
        guard rows.indices.contains(cell.r), cols.indices.contains(cell.c) else { return "" }
        return "\(rows[cell.r]) — \(cols[cell.c])"
    }
}

extension SelectableMatrix {
    static func defaultStyle() -> SelectableMatrix {
        var m = SelectableMatrix(
            title: "Style / Perspective",
            rows: ["Narrative","Exploratory","Instructional","Reflective"],
            cols: ["First-person","Third-person","Field notes","Poetic register"]
        )
        m.enableAll()
        return m
    }

    static func defaultInterests() -> SelectableMatrix {
        var m = SelectableMatrix(
            title: "Interests / Manifestations",
            rows: ["Movement & Embodiment","Navigation & Orientation","Ecology & Animal Kinship","Cultural Practices"],
            cols: ["capoeira ao amanhecer","kuzushi no cotidiano","parkour meditativo",
                   "songlines como mapas","auroras boreais","tradições ama",
                   "corvídeos e trocas","migração de renas","danças de baleias",
                   "faróis e guardiões","cerimônias do chá","bibliotecas vivas"]
        )
        m.enableAll()
        return m
    }
}
