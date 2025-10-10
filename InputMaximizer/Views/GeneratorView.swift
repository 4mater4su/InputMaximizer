//
//  GeneratorView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 27.08.25.
//

import SwiftUI
import Foundation

// MARK: - Generator View

extension GeneratorService.Request.SpeechSpeed: Identifiable {
    public var id: String { rawValue }
}

typealias LanguageLevel = GeneratorService.Request.LanguageLevel

extension GeneratorService.Request.LanguageLevel: Identifiable {
    public var id: String { rawValue }
}

typealias TranslationStyle = GeneratorService.Request.TranslationStyle

extension GeneratorService.Request.TranslationStyle: Identifiable {
    public var id: String { rawValue }
}

// MARK: - Persisted settings

private struct GeneratorSettings: Codable, Equatable {
    var mode: String
    var segmentation: String
    var lengthPresetRaw: Int
    var genLanguage: String
    var transLanguage: String
    var languageLevel: String
    var speechSpeed: String
    var translationStyle: String
}

private extension GeneratorSettings {
    static func fromViewState(
        mode: GeneratorView.GenerationMode,
        segmentation: GeneratorView.Segmentation,
        lengthPreset: GeneratorView.LengthPreset,
        genLanguage: String,
        transLanguage: String,
        languageLevel: LanguageLevel,
        speechSpeed: GeneratorView.SpeechSpeed,
        translationStyle: TranslationStyle
    ) -> GeneratorSettings {
        .init(
            mode: mode.rawValue,
            segmentation: segmentation.rawValue,
            lengthPresetRaw: lengthPreset.rawValue,
            genLanguage: genLanguage,
            transLanguage: transLanguage,
            languageLevel: languageLevel.rawValue,
            speechSpeed: speechSpeed.rawValue,
            translationStyle: translationStyle.rawValue
        )
    }
}


struct GeneratorView: View {
    @EnvironmentObject private var purchases: PurchaseManager
    @State private var showBuyCredits = false
    
    @EnvironmentObject private var lessonStore: LessonStore
    @EnvironmentObject private var folderStore: FolderStore
    @EnvironmentObject private var generator: GeneratorService
    @Environment(\.dismiss) private var dismiss

    // Persistence for aspect selections
    @AppStorage("styleTableJSON") private var styleTableJSON: Data = Data()
    @AppStorage("interestRowJSON") private var interestRowJSON: Data = Data()
    
    // Persist all generator knobs in one blob
    @AppStorage("generatorSettingsV1") private var generatorSettingsData: Data = Data()
    
    @AppStorage("generatorPromptV1") private var userPrompt: String = ""
    @AppStorage("generatorRandomTopicV1") private var randomTopic: String = ""

    // Persisted toggle for the Advanced dropdown
    @AppStorage("generatorAdvancedExpandedV1") private var advancedExpandedStore: Bool = false

    // Local binding that connects @AppStorage to the environment
    private var advancedExpandedBinding: Binding<Bool> {
        Binding(
            get: { advancedExpandedStore },
            set: { advancedExpandedStore = $0 }
        )
    }
    
    @Environment(\.horizontalSizeClass) private var hSize
    
    // MARK: - Length preset
    enum LengthPreset: Int, CaseIterable, Identifiable {
        case short, medium, long
        
        var id: Int { rawValue }
        
        var label: String {
            switch self {
            case .short:     return "Short"
            case .medium:    return "Medium"
            case .long:      return "Long"
            }
        }
        
        var words: Int {
            switch self {
            case .short:     return 100
            case .medium:    return 200
            case .long:      return 300
            }
        }
    }

    @State private var showSegmentationInfo = false
    @State private var showModeInfo = false
    @State private var showTranslationStyleInfo = false

    
    @State private var lengthPreset: LengthPreset = .medium

    // MARK: - State
    // Present one sheet at a time, from the root (not on the Button).
    private enum ActiveSheet: Identifiable {
        case buyCredits
        var id: String { String(describing: self) }
    }

    @State private var activeSheet: ActiveSheet?

    @State private var serverBalance: Int = 0
    @State private var balanceError: String?

    @MainActor
    private func refreshServerBalance() async {
        do {
            serverBalance = try await GeneratorService.fetchServerBalance()
            balanceError = nil
        } catch {
            balanceError = error.localizedDescription
        }
    }
    
    // Auto-filled from model output
    @State private var lessonID: String = "Lesson001"
    @State private var title: String = ""          // filled from generated PT title

    @State private var genLanguage: String = "Portuguese (Brazil)"
    @State private var transLanguage: String = "English"

    @State private var languageLevel: LanguageLevel = .B1

    // NEW: aspect states
    @State private var styleTable: AspectTable = .defaults()
    @State private var interestRow: AspectRow = AspectTable.defaultInterestsRow()
    @State private var showConfigurator = false

    @State private var knownLessonIDs = Set<String>()
    @State private var newlyCreatedLesson: Lesson?     // lesson to show in the toast
    @State private var showToast: Bool = false
    @State private var navTargetLesson: Lesson?        // drives navigationDestination
    @State private var navTargetFolder: Folder?        // drives folder navigation
    @State private var toastHideWork: DispatchWorkItem?
    
    @FocusState private var promptIsFocused: Bool
    
    @AppStorage("generatorSuggestionsExpandedV1") private var suggestionsExpanded: Bool = false
    @State private var suggestionsFeed: [String] = []
    
    @State private var showPromptBrainstorm = false
    
    // Long-form generation
    @State private var enableLongForm = false
    @State private var longFormTotalWords = 1200

    private var hasSuggestions: Bool {
        !suggestionsFeed.isEmpty
    }

    private let supportedLanguages: [String] = [
        "Afrikaans","Arabic (Egypt)","Arabic (Gulf)","Arabic (Levantine)","Arabic (Maghrebi)","Arabic (Modern Standard)","Armenian","Azerbaijani","Belarusian","Bosnian","Bulgarian","Catalan",
        "Chinese (Cantonese - Traditional)","Chinese (Mandarin - Simplified)","Chinese (Mandarin - Traditional)","Croatian",
        "Czech","Danish","Dutch","English (Australia)","English (India)","English (UK)","English (US)","Estonian","Finnish","French", "French (Canada)","Galician",
        "German","German (Austria)","German (Switzerland)","Greek","Hebrew","Hindi",
        "Hungarian","Icelandic","Indonesian","Italian","Japanese","Kannada","Kazakh","Korean","Latvian","Lithuanian",
        "Macedonian","Malay (Malaysia)","Marathi","Maori","Nepali","Norwegian (Bokmål)","Norwegian (Nynorsk)","Persian (Dari)","Persian (Tajik)","Polish","Portuguese (Portugal)","Portuguese (Brazil)","Romanian","Russian",
        "Serbian","Slovak","Slovenian","Spanish (Argentina)","Spanish (Latinoamérica)","Spanish (Mexico)","Spanish (Spain)","Swahili (Kenya)","Swahili (Tanzania)","Swedish","Tagalog","Tamil","Thai","Turkish","Ukrainian",
        "Urdu","Vietnamese (Northern)","Vietnamese (Southern)","Welsh"
    ]

    // Modes
    enum GenerationMode: String, CaseIterable, Identifiable {
        case prompt = "Prompt"
        case random = "Random"
        var id: String { rawValue }
    }
    @State private var mode: GenerationMode = .prompt
    
    // MARK: - Segmentation
    enum Segmentation: String, CaseIterable, Identifiable {
        case sentences = "Sentences"
        case paragraphs = "Paragraphs"
        var id: String { rawValue }
    }
    @State private var segmentation: Segmentation = .sentences

    // Reuse the same enum so there’s no mismatch.
    typealias SpeechSpeed = GeneratorService.Request.SpeechSpeed

    @State private var speechSpeed: SpeechSpeed = .slow

    @State private var translationStyle: TranslationStyle = .idiomatic
    
    // MARK: - Prompt categories (I Ching trigrams)

    enum PromptCategory: String, CaseIterable, Identifiable {
        case all = "All"
        case sleep = "Sleep"
        case voyage = "Voyage"
        case city = "City"
        case wild = "Wild"
        case myth = "Myth"
        case water = "Water"
        case night = "Night"
        case cosmos = "Cosmos"
        case time = "Time"
        case philosophy = "Philosophy"
        case practice = "Practice"

        var id: String { rawValue }
    }

    @State private var selectedPromptCategory: PromptCategory = .all

