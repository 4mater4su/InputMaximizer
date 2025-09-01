//
//  Segment.swift
//  InputMaximizer
//
//  Created by Robin Geske on 01.09.25.
//

import Foundation

struct Segment: Codable, Identifiable {
    let id: Int
    let pt_text: String
    let en_text: String
    let pt_file: String
    let en_file: String
    let paragraph: Int

    private enum CodingKeys: String, CodingKey {
        case id, pt_text, en_text, pt_file, en_file, paragraph
    }

    init(id: Int, pt_text: String, en_text: String, pt_file: String, en_file: String, paragraph: Int = 0) {
        self.id = id; self.pt_text = pt_text; self.en_text = en_text
        self.pt_file = pt_file; self.en_file = en_file; self.paragraph = paragraph
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        pt_text = try c.decode(String.self, forKey: .pt_text)
        en_text = try c.decode(String.self, forKey: .en_text)
        pt_file = try c.decode(String.self, forKey: .pt_file)
        en_file = try c.decode(String.self, forKey: .en_file)
        paragraph = try c.decodeIfPresent(Int.self, forKey: .paragraph) ?? 0
    }
}
