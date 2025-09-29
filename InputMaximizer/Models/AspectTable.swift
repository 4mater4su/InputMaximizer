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
            return "\(joined)"       //                  return "\(pair.row.title): \(joined)"
        }
        .joined(separator: "\n")   // <-- instead of " • "
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
                // WHAT it is (flow / form)
                AspectRow(title: "Archetype", options: [
                    AspectOption(label: "Story"),
                    AspectOption(label: "Myth"),
                    AspectOption(label: "Dream-journey"),
                    AspectOption(label: "Koan"),
                    AspectOption(label: "Journal entry"),
                    AspectOption(label: "Letter"),
                    AspectOption(label: "Lyric Poem"),
                    AspectOption(label: "Riddle"),
                    AspectOption(label: "Lecture / essay")
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
                
                /*
                // ARCHETYPE: The 64 I Ching hexagrams
                AspectRow(title: "Hexagram Archetype", options: [
                    AspectOption(label: "The Creative (Heaven)"),
                    AspectOption(label: "The Receptive (Earth)"),
                    AspectOption(label: "Difficulty at the Beginning"),
                    AspectOption(label: "Youthful Folly"),
                    AspectOption(label: "Waiting"),
                    AspectOption(label: "Conflict"),
                    AspectOption(label: "The Army"),
                    AspectOption(label: "Holding Together"),
                    AspectOption(label: "Small Taming"),
                    AspectOption(label: "Treading"),
                    AspectOption(label: "Peace"),
                    AspectOption(label: "Standstill"),
                    AspectOption(label: "Fellowship"),
                    AspectOption(label: "Great Possession"),
                    AspectOption(label: "Modesty"),
                    AspectOption(label: "Enthusiasm"),
                    AspectOption(label: "Following"),
                    AspectOption(label: "Work on the Decayed"),
                    AspectOption(label: "Approach"),
                    AspectOption(label: "Contemplation"),
                    AspectOption(label: "Biting Through"),
                    AspectOption(label: "Grace"),
                    AspectOption(label: "Splitting Apart"),
                    AspectOption(label: "Return"),
                    AspectOption(label: "Innocence"),
                    AspectOption(label: "Great Taming"),
                    AspectOption(label: "Nourishment"),
                    AspectOption(label: "Great Exceeding"),
                    AspectOption(label: "The Abysmal (Danger)"),
                    AspectOption(label: "Clinging (Fire)"),
                    AspectOption(label: "Influence"),
                    AspectOption(label: "Duration"),
                    AspectOption(label: "Retreat"),
                    AspectOption(label: "Great Power"),
                    AspectOption(label: "Progress"),
                    AspectOption(label: "Darkening of the Light"),
                    AspectOption(label: "The Family"),
                    AspectOption(label: "Opposition"),
                    AspectOption(label: "Obstruction"),
                    AspectOption(label: "Deliverance"),
                    AspectOption(label: "Decrease"),
                    AspectOption(label: "Increase"),
                    AspectOption(label: "Breakthrough"),
                    AspectOption(label: "Coming to Meet"),
                    AspectOption(label: "Gathering Together"),
                    AspectOption(label: "Pushing Upward"),
                    AspectOption(label: "Oppression"),
                    AspectOption(label: "The Well"),
                    AspectOption(label: "Revolution"),
                    AspectOption(label: "The Cauldron"),
                    AspectOption(label: "The Arousing (Thunder)"),
                    AspectOption(label: "Keeping Still (Mountain)"),
                    AspectOption(label: "Development"),
                    AspectOption(label: "The Marrying Maiden"),
                    AspectOption(label: "Abundance"),
                    AspectOption(label: "The Wanderer"),
                    AspectOption(label: "The Gentle (Wind)"),
                    AspectOption(label: "The Joyous (Lake)"),
                    AspectOption(label: "Dispersion"),
                    AspectOption(label: "Limitation"),
                    AspectOption(label: "Inner Truth"),
                    AspectOption(label: "Small Exceeding"),
                    AspectOption(label: "After Completion"),
                    AspectOption(label: "Before Completion")
                ]),
                */

                /*
                // ARCHETYPE: The 64 I Ching hexagrams
                AspectRow(title: "Hexagram Archetype", options: [
                    AspectOption(label: "䷀ 1 · The Creative (Heaven)"),
                    AspectOption(label: "䷁ 2 · The Receptive (Earth)"),
                    AspectOption(label: "䷂ 3 · Difficulty at the Beginning"),
                    AspectOption(label: "䷃ 4 · Youthful Folly"),
                    AspectOption(label: "䷄ 5 · Waiting"),
                    AspectOption(label: "䷅ 6 · Conflict"),
                    AspectOption(label: "䷆ 7 · The Army"),
                    AspectOption(label: "䷇ 8 · Holding Together"),
                    AspectOption(label: "䷈ 9 · Small Taming"),
                    AspectOption(label: "䷉ 10 · Treading"),
                    AspectOption(label: "䷊ 11 · Peace"),
                    AspectOption(label: "䷋ 12 · Standstill"),
                    AspectOption(label: "䷌ 13 · Fellowship"),
                    AspectOption(label: "䷍ 14 · Great Possession"),
                    AspectOption(label: "䷎ 15 · Modesty"),
                    AspectOption(label: "䷏ 16 · Enthusiasm"),
                    AspectOption(label: "䷐ 17 · Following"),
                    AspectOption(label: "䷑ 18 · Work on the Decayed"),
                    AspectOption(label: "䷒ 19 · Approach"),
                    AspectOption(label: "䷓ 20 · Contemplation"),
                    AspectOption(label: "䷔ 21 · Biting Through"),
                    AspectOption(label: "䷕ 22 · Grace"),
                    AspectOption(label: "䷖ 23 · Splitting Apart"),
                    AspectOption(label: "䷗ 24 · Return"),
                    AspectOption(label: "䷘ 25 · Innocence"),
                    AspectOption(label: "䷙ 26 · Great Taming"),
                    AspectOption(label: "䷚ 27 · Nourishment"),
                    AspectOption(label: "䷛ 28 · Great Exceeding"),
                    AspectOption(label: "䷜ 29 · The Abysmal (Danger)"),
                    AspectOption(label: "䷝ 30 · Clinging (Fire)"),
                    AspectOption(label: "䷞ 31 · Influence"),
                    AspectOption(label: "䷟ 32 · Duration"),
                    AspectOption(label: "䷠ 33 · Retreat"),
                    AspectOption(label: "䷡ 34 · Great Power"),
                    AspectOption(label: "䷢ 35 · Progress"),
                    AspectOption(label: "䷣ 36 · Darkening of the Light"),
                    AspectOption(label: "䷤ 37 · The Family"),
                    AspectOption(label: "䷥ 38 · Opposition"),
                    AspectOption(label: "䷦ 39 · Obstruction"),
                    AspectOption(label: "䷧ 40 · Deliverance"),
                    AspectOption(label: "䷨ 41 · Decrease"),
                    AspectOption(label: "䷩ 42 · Increase"),
                    AspectOption(label: "䷪ 43 · Breakthrough"),
                    AspectOption(label: "䷫ 44 · Coming to Meet"),
                    AspectOption(label: "䷬ 45 · Gathering Together"),
                    AspectOption(label: "䷭ 46 · Pushing Upward"),
                    AspectOption(label: "䷮ 47 · Oppression"),
                    AspectOption(label: "䷯ 48 · The Well"),
                    AspectOption(label: "䷰ 49 · Revolution"),
                    AspectOption(label: "䷱ 50 · The Cauldron"),
                    AspectOption(label: "䷲ 51 · The Arousing (Thunder)"),
                    AspectOption(label: "䷳ 52 · Keeping Still (Mountain)"),
                    AspectOption(label: "䷴ 53 · Development"),
                    AspectOption(label: "䷵ 54 · The Marrying Maiden"),
                    AspectOption(label: "䷶ 55 · Abundance"),
                    AspectOption(label: "䷷ 56 · The Wanderer"),
                    AspectOption(label: "䷸ 57 · The Gentle (Wind)"),
                    AspectOption(label: "䷹ 58 · The Joyous (Lake)"),
                    AspectOption(label: "䷺ 59 · Dispersion"),
                    AspectOption(label: "䷻ 60 · Limitation"),
                    AspectOption(label: "䷼ 61 · Inner Truth"),
                    AspectOption(label: "䷽ 62 · Small Exceeding"),
                    AspectOption(label: "䷾ 63 · After Completion"),
                    AspectOption(label: "䷿ 64 · Before Completion")
                ]),
                */
                
                /*
                // WHERE it happens
                AspectRow(title: "Setting", options: [
                    AspectOption(label: "Sea / Coast"),
                    AspectOption(label: "Mountains"),
                    AspectOption(label: "Forest"),
                    AspectOption(label: "Desert"),
                    AspectOption(label: "River / Lake"),
                    AspectOption(label: "City"),
                    AspectOption(label: "Village / Small town"),
                    AspectOption(label: "Temple / Monastery"),
                    AspectOption(label: "Market / Festival"),
                    AspectOption(label: "Library / Archive"),
                    AspectOption(label: "Workshop / Lab"),
                    AspectOption(label: "Court / Palace"),
                    AspectOption(label: "Battlefield / Frontier"),
                    AspectOption(label: "Home / Domestic space"),
                    AspectOption(label: "Road / Journey"),
                    AspectOption(label: "Wilderness Edge / Threshold"),
                    AspectOption(label: "Dreamscape"),
                    AspectOption(label: "Underworld"),
                    AspectOption(label: "Space Station / Starship"),
                    AspectOption(label: "Alien World")
                ]),
                 */

                /*
                // WHEN it happens
                AspectRow(title: "Timeframe", options: [
                    AspectOption(label: "Mythic past"),
                    AspectOption(label: "Historical past"),
                    AspectOption(label: "Present"),
                    AspectOption(label: "Near future"),
                    AspectOption(label: "Far future"),
                    AspectOption(label: "Timeless")
                ]),
                 */

                /*
                // HOW FAR IN / OUT we zoom (recursion levels)
                AspectRow(title: "Scale / Recursion", options: [
                    AspectOption(label: "Cosmic (galaxies, creation, entropy)"),
                    AspectOption(label: "Planetary (worlds, climates, ecosystems)"),
                    AspectOption(label: "Civilizational (nations, cultures, histories)"),
                    AspectOption(label: "Communal (cities, tribes, gatherings)"),
                    AspectOption(label: "Interpersonal (dialogues, relationships)"),
                    AspectOption(label: "Personal (self, inner life, body)"),
                    AspectOption(label: "Microcosmic (cells, insects, hidden processes)"),
                    AspectOption(label: "Elemental (fire, water, wind, stone)"),
                    AspectOption(label: "Systemic (networks, economies, ecologies)"),
                    AspectOption(label: "Abstract / Archetypal (concepts, forces, patterns)")
                ]),
                */

            ]
        )
    }

    static func defaultInterestsRow() -> AspectRow {
        AspectRow(title: "Interests", options: [
            AspectOption(label: "Living with the Sámi in Lapland, learning dog sledding and reading the aurora"),
            AspectOption(label: "Joining a desert caravan, following stars and singing the water songs"),
            AspectOption(label: "Working with beekeepers, listening to the hive’s hum as language"),
            AspectOption(label: "Sailing with Polynesian navigators, steering by swells and constellations"),
            AspectOption(label: "Spending a season in a Zen monastery, sweeping leaves as meditation"),
            AspectOption(label: "Learning calligraphy from a master, where each stroke teaches patience"),
            AspectOption(label: "Exploring ancient ruins with archaeologists, unearthing forgotten gestures"),
            AspectOption(label: "Traveling on the Trans-Siberian Railway, gathering stories from strangers"),
            AspectOption(label: "Helping rewild a forest, tracking wolves and planting forgotten seeds"),
            AspectOption(label: "Joining astronomers on a mountaintop, watching galaxies rise through thin air"),
            
            AspectOption(label: "Fishing with Inuit elders through ice holes, listening for seals beneath the floes"),
            AspectOption(label: "Walking pilgrimage routes in Spain, tracing footsteps worn smooth by centuries"),
            AspectOption(label: "Learning falconry in the desert, releasing a hawk into boundless sky"),
            AspectOption(label: "Diving into coral reefs with marine biologists, mapping colors as living archives"),
            AspectOption(label: "Wandering Himalayan trails with monks, reading prayers carved into stones"),
            AspectOption(label: "Harvesting olives in the Mediterranean, tasting history in the first press"),
            AspectOption(label: "Crossing the savanna with herders, reading clouds for rain signs"),
            AspectOption(label: "Studying tea ceremonies in Kyoto, silence flowing between gestures"),
            AspectOption(label: "Living in a lighthouse, listening to the rhythm of waves and foghorns"),
            AspectOption(label: "Practicing archery in Bhutan, each arrow a breath released"),
            
            AspectOption(label: "Following elephants with trackers in Botswana, moving in respectful silence"),
            AspectOption(label: "Joining storytellers around a Saharan fire, trading myths for dates and tea"),
            AspectOption(label: "Herding yaks on the Tibetan plateau, watching shadows stretch across glaciers"),
            AspectOption(label: "Learning woodblock printing in a riverside village, carving memory into grain"),
            AspectOption(label: "Canoeing through Amazon tributaries, hearing howler monkeys call the dawn"),
            AspectOption(label: "Training with flamenco dancers in Andalusia, learning rhythm from footsteps"),
            AspectOption(label: "Collecting herbs with shamans in the Andes, naming each plant by its spirit"),
            AspectOption(label: "Tending rice terraces in Bali, listening to water temples guide the flow"),
            AspectOption(label: "Riding horses with Mongolian nomads, sleeping beneath endless sky"),
            AspectOption(label: "Watching fireflies gather in summer forests, translating their light into music"),
            
            AspectOption(label: "Learning to weave with Andean artisans, each pattern a story of mountains"),
            AspectOption(label: "Sharing bread in a Syrian courtyard, recipes carried through exile"),
            AspectOption(label: "Sleeping in hammocks with sailors, rocking to ocean’s hidden clock"),
            AspectOption(label: "Exploring Icelandic lava fields, steam rising like messages from earth"),
            AspectOption(label: "Practicing drumming in West Africa, heartbeat teaching community"),
            AspectOption(label: "Following salmon upstream with First Nations fishers, marking cycles of return"),
            AspectOption(label: "Planting trees with children in Kenya, each sapling a promise"),
            AspectOption(label: "Singing in Georgian choirs, voices weaving mountains into harmony"),
            AspectOption(label: "Joining shepherds in Provence, bells echoing across lavender fields"),
            AspectOption(label: "Sitting with desert hermits, silence thick as stone"),
            
            AspectOption(label: "Following fire-walkers in Polynesia, watching embers become prayer"),
            AspectOption(label: "Practicing sword forms in a Japanese dojo, cutting through illusion"),
            AspectOption(label: "Walking rice fields in Vietnam, dragonflies guiding the harvest"),
            AspectOption(label: "Stargazing in the Atacama desert, thin air revealing infinity"),
            AspectOption(label: "Visiting a Sufi lodge, whirling with dervishes until thought dissolves"),
            AspectOption(label: "Listening to whalesong from a kayak, the sea itself speaking"),
            AspectOption(label: "Building yurts with Kazakh nomads, round walls against the wind"),
            AspectOption(label: "Sitting in Irish pubs, learning ballads that carry centuries"),
            AspectOption(label: "Meditating in caves above the Ganges, river echoing in stone"),
            AspectOption(label: "Brewing coffee in Ethiopia, fire and aroma binding community"),
            
            AspectOption(label: "Foraging mushrooms in Finnish forests, learning which ones whisper safety"),
            AspectOption(label: "Crossing Siberian taiga by sled, wolves pacing at the tree line"),
            AspectOption(label: "Wandering Marrakech souks, spices writing the air"),
            AspectOption(label: "Planting rice in Laos, barefoot with farmers, mud binding kinship"),
            AspectOption(label: "Following jaguars with trackers in the Pantanal, silence as weapon"),
            AspectOption(label: "Praying at dawn in Jerusalem, bells and calls weaving sky"),
            AspectOption(label: "Joining Masai warriors, learning to jump into courage"),
            AspectOption(label: "Reading constellations with Australian elders, the sky a map of law"),
            AspectOption(label: "Helping monks paint mandalas, colors arranged into impermanence"),
            AspectOption(label: "Riding camels along the Silk Road, trading silk for stories"),
            
            AspectOption(label: "Exploring shipwrecks with divers in the Mediterranean, touching rusted history"),
            AspectOption(label: "Attending Day of the Dead in Oaxaca, offerings bridging the unseen"),
            AspectOption(label: "Tending goats on Greek islands, bells echoing over blue sea"),
            AspectOption(label: "Writing poems in Kyoto gardens, cherry blossoms scattering their replies")
        ])
    }

}