    private let promptsByCategory: [PromptCategory: [String]] = [

        // --- Sleep (soothing dream voyages, bedtime journeys) ---
        .sleep: [
            "Write a calming bedtime story where the listener boards a gentle starship that hums quietly as it glides past constellations. The journey begins above misty wetlands and drifts through the night sky toward a tranquil planet of rolling hills and glowing lakes.",
            
            "Describe a peaceful voyage on the back of a giant turtle drifting across a moonlit ocean. The stars shimmer above, the waves move in a steady rhythm, and each moment invites rest and stillness.",
            
            "Write a bedtime journey aboard a slow-floating airship sailing above lantern-lit cities. The engines breathe softly, the lights below flicker like fireflies, and the horizon stretches endlessly in calm night air.",
            
            "Guide the listener through a dreamlike walk across a meadow of bioluminescent flowers. Each step stirs a soft glow, and the air is filled with gentle, otherworldly music that encourages deep relaxation.",
            
            "Tell a soothing story of drifting through quiet canals in a starlit city built on water. The boat glides under arched bridges, moonlight ripples on the surface, and the sounds of the world fade into silence.",
            
            "Imagine a gentle journey on the back of a sky-dragon who moves slowly through the clouds. Its wings beat with calm rhythm, carrying the listener past constellations and toward a dawn-colored horizon.",
            
            "Describe a tranquil bedtime walk through a luminous forest at night. Fireflies flicker between the trees, streams murmur softly, and the path seems to lead endlessly deeper into calm and safety.",
            
            "Write a bedtime voyage aboard a dream-train that travels not across land, but through shifting dreamscapes. Each stop reveals a peaceful world—valleys of starlight, oceans of glass, fields that hum with lullabies."
        ],
        
        // --- Voyage (journeys, movement, routes) ---
        .voyage: [
            "Daydreaming in a train to Istanbul, wondering how all our lives are connected",
            "Riding a horse across the Mongolian steppe under endless skies",
            "Sailing by starlight among the Greek islands, guided only by myths",
            "Sailing down the Nile past temples and palm groves",
            "Drifting on a houseboat through Kerala’s backwaters",
            "Drifting through the streets of Amsterdam during tulip season",
            "Crossing Tibetan passes with yak caravans",
            "Riding the Trans-Siberian Railway and daydreaming for days",
            "Walking across bamboo bridges in rural Vietnam",
            "Sharing a ferry ride with farmers carrying baskets of fruit"
        ],

        // --- City (cafés, markets, street life) ---
        .city: [
            "Trading jokes with taxi drivers in Cairo traffic",
            "Eating mangoes on a rooftop in Havana",
            "Listening to live music and tasting tapas in the streets of Sevilla",
            "Swapping travel stories in a Kathmandu teahouse",
            "Whispering ghost tales in Prague alleys",
            "Journaling at a Paris café window",
            "Acting in street theater in Naples",
            "Sketching strangers in a smoky café in Buenos Aires",
            "Playing chess with an old man on the streets of Marrakech",
            "Getting lost in the alleyways of Fez’s ancient medina",
            "Reading tarot cards in a candlelit attic in Lisbon",
            "Walking through neon-lit night markets in Ho Chi Minh City",
            "Dancing tango on cobblestones in Buenos Aires",
            "Buying cherries at sunrise in a Turkish bazaar",
            "Drinking coffee at dawn in a hidden café in Addis Ababa"
        ],

        // --- Wilderness (mountains, deserts, ice, wild places) ---
        .wild: [
            "Mountaineering at sunrise on the Himalayan ridges",
            "Flying as an eagle over the snowy peaks of the Alps",
            "Watching sunrise from the top of Mount Kilimanjaro, above the clouds",
            "Wandering the jungle temples of Tikal as howler monkeys roar in the distance",
            "Sharing stories with nomads in a yurt on the Kazakh steppe",
            "Exploring flooded marble caves in Patagonia by kayak",
            "Watching lava flow into the ocean on the shores of Hawai‘i’s Big Island",
            "Traversing the salt flats of Uyuni under a mirror of stars",
            "Climbing the ancient rock churches of Lalibela by candlelight",
            "Spotting wild elephants while camping in Sri Lanka’s jungles",
            "Exploring ice caves under Vatnajökull Glacier in Iceland",
            "Crossing the frozen Lake Baikal on foot in winter",
            "Watching geysers erupt in Yellowstone at dawn",
            "Sleeping under the open sky in Wadi Rum",
            "Watching the sunrise paint Uluru in Australia",
            "Sledding with huskies across Lapland"
        ],

        // --- Myth & Ritual (traditions, ceremonies, teachings) ---
        .myth: [
            "Storytelling by firelight in the Sahara",
            "Writing wishes on lanterns in Chiang Mai",
            "Dancing barefoot at a Balinese temple festival",
            "Joining a desert caravan, in search of wisdom",
            "Learning riddles from Maasai elders",
            "Reciting blessings at a Himalayan monastery",
            "Practicing secret martial arts in a moss-covered temple in Kyoto",
            "Practicing calligraphy in a hidden courtyard in Kyoto",
            "Drinking spiced tea in a desert caravanserai as traders pass by",
            "Exploring an underwater temple said to belong to forgotten gods",
            "Listening to throat singing in Tuva around a campfire",
            "Learning flamenco rhythms in a Granada courtyard",
            "Drinking cacao with shamans in the Guatemalan highlands",
            "Joining masked dancers at a Bhutanese festival",
            "Following legends of dragons in the Carpathian mountains",
            "Watching shadow puppetry in a Javanese village"
        ],

        // --- Waters & Coasts (oceans, rivers, shores) ---
        .water: [
            "Surfing glowing waves under a full moon in Hawaii",
            "Diving into coral caves in the Great Barrier Reef",
            "Floating in the Dead Sea at sunrise, surrounded by silence",
            "Sailing down the Nile past temples and palm groves",
            "Drifting on a houseboat through Kerala’s backwaters",
            "Exploring flooded marble caves in Patagonia by kayak",
            "Exploring shipwrecks while diving in the Maldives",
            "Listening to myths whispered by shamans in the Amazon",
            "Stargazing from a hammock deep in the Amazon rainforest",
        ],

        // --- Night & Neon (after-dark, music, glow) ---
        .night: [
            "Karaoke duets with strangers in Tokyo",
            "Shapeshifting into a cat and wandering neon-lit rooftops of Hong Kong",
            "Sipping cocktails at the Moon Bar, watching Earth rise above the horizon",
            "Drumming at midnight in a São Tomé village",
            "Watching the aurora from a glass igloo in Finland",
            "Walking through neon-lit night markets in Ho Chi Minh City",
            "Riding gondolas at midnight through Venice’s quiet canals",
            "Listening to jazz spill from basement bars in New Orleans",
            "Lanterns rising over the Ganges in Varanasi"
        ],

        // --- Cosmos & Frontier (stars, space, sky craft) ---
        .cosmos: [
            "Joining the first colony on Mars and planting a tree in red soil",
            "Wandering through an abandoned Soviet observatory at dawn",
            "Stargazing from the Atacama Desert observatories",
            "Watching the Perseid meteor shower from the Sahara dunes",
            "Learning star navigation with Polynesian wayfinders",
            "Listening to fishermen name constellations in Crete",
            "Listening to Arctic winds while camping beneath the Northern Lights in Svalbard",
            "Flying as an eagle over the snowy peaks of the Alps",
            "A rooftop dinner in Marrakech where ten languages mix in the air",
            "Clouds forming a sentence you almost understand",
            "A door in the desert that opens into the ocean"
        ],

        // --- Time & Memory (lost places, ruins, eras) ---
        .time: [
            "Slipping through time to Paris in the 1920s, jazz spilling from the bars",
            "Exploring forgotten castles hidden in the Black Forest",
            "Exploring the eerie silence of Chernobyl’s abandoned streets",
            "Reading forgotten manuscripts in an old Oxford library",
            "Hiking through the red canyons of Petra by torchlight",
            "Climbing the steps of Machu Picchu in the mist",
            "Sketching ruins among olive groves in Delphi",
            "Exploring the underground salt cathedral of Zipaquirá in Colombia",
            "Time-traveling to Florence during the Renaissance and sketching with apprentices",
            "Capoeira at dawn on a Rio beach",
            "Cheering at a village football match in Ghana",
            "Tasting street noodles at midnight in Taipei",
            "Joining drumming circles at dusk in Dakar"
        ],
        
        .philosophy: [
            "To what extent are dreams a form of reality rather than just illusions of the mind?",
            "Where do ideas originate before they arrive in our awareness?",
            "What does the phenomenon of synesthesia reveal about the hidden nature of reality?",
            "Do our imaginations create worlds as real as the physical one we share?",
            "Why do things often become less tangible the more we try to grasp them?",
            "What makes something “real” — experience, belief, or shared agreement?",
            "Can beauty exist without an observer?",
            "What role do myths play in shaping how we see reality?",
            "Is perception a window into the world, or a world in itself?",
            "If animals perceive realities we cannot, what world are we missing?",
            
            "If incarnation is real, what does it reveal about continuity and change in who we are?",
            "What is the nature of consciousness: an emergent property, or a fundamental aspect of the universe?",
            "How can I hold a healthy relationship with my past and future selves while living fully in the present?",
            "Is it useful to view life as an evolving maze that reshapes itself with every choice?",
            "What does it truly mean to feel love — and can love ever be fully known, or only lived?",
            "How much of who I am is memory, and how much is possibility?",
            "In what ways do fears shape the boundaries of my identity?",
            "How does imagination contribute to who we become?",
            "Where do our deepest desires come from, and what do they reveal?",
            "What does it mean to live with integrity across changing circumstances?",
            
            "Is time truly relative, or is it only our perception that shifts?",
            "Has the future already unfolded, waiting only to be discovered?",
            "How does meaning shift when viewed from the perspective of deep time?",
            "If the present is always vanishing, what does it mean to “live in the now”?",
            "What is eternity — endless duration, or timeless presence?",
            "How do dreams alter our sense of time?",
            "Is memory a form of time travel?",
            "If all moments are connected, how do we move through them?",
            "What does it mean for a story to outlive its teller?",
            
            "What does it mean to share genuine understanding with animals or pets?",
            "Why do different species — and even individuals of the same species — carry distinct personalities?",
            "If every encounter with a stranger holds the potential to change my life, what fears keep me from openness?",
            "How do we recognize ourselves in the faces of others?",
            "What is carried forward by a promise passed through generations?",
            "How does trust form, and what sustains it?",
            "Can love exist without expression, or does it require action?",
            "What makes a community more than the sum of its members?",
            "How does listening transform a relationship?",
            "What do I learn about myself through the bonds I create?",
            
            "Where does the universe end, and what, if anything, lies beyond?",
            "Where do unremembered dreams go when they slip beyond waking?",
            "What becomes of prayers that never find an echo?",
            "How do forgotten languages continue to resonate in silence?",
            "In what ways do myths outlive the people who first told them?",
            "What role does mystery play in shaping a meaningful life?",
            "How does wonder keep us alive in the face of the unknown?",
            "Where do possibilities dwell before they take form?",
            "What truths linger in ruins and abandoned places?",
            "How does the unknown give shape to everything we call the known?"
        ],
        
        .practice: [
            "What small ritual brings you back to yourself?",
            "How do you recognize joy in ordinary moments?",
            "What do you return to when everything feels uncertain?",
            "What do your mornings reveal about the rhythm of your life?",
            "When do you feel most connected to your body?",
            "What space in your daily life feels sacred, even if unnoticed?",
            "How do you give attention to the simplest of tasks?",
            "How do you carry gratitude through ordinary days?",
            "How does your body respond when you move without purpose?",
            "What changes when you treat movement as play rather than exercise?",
            "How does balance teach you about attention?",
            "Where in your body do you hold unnecessary tension?",
            "What lessons appear when you deliberately move awkwardly?",
            "How does slowness reveal details hidden in fast movement?",
            "What new pathways open when you explore the floor as a landscape?",
            "How do you adapt when movement does not go as planned?",
            "What stories are carried in the way you walk?",
            "How does repetition transform into understanding?"
        ]

    ]


    // Flattened pool that respects the selected category (All = union of all)
    private var promptPool: [String] {
        if selectedPromptCategory == .all {
            promptsByCategory.values.flatMap { $0 }
        } else {
            promptsByCategory[selectedPromptCategory] ?? []
        }
    }

    // Pick a random prompt from the current category (or All), replacing any previous text.
    private func pickRandomPresetPrompt() {
        let pool = promptPool
        guard !pool.isEmpty else { return }
        var choice = pool.randomElement()!
        if pool.count > 1 {
            var attempts = 0
            while choice == userPrompt && attempts < 5 {
                choice = pool.randomElement()!
                attempts += 1
            }
        }
        userPrompt = choice
    }
    
    // MARK: - Random Variables Topic Create
    
    // Build a topic from selected aspects + one interest
    private func buildRandomTopic() -> String {
        let styleSel = styleTable.randomSelection()           // only active rows with at least one enabled option
        let styleSeed = styleTable.renderSeed(from: styleSel)

        let enabledInterests = interestRow.options.filter { $0.enabled }
        let interestSeed: String? = (interestRow.isActive && !enabledInterests.isEmpty)
            ? enabledInterests.randomElement()!.label
            : nil

        var parts: [String] = []
        if !styleSeed.isEmpty { parts.append(styleSeed) }
        if let interest = interestSeed { parts.append("\n\(interest)") }    //      if let interest = interestSeed { parts.append("Interest: \(interest)") }

        if parts.isEmpty { return "Interest: capoeira ao amanhecer" }
        return parts.joined(separator: "\n")   // <-- instead of " • "

    }

    // MARK: - Persistence helpers
    private func saveGeneratorSettings() {
        let payload = GeneratorSettings.fromViewState(
            mode: mode,
            segmentation: segmentation,
            lengthPreset: lengthPreset,
            genLanguage: genLanguage,
            transLanguage: transLanguage,
            languageLevel: languageLevel,
            speechSpeed: speechSpeed,
            translationStyle: translationStyle
        )
        if let data = try? JSONEncoder().encode(payload) {
            generatorSettingsData = data
        }
    }

    private func loadGeneratorSettings() {
        guard !generatorSettingsData.isEmpty,
              let payload = try? JSONDecoder().decode(GeneratorSettings.self, from: generatorSettingsData)
        else { return }

        // Mode
        if let m = GenerationMode(rawValue: payload.mode) { mode = m }

        // Segmentation
        if let s = Segmentation(rawValue: payload.segmentation) { segmentation = s }

        // Length preset (clamp to valid range)
        if let preset = LengthPreset(rawValue: payload.lengthPresetRaw) { lengthPreset = preset }

        // Languages (fallback to defaults if not supported)
        if supportedLanguages.contains(payload.genLanguage) { genLanguage = payload.genLanguage }
        if supportedLanguages.contains(payload.transLanguage) { transLanguage = payload.transLanguage }

        // CEFR & speech speed
        if let lvl = LanguageLevel(rawValue: payload.languageLevel) { languageLevel = lvl }
        if let spd = SpeechSpeed(rawValue: payload.speechSpeed) { speechSpeed = spd }
        
        // Translation style
        if let ts = TranslationStyle(rawValue: payload.translationStyle) { translationStyle = ts }

    }
    
    private func loadTable(from data: Data, fallback: AspectTable) -> AspectTable {
        guard !data.isEmpty, let decoded = try? JSONDecoder().decode(AspectTable.self, from: data) else {
            return fallback
        }
        return decoded
    }
    private func loadRow(from data: Data, fallback: AspectRow) -> AspectRow {
        guard !data.isEmpty, let decoded = try? JSONDecoder().decode(AspectRow.self, from: data) else {
            return fallback
        }
        return decoded
    }
    private func saveTable(_ table: AspectTable) -> Data {
        (try? JSONEncoder().encode(table)) ?? Data()
    }
    private func saveRow(_ row: AspectRow) -> Data {
        (try? JSONEncoder().encode(row)) ?? Data()
    }
    
    private var allSupportedLanguages: [String] { supportedLanguages }
    

    @ViewBuilder private func segmentationSection() -> some View {
        Section {
            let allSegs: [Segmentation] = Array(Segmentation.allCases)
            Picker("Segment by", selection: $segmentation) {
                ForEach(allSegs, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Segment by")
        } header: {
            HStack(spacing: 6) {
                Text("Segmentation")
                Button {
                    showSegmentationInfo = true
                } label: {
                    Image(systemName: "info.circle").imageScale(.medium)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About Segmentation")

                // iPad/regular width: anchored popover
                .modifier(RegularWidthPopover(isPresented: $showSegmentationInfo) {
                    SegmentationInfoCard()
                        .frame(maxWidth: 360)
                        .padding()
                })
                .sheet(isPresented: Binding(
                    get: { hSize == .compact && showSegmentationInfo },
                    set: { showSegmentationInfo = $0 }
                )) {
                    SegmentationInfoCard()
                        .presentationDetents([.fraction(0.4), .medium])
                        .presentationDragIndicator(.visible)
                }

                Spacer()
            }

        }
    }


    @ViewBuilder private func lengthSection() -> some View {
        Section {
            Picker("", selection: $lengthPreset) {
                ForEach(LengthPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } header: {
            HStack {
                Text("Length")
                Spacer()
                Text("~\(lengthPreset.words) words")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Approximately \(lengthPreset.words) words")
            }
        }
    }
    
    @ViewBuilder private func longFormSection() -> some View {
        Section {
            Toggle("Long-form Generation", isOn: $enableLongForm)
            
            if enableLongForm {
                Stepper("Total Words: \(longFormTotalWords)", value: $longFormTotalWords, in: 600...3000, step: 300)
                
                Text("This will create ~\(longFormTotalWords / 300) lessons in a folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text("All lessons will be created from a single coherent narrative.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Series Generation")
        }
    }

    @ViewBuilder private func speechSpeedSection() -> some View {
        Section("Speech Speed") {
            Picker("Speech Speed", selection: $speechSpeed) {
                Text("Regular").tag(SpeechSpeed.regular)
                Text("Slow").tag(SpeechSpeed.slow)
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder private func levelSection() -> some View {
        Section("Language Level (CEFR)") {
            let levels: [LanguageLevel] = Array(LanguageLevel.allCases)
            Picker("Level", selection: $languageLevel) {
                ForEach(levels, id: \.self) { level in
                    Text(level.rawValue).tag(level)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder private func actionSection() -> some View {
        Section {
            Button {
                // No local debit here; proxy debits per request.
                if mode == .random && randomTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    randomTopic = buildRandomTopic()
                }

                let reqMode: GeneratorService.Request.GenerationMode = (mode == .prompt) ? .prompt : .random
                let reqSeg: GeneratorService.Request.Segmentation = (segmentation == .paragraphs) ? .paragraphs : .sentences

                var req = GeneratorService.Request(
                    languageLevel: languageLevel,
                    mode: reqMode,
                    userPrompt: userPrompt,
                    genLanguage: genLanguage,
                    transLanguage: transLanguage,
                    segmentation: reqSeg,
                    lengthWords: lengthPreset.words,
                    speechSpeed: speechSpeed,
                    userChosenTopic: randomTopic.isEmpty ? nil : randomTopic, // wrap to nil if empty
                    topicPool: nil
                )
                req.translationStyle = translationStyle
                
                // Set length mode based on long-form toggle
                if enableLongForm {
                    // Calculate lessons: same text divided into N+1 lessons (min 2, max 10)
                    let lessonsCount = min(max((longFormTotalWords / 300) + 1, 2), 10)
                    req.lengthMode = .longForm(totalWords: longFormTotalWords, lessonsCount: lessonsCount)
                } else {
                    req.lengthMode = .standard(words: lengthPreset.words)
                }

                generator.start(req, lessonStore: lessonStore, folderStore: folderStore)
            } label: {
                HStack { if generator.isBusy { ProgressView() }
                    Text(generator.isBusy ? "Generating..." : "Generate Lesson")
                }
            }
            .disabled(generator.isBusy || (mode == .prompt && userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))


            Text("Credits: \(serverBalance)")
                .font(.body)
                .foregroundStyle(.secondary)
            
            if !generator.status.isEmpty {
                generationStatusView()
            }
        }
    }

    // MARK: - Generation Status Helpers
    
    @ViewBuilder
    private func generationStatusView() -> some View {
        // Check if this is a folder ID (long-form generation)
        if let lastID = generator.lastLessonID, lastID.hasPrefix("folder:") {
            folderStatusView(lastID: lastID)
        } else {
            lessonStatusView()
        }
    }
    
    @ViewBuilder
    private func folderStatusView(lastID: String) -> some View {
        let folderID = String(lastID.dropFirst("folder:".count))
        let folder = folderStore.folders.first(where: { $0.id.uuidString == folderID })
        let statusText = (folder != nil) ? "Series ready — tap to open" : generator.status
        
        if let folder {
            Button {
                navTargetFolder = folder
            } label: {
                statusButtonLabel(text: statusText)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.green)
            .accessibilityLabel("Open generated series folder")
        } else {
            statusTextLabel(text: statusText)
        }
    }
    
    @ViewBuilder
    private func lessonStatusView() -> some View {
        let lesson = lessonStore.lessons.first(where: { $0.id == generator.lastLessonID })
        let statusText = (lesson != nil) ? "Lesson ready — tap to open" : generator.status
        
        if let lesson {
            Button {
                navTargetLesson = lesson
            } label: {
                statusButtonLabel(text: statusText)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.green)
            .accessibilityLabel("Open last generated lesson")
        } else {
            statusTextLabel(text: statusText)
        }
    }
    
    @ViewBuilder
    private func statusButtonLabel(text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .imageScale(.small)
            Text(text)
            Image(systemName: "chevron.right")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
    
    @ViewBuilder
    private func statusTextLabel(text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
    }
    
    // MARK: - Form Sections
    
    @ViewBuilder
    private func modeAndSuggestionsSection() -> some View {
        Section {
                VStack(spacing: 0) {
                    ModeCard(
                        mode: $mode,
                        userPrompt: $userPrompt,
                        selectedPromptCategory: $selectedPromptCategory,
                        randomTopic: $randomTopic,
                        showConfigurator: $showConfigurator,
                        pickRandomPresetPrompt: { pickRandomPresetPrompt() },
                        buildRandomTopic: { buildRandomTopic() },
                        promptFocus: $promptIsFocused,
                        showModeInfo: $showModeInfo
                    )
                    .padding(.top, 42)
                    .buttonStyle(.plain)

                    // Suggestions only render when we have generated suggestions
                    if hasSuggestions {
                        if suggestionsExpanded {
                            NextPromptSuggestionsView(
                                isExpanded: $suggestionsExpanded,
                                suggestions: suggestionsFeed,
                                onPick: { picked in
                                    mode = .prompt
                                    userPrompt = picked
                                }
                            )
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                        }
                    }
                    
                }
                // Reserve bottom space for chevron overlay when suggestions collapsed
                .padding(.bottom, (hasSuggestions && !suggestionsExpanded) ? 30 : 0)

                // Chevron overlay only for collapsed suggestions
                .overlay(alignment: .bottom) {
                    if hasSuggestions && !suggestionsExpanded {
                        Button {
                            Task { @MainActor in
                                suggestionsExpanded = true
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .imageScale(.medium)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .offset(y: 4)
                        .accessibilityLabel("Show next prompt suggestions")
                    }
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }
    
    @ViewBuilder
    private var segmentationItem: some View {
        AdvancedItem(
            title: "Segmentation",
            infoAction: { showSegmentationInfo = true }
        ) {
            Picker("Segment by", selection: $segmentation) {
                ForEach(Array(Segmentation.allCases), id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .contentShape(Rectangle())
            .padding(.horizontal, 2)
            .accessibilityLabel("Segment by")
        }
    }
    
    @ViewBuilder
    private var lengthItem: some View {
        AdvancedItem(
            title: "Length",
            trailing: "~\(lengthPreset.words) words"
        ) {
            Picker("", selection: $lengthPreset) {
                ForEach(LengthPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .contentShape(Rectangle())
            .padding(.horizontal, 2)
            .labelsHidden()
        }
    }
    
    @ViewBuilder
    private var longFormItem: some View {
        AdvancedItem(title: "Long-form series") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable multi-lesson generation", isOn: $enableLongForm)
                
                if enableLongForm {
                    Divider()
                    Stepper("Total: \(longFormTotalWords) words", value: $longFormTotalWords, in: 600...3000, step: 300)
                    Text("Creates ~\(longFormTotalWords / 300) lessons from one coherent story")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    @ViewBuilder
    private var speechSpeedItem: some View {
        AdvancedItem(title: "Speech speed") {
            Picker("Speech speed", selection: $speechSpeed) {
                Text("Regular").tag(SpeechSpeed.regular)
                Text("Slow").tag(SpeechSpeed.slow)
            }
            .pickerStyle(.segmented)
            .contentShape(Rectangle())
            .padding(.horizontal, 2)
            .labelsHidden()
        }
    }
    
    @ViewBuilder
    private var languageLevelItem: some View {
        AdvancedItem(title: "Language level (CEFR)") {
            Picker("Level", selection: $languageLevel) {
                ForEach(Array(LanguageLevel.allCases), id: \.self) { level in
                    Text(level.rawValue).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .contentShape(Rectangle())
            .padding(.horizontal, 2)
            .labelsHidden()
        }
    }
    
    @ViewBuilder
    private var translationStyleItem: some View {
        AdvancedItem(
            title: "Translation style",
            infoAction: { showTranslationStyleInfo = true }
        ) {
            Picker("Translation style", selection: $translationStyle) {
                Text("Literal").tag(TranslationStyle.literal)
                Text("Idiomatic").tag(TranslationStyle.idiomatic)
            }
            .pickerStyle(.segmented)
            .contentShape(Rectangle())
            .padding(.horizontal, 2)
            .labelsHidden()
        }
    }
    
    @ViewBuilder
    private var advancedCardContent: some View {
        segmentationItem
        AdvancedSpacer()
        lengthItem
        AdvancedSpacer()
        longFormItem
        AdvancedSpacer()
        speechSpeedItem
        AdvancedSpacer()
        languageLevelItem
        AdvancedSpacer()
        translationStyleItem
    }
    
    private func advancedOptionsSection() -> AnyView {
        let advanced = advancedExpandedBinding
        
        return AnyView(
            Section {
                AdvancedCard(expanded: advanced, title: "Advanced Options") {
                    advancedCardContent
                }
                
                .modifier(RegularWidthPopover(isPresented: $showSegmentationInfo) {
                    SegmentationInfoCard()
                        .frame(maxWidth: 360)
                        .padding()
                })
                .sheet(isPresented: Binding(
                    get: { hSize == .compact && showSegmentationInfo },
                    set: { showSegmentationInfo = $0 }
                )) {
                    SegmentationInfoCard()
                        .presentationDetents([.fraction(0.4), .medium])
                        .presentationDragIndicator(.visible)
                }
                
                .modifier(RegularWidthPopover(isPresented: $showTranslationStyleInfo) {
                    TranslationStyleInfoCard()
                        .frame(maxWidth: 360)
                        .padding()
                })
                .sheet(isPresented: Binding(
                    get: { hSize == .compact && showTranslationStyleInfo },
                    set: { showTranslationStyleInfo = $0 }
                )) {
                    TranslationStyleInfoCard()
                        .presentationDetents([.fraction(0.35), .medium])
                        .presentationDragIndicator(.visible)
                }
            }
            .listRowInsets(EdgeInsets())               // removes the default insets
            .listRowBackground(Color.clear)            // removes the default grouped bg
        )
    }
    
    @ViewBuilder
    private func languagesSection() -> some View {
        Section {
                LanguageCard(
                    genLanguage: $genLanguage,
                    transLanguage: $transLanguage,
                    allSupportedLanguages: allSupportedLanguages
                )

            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }
    
    // MARK: - Form Content
    @ViewBuilder
    private var formBody: some View {
        modeAndSuggestionsSection()
        advancedOptionsSection()
        languagesSection()
        actionSection()
    }
    
    // Break up the complex view hierarchy into smaller pieces
    private var formWithBasicStyling: some View {
        Form {
            formBody
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .background(
            TapToDismissKeyboard {
                if mode == .prompt { promptIsFocused = false }
            }
        )
        .scrollDismissesKeyboard(.immediately)
    }
    
    private var formWithLifecycleHandlers: some View {
        formWithBasicStyling
            .onChange(of: mode, initial: false) { _, _ in
                // keep keyboard hidden until user taps
                promptIsFocused = false
            }
            .onAppear {
                print("DeviceID.current = \(DeviceID.current)")
                // hydrate from persistence (or seed defaults)
                let loadedTable = loadTable(from: styleTableJSON, fallback: styleTable)
                let loadedRow = loadRow(from: interestRowJSON, fallback: interestRow)
                styleTable = loadedTable
                interestRow = loadedRow
                if styleTableJSON.isEmpty { styleTableJSON = saveTable(styleTable) }
                if interestRowJSON.isEmpty { interestRowJSON = saveRow(interestRow) }
                
                // Snapshot current lesson IDs so we can detect new ones later
                knownLessonIDs = Set(lessonStore.lessons.map { $0.id })
                
                // Load generator settings
                loadGeneratorSettings()
                promptIsFocused = false   // ensure keyboard is hidden on open
            }
            // Persist generator settings — keep one-liners
            .onChange(of: mode, initial: false)            { _, _ in saveGeneratorSettings() }
            .onChange(of: segmentation, initial: false)    { _, _ in saveGeneratorSettings() }
            .onChange(of: lengthPreset, initial: false)    { _, _ in saveGeneratorSettings() }
            .onChange(of: genLanguage, initial: false)     { _, _ in saveGeneratorSettings() }
            .onChange(of: transLanguage, initial: false)   { _, _ in saveGeneratorSettings() }
            .onChange(of: languageLevel, initial: false)   { _, _ in saveGeneratorSettings() }
            .onChange(of: speechSpeed, initial: false)     { _, _ in saveGeneratorSettings() }
            .onChange(of: translationStyle, initial: false) { _, _ in saveGeneratorSettings() }
    }
    
    private var formWithPersistence: some View {
        formWithLifecycleHandlers
            // Persist aspect table & interests
            .onChange(of: styleTable, initial: false) { _, newValue in
                styleTableJSON = saveTable(newValue)
            }
            .onChange(of: interestRow, initial: false) { _, newValue in
                interestRowJSON = saveRow(newValue)
            }
            // Detect newly added lessons to show the toast
            .onChange(of: lessonStore.lessons, initial: false) { _, newLessons in
                let added = newLessons.filter { !knownLessonIDs.contains($0.id) }
                if let lesson = added.last {
                    newlyCreatedLesson = lesson
                    toastHideWork?.cancel()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                        showToast = true
                    }
                    let work = DispatchWorkItem {
                        withAnimation(.easeInOut) { showToast = false }
                    }
                    toastHideWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
                }
                knownLessonIDs = Set(newLessons.map { $0.id })
            }
            // React to out-of-credits latch
            .onChange(of: generator.outOfCredits, initial: false) { _, needs in
                if needs {
                    showBuyCredits = true
                    generator.outOfCredits = false
                }
            }
    }
    
    private var formWithNavigation: some View {
        formWithPersistence
            .navigationTitle("Generator")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showPromptBrainstorm = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 14, weight: .semibold))
                            Text("AI")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            LinearGradient(
                                colors: [Color.blue, Color(red: 0.0, green: 0.4, blue: 0.7), Color(red: 0.0, green: 0.2, blue: 0.5)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .clipShape(Capsule())
                        )
                        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
                        .shadow(color: .blue.opacity(0.4), radius: 8, x: 0, y: 4)
                    }
                    .accessibilityLabel("Brainstorm prompt ideas with AI")
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.generatorAdvancedExpanded, advancedExpandedBinding)
    }
    
    private var formWithSheets: some View {
        formWithNavigation
            .sheet(isPresented: $showConfigurator) {
                AspectConfiguratorView(styleTable: $styleTable, interestRow: $interestRow)
                    .onDisappear {
                        styleTableJSON = saveTable(styleTable)
                        interestRowJSON = saveRow(interestRow)
                    }
            }
            // Destination for programmatic navigation from toast tap
            .navigationDestination(item: $navTargetLesson) { lesson in
                ContentView(selectedLesson: lesson, lessons: lessonStore.lessons)
            }
            // Destination for folder navigation (long-form series)
            .navigationDestination(item: $navTargetFolder) { folder in
                FolderDetailView(folder: folder, lessons: lessonStore.lessons)
            }
            .sheet(isPresented: $showBuyCredits, onDismiss: {
                Task { await refreshServerBalance() }   // calls @MainActor func
            }) {
                NavigationStack {
                    BuyCreditsView(presentation: .modal)
                        .environmentObject(purchases)
                }
            }
            .sheet(isPresented: $showPromptBrainstorm) {
                PromptBrainstormView(
                    onSelectPrompt: { finalPrompt in
                        mode = .prompt
                        userPrompt = finalPrompt
                        showPromptBrainstorm = false
                    }
                )
                .environmentObject(generator)
            }
    }
    
    private var formContent: some View {
        formWithSheets
            // Overlay toast banner at top of GeneratorView
            .overlay(alignment: .top) {
                if showToast, let lesson = newlyCreatedLesson {
                    ToastBanner(
                        message: "New lesson ready: \(lesson.title)",
                        isSuccess: true,
                        onTap: {
                            // Hide toast and navigate
                            toastHideWork?.cancel()
                            withAnimation(.easeInOut) { showToast = false }
                            navTargetLesson = lesson
                        }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 6)
                }
            }
            .task {
                await refreshServerBalance()   // main-actor isolated; safe UI mutation
            }
            .onAppear {
                // Seed once when the view shows (main-thread context here)
                suggestionsFeed = generator.nextPromptSuggestions
            }
            .onReceive(
                generator.$nextPromptSuggestions
                    .receive(on: RunLoop.main)   // ensure updates arrive on main
            ) { newValue in
                let hadSuggestions = !suggestionsFeed.isEmpty
                suggestionsFeed = newValue
                
                // Auto-expand when suggestions are first generated
                if !hadSuggestions && !newValue.isEmpty {
                    suggestionsExpanded = true
                }
            }
            .onReceive(
                NotificationCenter.default
                    .publisher(for: .didPurchaseCredits)
                    .receive(on: RunLoop.main)                 // <- ensure delivery on main
            ) { _ in
                Task { await refreshServerBalance() }         // <- main-actor func, safe
            }
            // Refresh balance after a successful generation
            .onChange(of: generator.lastLessonID, initial: false) { _, _ in
                Task { await refreshServerBalance() }   // calls @MainActor func
            }
    }
    
    // MARK: - Body
    var body: some View {
        formContent
    }
}

// MARK: - Advanced options card

private struct AdvancedCard<Content: View>: View {
    @Binding var expanded: Bool
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                        .imageScale(.medium)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            // Divider between header and content
            if expanded {
                Divider()
                    .transition(.opacity)
            }

            // Body content
            if expanded {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            // Card background that adapts to light/dark
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .padding(.vertical, 6)
    }
}

// A lightweight inner group to give each advanced control its own mini-surface
private struct AdvancedItem<Content: View>: View {
    let title: String
    var trailing: String? = nil
    var infoAction: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let infoAction {
                    Button(action: infoAction) {
                        Image(systemName: "info.circle")
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About \(title)")
                }
            }

            content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.08), lineWidth: 1)
        )
    }
}

// A simple divider with extra breathing room between items
private struct AdvancedSpacer: View {
    var body: some View {
        Divider().opacity(0)      // invisible line
            .frame(height: 8)     // …acting as vertical spacer
    }
}

@MainActor
private struct NextPromptSuggestionsView: View {
    @Binding var isExpanded: Bool
    let suggestions: [String]
    var onPick: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {

            // HEADER — with title and toggle chevron
            Button {
                Task { @MainActor in
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.yellow)
                        Text("Next prompt ideas")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Color.appBackground)
            }
            .buttonStyle(.plain)

            // CONTENT — only present when expanded
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(suggestions.prefix(3)), id: \.self) { s in
                        Button { onPick(s) } label: {
                            Text(s)
                                .font(.footnote)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .padding(.vertical, 10)
                                .padding(.horizontal, 12)
                        }
                        .buttonStyle(.bordered)
                        .tint(.accentColor)
                    }
                }
                .padding(.bottom, 12)
                .padding(.horizontal, 12)
                .transition(.opacity)
            }
        }
        .padding(.top, 0)
        .padding(.horizontal, 0)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.appBackground)
        )
    }
}





// MARK: - Mode + Input card
@MainActor
private struct ModeCard: View {
    @Binding var mode: GeneratorView.GenerationMode
    @Binding var userPrompt: String
    @Binding var selectedPromptCategory: GeneratorView.PromptCategory
    @Binding var randomTopic: String
    @Binding var showConfigurator: Bool
    var pickRandomPresetPrompt: () -> Void
    var buildRandomTopic: () -> String
    var promptFocus: FocusState<Bool>.Binding
    @Binding var showModeInfo: Bool

    @Environment(\.horizontalSizeClass) private var hSize

    private var editorMinHeight: CGFloat {
        hSize == .compact ? 160 : 200
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                Text("Mode").font(.headline)
                Spacer()
                Button { showModeInfo = true } label: {
                    Image(systemName: "info.circle").imageScale(.medium)
                }
                .buttonStyle(.plain)
                .modifier(RegularWidthPopover(isPresented: $showModeInfo) {
                    ModeInfoCard().frame(maxWidth: 360).padding()
                })
                .sheet(isPresented: Binding(
                    get: { hSize == .compact && showModeInfo },
                    set: { showModeInfo = $0 }
                )) {
                    ModeInfoCard()
                        .presentationDetents([.fraction(0.35), .medium])
                        .presentationDragIndicator(.visible)
                }
            }
            .padding(.bottom, 2)

            // Mode picker
            Picker("Generation Mode", selection: $mode) {
                Text(GeneratorView.GenerationMode.prompt.rawValue).tag(GeneratorView.GenerationMode.prompt)
                Text(GeneratorView.GenerationMode.random.rawValue).tag(GeneratorView.GenerationMode.random)
            }
            .pickerStyle(.segmented)

            Group {
                if mode == .prompt {
                    // ---- PROMPT MODE ----
                    VStack(alignment: .leading, spacing: 10) {

                        StableTextEditor(
                            text: $userPrompt,
                            minHeight: editorMinHeight,
                            showsDoneAccessory: true,
                            onClear: { userPrompt = "" }
                        )
                        .frame(minHeight: editorMinHeight)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .systemGray6)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
                        .transaction { $0.animation = nil }

                        HStack(spacing: 8) {
                            // Match random mode button styling
                            Button(action: pickRandomPresetPrompt) {
                                Label("Randomize", systemImage: "die.face.5")
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .buttonStyle(.bordered)

                            Spacer(minLength: 8)

                            // Category as a bordered "button-like" menu, same visual weight
                            Menu {
                                Picker("Category", selection: $selectedPromptCategory) {
                                    ForEach(GeneratorView.PromptCategory.allCases) { Text($0.rawValue).tag($0) }
                                }
                            } label: {
                                Label(selectedPromptCategory.rawValue, systemImage: "line.3.horizontal.decrease.circle")
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .buttonStyle(.bordered)
                        }

                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    // ---- RANDOM MODE ----
                    VStack(alignment: .leading, spacing: 10) {
                        StableTextEditor(
                            text: $randomTopic,
                            minHeight: editorMinHeight,
                            showsDoneAccessory: true,
                            onClear: { randomTopic = "" }
                        )
                        .frame(minHeight: editorMinHeight)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .systemGray6)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
                        .transaction { $0.animation = nil }

                        // Buttons row: left + right, no overlap, no wrapping
                        ZStack {
                            HStack {
                                Button {
                                    randomTopic = buildRandomTopic()
                                } label: {
                                    Label("Randomize", systemImage: "die.face.5")
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .buttonStyle(.bordered)
                                Spacer()
                            }

                            HStack {
                                Spacer()
                                Button {
                                    showConfigurator = true
                                } label: {
                                    Label("Configure", systemImage: "slider.horizontal.3")
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }
}

private struct FieldHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 2)
    }
}


private struct ModeInfoCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .imageScale(.large)
                Text("About Mode")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prompt")
                            .font(.subheadline.bold())
                        Text("You provide your own prompt or source text. Great for tailored lessons.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "text.cursor")
                        .font(.caption2)
                }

                Divider()

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Random")
                            .font(.subheadline.bold())
                        Text("The app generates a random topic based on your interests and style settings. Good for variety and surprise practice.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "die.face.5")
                        .font(.caption2)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(radius: 8, y: 4)
        )
    }
}

private struct SegmentationInfoCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "textformat")
                    .imageScale(.large)
                Text("About Segmentation")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sentences")
                            .font(.subheadline.bold())
                        Text("Splits the text into single-sentence chunks.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "circle.fill").font(.caption2) }

                Divider()

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Paragraphs")
                            .font(.subheadline.bold())
                        Text("Keeps multi-sentence blocks together for more context and natural flow.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "rectangle.3.offgrid").font(.caption2) }
            }

            // Moved tip lives in the card
            HStack(spacing: 8) {
                Image(systemName: "lightbulb")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text("Choose how text is divided for speech: generate one audio clip per sentence, or one per paragraph.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(radius: 8, y: 4)
        )
    }
}

private struct TranslationStyleInfoCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "character.book.closed")
                    .imageScale(.large)
                Text("About Translation Style")
                    .font(.headline)
            }
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Literal")
                            .font(.subheadline.bold())
                        Text("Closer to word-for-word. Preserves original order and grammar to make vocab mapping easy, but can sound stiff or unnatural.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "text.justify") }

                Divider()

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Idiomatic")
                            .font(.subheadline.bold())
                        Text("Natural phrasing. Reorders or rewrites where needed so it reads as a native would write it—meaning over form.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "quote.bubble") }
            }

        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(radius: 8, y: 4)
        )
    }
}



// MARK: - Languages card

private struct LanguageCard: View {
    @Binding var genLanguage: String
    @Binding var transLanguage: String
    let allSupportedLanguages: [String]

    var body: some View {
        VStack(spacing: 0) {
            // Header row with title + swap button
            HStack {
                Image(systemName: "globe")
                Text("Languages").font(.headline)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        swap(&genLanguage, &transLanguage)
                    }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Swap target and helper languages")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().opacity(0.15)

            // Compact rows
            VStack(spacing: 0) {
                // Target
                HStack {
                    Text("Target")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $genLanguage) {
                        ForEach(allSupportedLanguages, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Target language")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider().opacity(0.15)

                // Helper
                HStack {
                    Text("Helper")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $transLanguage) {
                        ForEach(allSupportedLanguages, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Helper language")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .padding(.vertical, 6)
        .onChange(of: genLanguage) { _, new in
            if new == transLanguage,
               let alt = allSupportedLanguages.first(where: { $0 != new }) {
                transLanguage = alt
            }
        }
    }
}



private struct RegularWidthPopover<PopupContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let popup: () -> PopupContent

    @Environment(\.horizontalSizeClass) private var hSize

    func body(content: Content) -> some View {
        content.popover(
            isPresented: Binding(
                get: { hSize != .compact && isPresented },
                set: { isPresented = $0 }
            ),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            popup()
        }
    }
}

// MARK: - Environment key for "Advanced options" expanded state

private struct GeneratorAdvancedExpandedKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    var generatorAdvancedExpanded: Binding<Bool> {
        get { self[GeneratorAdvancedExpandedKey.self] }
        set { self[GeneratorAdvancedExpandedKey.self] = newValue }
    }
}

struct StableTextEditor: UIViewRepresentable {
    @Binding var text: String
    var minHeight: CGFloat = 140
    var showsDoneAccessory: Bool = true
    var placeholder: String? = nil
    var onClear: (() -> Void)? = nil

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: StableTextEditor
        weak var textView: UITextView?
        private let placeholderLabel = UILabel()
        private var constraints: [NSLayoutConstraint] = []

        init(_ parent: StableTextEditor) {
            self.parent = parent
            super.init()
            placeholderLabel.numberOfLines = 0
            placeholderLabel.font = UIFont.preferredFont(forTextStyle: .body)
            placeholderLabel.textColor = UIColor.secondaryLabel.withAlphaComponent(0.5)
        }

        func attachPlaceholder(to textView: UITextView) {
            guard placeholderLabel.superview == nil else { return }
            placeholderLabel.text = parent.placeholder
            placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
            textView.addSubview(placeholderLabel)
            activatePlaceholderConstraints(for: textView)
            updatePlaceholderVisibility()
        }

        private func activatePlaceholderConstraints(for textView: UITextView) {
            NSLayoutConstraint.deactivate(constraints)
            let left = textView.textContainerInset.left + textView.textContainer.lineFragmentPadding
            let right = textView.textContainerInset.right + textView.textContainer.lineFragmentPadding
            let top = textView.textContainerInset.top

            constraints = [
                placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: left),
                // Use lessThanOrEqual to avoid forcing layout wider than container
                placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor, constant: -right),
                placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: top)
            ]
            NSLayoutConstraint.activate(constraints)
        }

        func updatePlaceholderVisibility() {
            placeholderLabel.isHidden = !(parent.placeholder != nil && parent.text.isEmpty)
        }

        // Keep constraints in sync if insets/padding change (e.g., Dynamic Type)
        func refreshConstraintsIfNeeded() {
            guard let tv = textView else { return }
            activatePlaceholderConstraints(for: tv)
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            updatePlaceholderVisibility()
        }

        func textViewDidChangeSelection(_ textView: UITextView) { /* keep stable */ }

        @objc func doneTapped() { textView?.resignFirstResponder() }
        
        @objc func clearTapped() { 
            parent.onClear?()
        }
        
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if scrollView.contentOffset.x != 0 {
                scrollView.contentOffset.x = 0
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        tv.setContentHuggingPriority(.defaultLow, for: .vertical)
        tv.isScrollEnabled = true
        tv.alwaysBounceVertical = true
        tv.alwaysBounceHorizontal = false
        tv.showsHorizontalScrollIndicator = false
        tv.isDirectionalLockEnabled = true     // helps keep gestures vertical
        tv.contentInsetAdjustmentBehavior = .never
        
        // ✅ Force wrapping at the layout level
        tv.textContainer.widthTracksTextView = true
        tv.textContainer.lineBreakMode = .byWordWrapping

        // ✅ Also set paragraph style so newly typed text obeys wrapping
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        tv.typingAttributes[.paragraphStyle] = para
        //tv.defaultTextAttributes[.paragraphStyle] = para
        
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.adjustsFontForContentSizeCategory = true
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        context.coordinator.attachPlaceholder(to: tv)

        if showsDoneAccessory {
            // Give the toolbar a real frame and let it resize with the keyboard width.
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0,
                                              width: UIScreen.main.bounds.width,
                                              height: 44))
            bar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            bar.translatesAutoresizingMaskIntoConstraints = true  // important: no Auto Layout here

            // Set items first, then sizeToFit (keeps system sizing happy)
            var items: [UIBarButtonItem] = []
            
            // Add Clear button if onClear callback is provided
            if onClear != nil {
                let clearButton = UIBarButtonItem(title: "Clear", style: .plain,
                                                  target: context.coordinator,
                                                  action: #selector(Coordinator.clearTapped))
                clearButton.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 17, weight: .semibold)], for: .normal)
                items.append(clearButton)
            }
            
            items.append(UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil))
            
            let doneButton = UIBarButtonItem(title: "Done", style: .plain,
                                            target: context.coordinator,
                                            action: #selector(Coordinator.doneTapped))
            doneButton.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 17, weight: .semibold)], for: .normal)
            items.append(doneButton)
            
            bar.items = items
            bar.sizeToFit()

            tv.inputAccessoryView = bar
        }

        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }

        // Keep paragraph wrapping if attributes get reset
        if (uiView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.lineBreakMode != .byWordWrapping {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byWordWrapping
            uiView.typingAttributes[.paragraphStyle] = para
            //uiView.defaultTextAttributes[.paragraphStyle] = para
        }

        // Extra safety: if something pushed content wider, snap X back to 0
        if uiView.contentOffset.x != 0 {
            uiView.setContentOffset(CGPoint(x: 0, y: uiView.contentOffset.y), animated: false)
        }

        context.coordinator.updatePlaceholderVisibility()
        context.coordinator.refreshConstraintsIfNeeded()
    }
}

// MARK: - Prompt Brainstorm View

@MainActor
private struct PromptBrainstormView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var generator: GeneratorService
    
    var onSelectPrompt: (String) -> Void
    
    @State private var messages: [ChatMessage] = []
    @State private var userInput: String = ""
    @State private var isThinking: Bool = false
    @State private var conversationStage: ConversationStage = .initial
    @State private var currentPrompt: String? = nil
    @State private var showConfirmation: Bool = false
    @FocusState private var inputIsFocused: Bool
    
    enum ConversationStage {
        case initial
        case exploring
        case refining
        case done
    }
    
    struct ChatMessage: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isUser: Bool
        let isPrompt: Bool
        
        init(text: String, isUser: Bool, isPrompt: Bool = false) {
            self.text = text
            self.isUser = isUser
            self.isPrompt = isPrompt
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Chat messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { message in
                                ChatBubble(
                                    message: message,
                                    onSelectPrompt: { prompt in
                                        currentPrompt = prompt
                                        showConfirmation = true
                                    }
                                )
                                .id(message.id)
                            }
                            
                            if isThinking {
                                ThinkingIndicator()
                                    .id("thinking")
                            }
                        }
                        .padding()
                    }
                    .onTapGesture {
                        inputIsFocused = false
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let lastMessage = messages.last {
                            withAnimation {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: isThinking) { _, newValue in
                        if newValue {
                            withAnimation {
                                proxy.scrollTo("thinking", anchor: .bottom)
                            }
                        }
                    }
                }
                
                // Input area
                Divider()
                
                HStack(spacing: 12) {
                    TextField("Your answer...", text: $userInput, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                        )
                        .focused($inputIsFocused)
                        .disabled(isThinking || conversationStage == .done)
                        .onSubmit {
                            sendMessage()
                        }
                    
                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .blue)
                    }
                    .disabled(userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isThinking || conversationStage == .done)
                }
                .padding()
            }
            .navigationTitle("Brainstorm Ideas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .overlay {
                if showConfirmation {
                    MagicalPromptConfirmation(
                        isPresented: $showConfirmation,
                        onUse: {
                            if let prompt = currentPrompt {
                                onSelectPrompt(prompt)
                                dismiss()
                            }
                        },
                        onRefine: {
                            showConfirmation = false
                        }
                    )
                }
            }
            .onAppear {
                startConversation()
            }
        }
    }
    
    private func startConversation() {
        let greetings = [
            "Hey! How are you?",
            "Hi there! How's it going?",
            "Hey! Tell me about something funny that happened today.",
            "Hi! What's new with you?",
            "Hey there! How's your day been?",
            "Hi! Anything interesting happen today?",
            "Hey! What made you smile today?",
            "Hi there! What's been on your mind lately?",
            "Hey! How are you feeling today?",
            "Hi! What's something cool you discovered recently?",
            "Hey there! What have you been up to?",
            "Hi! Tell me something interesting about your day.",
            "Hey! What's caught your attention lately?",
            "Hi there! How have things been going?",
            "Hey! What's something you're curious about?",
            "Hi! How's your week going so far?",
            "Hey there! What's making you happy today?",
            "Hi! Tell me about something you're excited about.",
            "Hey! What's been inspiring you lately?",
            "Hi there! How are things with you?",
            "Hey! What's something new you learned recently?",
            "Hi! What's on your mind right now?",
            "Hey there! Tell me what you've been thinking about.",
            "Hi! What's something good that happened lately?",
            "Hey! What are you in the mood for today?",
            "Hi there! How's everything going?",
            "Hey! What's something you're looking forward to?",
            "Hi! Tell me about your day so far.",
            "Hey there! What's been fun recently?",
            "Hi! What made you laugh today?",
            "Hey! How have you been lately?",
            "Hi there! What's something that caught your eye today?",
            "Hey! What's been keeping you busy?",
            "Hi! Tell me something random!",
            "Hey there! What's something you've been enjoying?",
            "Hi! How's life treating you?",
            "Hey! What's a fun thing you did recently?",
            "Hi there! What's something you're working on?",
            "Hey! Tell me about something interesting.",
            "Hi! What's been good with you?",
            "Hey there! What's something that surprised you today?",
            "Hi! How are you doing today?",
            "Hey! What's something you're grateful for today?",
            "Hi there! What's been memorable lately?",
            "Hey! Tell me what's been going on.",
            "Hi! What's something you find fascinating right now?",
            "Hey there! What's a story you want to share?",
            "Hi! How's your day treating you?",
            "Hey! What's been interesting in your world?",
            "Hi there! Tell me about something you noticed today."
        ]
        
        let greeting = greetings.randomElement() ?? greetings[0]
        messages.append(ChatMessage(text: greeting, isUser: false))
        conversationStage = .exploring
        
        // Auto-focus input after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            inputIsFocused = true
        }
    }
    
    private func sendMessage() {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        messages.append(ChatMessage(text: trimmed, isUser: true))
        userInput = ""
        
        Task {
            await generateResponse(userMessage: trimmed)
        }
    }
    
    private func generateResponse(userMessage: String) async {
        isThinking = true
        
        do {
            let response: String
            
            switch conversationStage {
            case .initial:
                response = ""
                
            case .exploring:
                // Respond naturally and spontaneously to the conversation
                let allMessages = messages.filter { $0.isUser }.map { $0.text }.joined(separator: " | ")
                
                let prompt = """
                You are a friendly assistant helping brainstorm language learning lesson ideas.
                
                Conversation so far: "\(allMessages)"
                Latest message: "\(userMessage)"
                
                Respond naturally. You can:
                - Ask ONE question to learn more (about topics, interests, settings, mood, details, etc.)
                - Make a brief observation or comment
                - Express curiosity about something they mentioned
                
                IMPORTANT:
                - Ask only ONE question per response
                - Keep it very short and conversational (1-2 sentences max)
                - Be natural and spontaneous, don't follow a pattern
                - Do NOT ask about text length or language level
                """
                
                response = try await generator.chatViaProxySimple(prompt)
                // Stay in exploring stage for follow-ups
                
            case .refining:
                // Check if user wants refinement or is ready to generate
                let lowerMessage = userMessage.lowercased()
                let seemsPositive = lowerMessage.contains("yes") || lowerMessage.contains("good") || 
                                   lowerMessage.contains("sounds") || lowerMessage.contains("perfect") ||
                                   lowerMessage.contains("great") || lowerMessage.contains("ok") ||
                                   lowerMessage.contains("sure") || lowerMessage.contains("yeah")
                
                if seemsPositive && currentPrompt != nil {
                    // User seems happy, acknowledge and finish
                    let responses = [
                        "Awesome! Tap the green checkmark to use this prompt.",
                        "Perfect! Hit the checkmark when you're ready.",
                        "Great! The checkmark will apply this prompt.",
                        "Sounds good! Use the checkmark to confirm."
                    ]
                    response = responses.randomElement() ?? responses[0]
                    conversationStage = .done
                } else {
                    // Generate refined version
                    let currentPromptText = currentPrompt ?? "the previous idea"
                    let allUserMessages = messages.filter { $0.isUser }.map { $0.text }.joined(separator: " | ")
                    
                    let prompt = """
                    Context: "\(allUserMessages)"
                    Current: "\(currentPromptText)"
                    Feedback: "\(userMessage)"
                    
                    Create a REFINED lesson prompt (1-2 sentences) based on their feedback. Make it vivid and scenario-based.
                    
                    Format your response EXACTLY as:
                    Line 1: PROMPT: [refined prompt in plain text only]
                    Line 2: [blank line]
                    Line 3: A natural follow-up question asking if this version is better or if they'd like more changes (one sentence)
                    
                    IMPORTANT: You MUST include the follow-up question on line 3.
                    No asterisks or formatting in the prompt text.
                    """
                    
                    response = try await generator.chatViaProxySimple(prompt)
                    let (textPart, extractedPrompt) = extractPromptAndText(from: response)
                    
                    isThinking = false
                    
                    // ORDER: Prompt first, then follow-up question
                    // Add refined prompt first
                    if let prompt = extractedPrompt {
                        currentPrompt = prompt
                        messages.append(ChatMessage(text: prompt, isUser: false, isPrompt: true))
                    }
                    
                    // Add the follow-up question/comment (with fallback)
                    let followUp = textPart.isEmpty ? "Is this version better?" : textPart
                    messages.append(ChatMessage(text: followUp, isUser: false))
                    
                    return
                }
                
            case .done:
                response = ""
            }
            
            // Check if we should generate first prompt
            if conversationStage == .exploring && messages.filter({ $0.isUser }).count >= 2 {
                // User has answered follow-ups, generate initial prompt
                let allUserResponses = messages.filter { $0.isUser }.map { $0.text }.joined(separator: " | ")
                
                let genPrompt = """
                Based on: "\(allUserResponses)"
                
                Create ONE creative lesson prompt (1-2 sentences) for language learning.
                Make it a specific, vivid scene.
                
                Format your response EXACTLY as:
                Line 1: PROMPT: [the actual prompt in plain text, no formatting]
                Line 2: [blank line]
                Line 3: A natural follow-up question asking what they think or if they'd like to refine it (one sentence)
                
                IMPORTANT: You MUST include the follow-up question on line 3.
                Use plain text only, no asterisks or special characters in the prompt.
                """
                
                let promptResponse = try await generator.chatViaProxySimple(genPrompt)
                let (textPart, extractedPrompt) = extractPromptAndText(from: promptResponse)
                
                isThinking = false
                
                // ORDER: Prompt first, then follow-up question (NO response before prompt)
                // Add prompt first
                if let prompt = extractedPrompt {
                    currentPrompt = prompt
                    messages.append(ChatMessage(text: prompt, isUser: false, isPrompt: true))
                }
                
                // Add the follow-up question/comment (with fallback)
                let followUp = textPart.isEmpty ? "What do you think about this prompt?" : textPart
                messages.append(ChatMessage(text: followUp, isUser: false))
                
                conversationStage = .refining
                return
            }
            
            if !response.isEmpty {
                isThinking = false
                messages.append(ChatMessage(text: response, isUser: false))
            } else {
                isThinking = false
            }
            
        } catch {
            isThinking = false
            messages.append(ChatMessage(text: "Sorry, I had trouble. Please try again.", isUser: false))
        }
    }
    
    private func extractPromptAndText(from response: String) -> (text: String, prompt: String?) {
        guard let promptRange = response.range(of: "PROMPT:", options: .caseInsensitive) else {
            // No prompt found, return whole response as text
            return (response.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        
        // Extract text before "PROMPT:"
        let beforePrompt = String(response[..<promptRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Extract prompt part
        let afterPromptMarker = response[promptRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        var extractedPrompt = ""
        var textAfterPrompt = ""
        
        // Find where prompt ends (newline or end of string)
        if let newlineRange = afterPromptMarker.range(of: "\n") {
            extractedPrompt = String(afterPromptMarker[..<newlineRange.lowerBound])
            textAfterPrompt = String(afterPromptMarker[newlineRange.upperBound...])
        } else {
            extractedPrompt = String(afterPromptMarker)
        }
        
        // Clean the prompt
        let cleanedPrompt = extractedPrompt
            .replacingOccurrences(of: "[*_\"'`]+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Combine before and after text
        var combinedText = beforePrompt
        if !textAfterPrompt.isEmpty {
            if !combinedText.isEmpty {
                combinedText += "\n\n"
            }
            combinedText += textAfterPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return (combinedText, cleanedPrompt.isEmpty ? nil : cleanedPrompt)
    }
}

private struct ThinkingIndicator: View {
    @State private var rotation: Double = 0
    
    var body: some View {
        HStack(spacing: 12) {
            // Animated sparkles icon
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.yellow)
                .rotationEffect(.degrees(rotation))
                .onAppear {
                    withAnimation(
                        .linear(duration: 2)
                        .repeatForever(autoreverses: false)
                    ) {
                        rotation = 360
                    }
                }
            
            /*
            Text("Thinking")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
            */
        }
        .padding(.horizontal)
    }
}

private struct MagicalPromptConfirmation: View {
    @Binding var isPresented: Bool
    var onUse: () -> Void
    var onRefine: () -> Void
    
    @State private var scale: CGFloat = 0.8
    @State private var opacity: Double = 0
    @State private var sparkleRotation: Double = 0
    
    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    onRefine()
                }
            
            // Magical confirmation card
            VStack(spacing: 24) {
                // Sparkles decoration at top
                HStack(spacing: 8) {
                    ForEach(0..<3) { index in
                        Image(systemName: "sparkles")
                            .font(.system(size: 20))
                            .foregroundStyle(.yellow)
                            .rotationEffect(.degrees(sparkleRotation + Double(index * 120)))
                    }
                }
                
                // Main prompt icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.purple.opacity(0.3), .blue.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 80, height: 80)
                    
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.purple, .blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                
                Text("Use this prompt?")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                
                HStack(spacing: 16) {
                    // Keep Refining button
                    Button {
                        onRefine()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 32))
                                .foregroundStyle(.orange)
                            
                            Text("Refine")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.orange.opacity(0.5), lineWidth: 2)
                        )
                    }
                    
                    // Use Prompt button
                    Button {
                        onUse()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.green)
                            
                            Text("Use It!")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.green.opacity(0.5), lineWidth: 2)
                        )
                    }
                }
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(.systemGroupedBackground))
                    .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
            )
            .padding(.horizontal, 40)
            .scaleEffect(scale)
            .opacity(opacity)
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                scale = 1.0
                opacity = 1.0
            }
            
            withAnimation(
                .linear(duration: 3)
                .repeatForever(autoreverses: false)
            ) {
                sparkleRotation = 360
            }
        }
    }
}

private struct ChatBubble: View {
    let message: PromptBrainstormView.ChatMessage
    var onSelectPrompt: (String) -> Void
    
    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 50) }
            
            if message.isPrompt {
                // Special prompt bubble - selectable
                Button {
                    onSelectPrompt(message.text)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.yellow)
                            .padding(.top, 2)
                        
                        Text(message.text)
                            .font(.body)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.tertiarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.green.opacity(0.4), lineWidth: 2)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // Regular text bubble
                Text(message.text)
                    .font(.body)
                    .foregroundColor(message.isUser ? .white : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(message.isUser ? Color.blue : Color(.secondarySystemBackground))
                    )
            }
            
            if !message.isUser { Spacer(minLength: 50) }
        }
        .padding(.horizontal)
    }
}

