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

// MARK: - Persisted settings

private struct GeneratorSettings: Codable, Equatable {
    var mode: String
    var segmentation: String
    var lengthPresetRaw: Int
    var genLanguage: String
    var transLanguage: String
    var languageLevel: String
    var speechSpeed: String
}

private extension GeneratorSettings {
    static func fromViewState(
        mode: GeneratorView.GenerationMode,
        segmentation: GeneratorView.Segmentation,
        lengthPreset: GeneratorView.LengthPreset,
        genLanguage: String,
        transLanguage: String,
        languageLevel: LanguageLevel,
        speechSpeed: GeneratorView.SpeechSpeed
    ) -> GeneratorSettings {
        .init(
            mode: mode.rawValue,
            segmentation: segmentation.rawValue,
            lengthPresetRaw: lengthPreset.rawValue,
            genLanguage: genLanguage,
            transLanguage: transLanguage,
            languageLevel: languageLevel.rawValue,
            speechSpeed: speechSpeed.rawValue
        )
    }
}

struct GeneratorView: View {
    @EnvironmentObject private var purchases: PurchaseManager
    @State private var showBuyCredits = false
    
    @EnvironmentObject private var lessonStore: LessonStore
    @EnvironmentObject private var generator: GeneratorService
    @Environment(\.dismiss) private var dismiss

    // Persistence for aspect selections
    @AppStorage("styleTableJSON") private var styleTableJSON: Data = Data()
    @AppStorage("interestRowJSON") private var interestRowJSON: Data = Data()
    
    // Persist all generator knobs in one blob
    @AppStorage("generatorSettingsV1") private var generatorSettingsData: Data = Data()
    
    @AppStorage("generatorPromptV1") private var userPrompt: String = ""
    @AppStorage("generatorRandomTopicV1") private var randomTopic: String = ""


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

    // --- Add to GeneratorView state ---
    @State private var knownLessonIDs = Set<String>()
    @State private var newlyCreatedLesson: Lesson?     // lesson to show in the toast
    @State private var showToast: Bool = false
    @State private var navTargetLesson: Lesson?        // drives navigationDestination
    @State private var toastHideWork: DispatchWorkItem?
    
    @FocusState private var promptIsFocused: Bool

    private let supportedLanguages: [String] = [
        "Afrikaans","Arabic","Armenian","Azerbaijani","Belarusian","Bosnian","Bulgarian","Catalan","Chinese (Simplified)","Chinese (Traditional)","Croatian",
        "Czech","Danish","Dutch","English","Estonian","Finnish","French", "French (Canada)","Galician","German","Greek","Hebrew","Hindi",
        "Hungarian","Icelandic","Indonesian","Italian","Japanese","Kannada","Kazakh","Korean","Latvian","Lithuanian",
        "Macedonian","Malay","Marathi","Maori","Nepali","Norwegian","Persian","Polish","Portuguese (Portugal)","Portuguese (Brazil)","Romanian","Russian",
        "Serbian","Slovak","Slovenian","Spanish","Spanish (Latinoamérica)","Spanish (Mexico)","Swahili","Swedish","Tagalog","Tamil","Thai","Turkish","Ukrainian",
        "Urdu","Vietnamese","Welsh"
    ]

    // Modes
    enum GenerationMode: String, CaseIterable, Identifiable {
        case random = "Random"
        case prompt = "Prompt"
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

    @State private var speechSpeed: SpeechSpeed = .regular

    
    // MARK: - Prompt categories

    enum PromptCategory: String, CaseIterable, Identifiable {
        case all = "All"
        case sea = "Sea"
        case peaks = "Peaks"
        case woods = "Woods"
        case desert = "Desert"
        case waters = "Waters"
        case sky = "Sky"
        case creatures = "Creatures"
        case cosmos = "Cosmos"
        case quest = "Quest"
        case calm = "Calm"
        case travel = "Travel"
        case elements = "Elements"
        case place = "Place"
        case insight = "Insight"

        var id: String { rawValue }
    }

    @State private var selectedPromptCategory: PromptCategory = .all

    private let promptsByCategory: [PromptCategory: [String]] = [
        .sea: [
            "Paddle toward a late, larger swell that carries a message only you can hear.",
            "Night-dive where every kick paints light; find who made the brightest trail.",
            "A reef hums like a choir—translate its chords into choices.",
            "A storm lifts the ocean like a muscle; trust something when the horizon bends.",
            "A coastal village measures time by tides and migrating whales; one storm rewrites its myths.",
            "A lighthouse log records the week the fog refused to lift.",
            "Chase a single perfect wave for a season—and tally the cost of patience.",
            "Sail by scent and sound alone; chart a map of winds instead of stars.",
            "Free-dive through kelp cathedrals; read stained-glass light.",
            "Follow a pod of dolphins; decide when to leave.",
            "A shipwreck surfaces at low tide; what debt remains?",
            "Learn to breathe with the swell, not against it.",
            "A rogue wave teaches proportion; write the lesson.",
            "Fishers predict weather by gull grammar; test it.",
            "A sea cave speaks in echoes; answer once.",
            "Navigate a maze of shoals by water color alone.",
            "A sailor’s knot saves a friendship at sea.",
            "Chart currents as conversations; join one midway.",
            "A beachcomber finds a compass that points to storms.",
            "A glassy dawn demands stillness over speed."
        ],
        .peaks: [
            "Negotiate each pitch with a mountain that changes its mind.",
            "A ridge at sunrise—write what fear omits when light arrives.",
            "Base camp barters stories like oxygen; trade one you wish you hadn’t.",
            "Turn back fifty meters from the top; defend it to yourself.",
            "A glacial crevasse field reads like history in blue.",
            "Lightning forces a bivy; count time by heartbeats.",
            "Thin air edits your thoughts—what words remain?",
            "The ethics of retreat prove heavier than the summit itself.",
            "Crampons sing on blue ice; hear the key.",
            "Cross a corniced ridge; trust the snow’s whisper.",
            "A prayer flag frays; tell what unravels with it.",
            "Avalanche shadow passes; measure the silence afterward.",
            "Summit fever visits camp; refuse politely.",
            "Glissade into a cloud; name each shade of gray.",
            "A crevasse rescue redefines rope teams and truth.",
            "The altimeter fails; navigate by breath count.",
            "Mountain goats set the route; follow or resist?",
            "Whiteout confines you to a tent; expand inward.",
            "A cairn offers two arrows; choose the windier.",
            "Descend by headlamp; memories glow like waypoints."
        ],
        .woods: [
            "Walk the canopy where green has a hundred dialects.",
            "A blind botanist maps a grove by taste and temperature.",
            "Night in the research hut: identify every sound by memory alone.",
            "After a burn, the first rain writes new script—decipher it.",
            "Two trails—official and deer-made—argue about truth.",
            "A windthrow opens the sky and a secret.",
            "Navigate by birdsong when compasses spin.",
            "The oldest tree speaks—only to patient listeners.",
            "Mist holds shapes that vanish when named.",
            "Forage by moonlight; learn a plant’s secret taste.",
            "A river of ants diverts you; step kindly.",
            "A fallen log bridges years as well as creeks.",
            "Mushrooms appear overnight; choose which story to tell.",
            "A hollow trunk stores letters; read the one for you.",
            "Woodpecker drumming maps hidden hollows; follow the beat.",
            "First snow powders needles; track a fox to humility.",
            "Ferns uncurl like questions at sunrise.",
            "Follow a deer trail to a human truth.",
            "The forest edge teaches borders without walls.",
            "Campfire sparks mirror stars; decide which to trust."
        ],
        .desert: [
            "Dunes move like tides; learn the moon’s role in sand.",
            "A sandstorm erases steps and certainty—what guides you now?",
            "Cross a salt flat where distance behaves like heat.",
            "Read wind-script in ripples to find water.",
            "A canyon speaks only at noon when light finds it.",
            "An oasis keeps a rumor older than palms.",
            "Learn the difference between empty and spacious.",
            "A migrating dune field teaches a village how to move.",
            "A cracked clay pan records last year’s thunder.",
            "Follow beetle tracks to morning shade.",
            "The horizon shimmers with rumors; verify one.",
            "Night sky pours meteors; make fewer wishes.",
            "Date palms share water through roots; learn generosity.",
            "Basalt boulders ring when struck; compose a map.",
            "A dried riverbed remembers the sea; listen close.",
            "Scorpions glow under ultraviolet; count courage.",
            "A caravansary welcomes stories as payment.",
            "Camel bells pace your heartbeat; match them.",
            "Lightning-glass hides beneath sand; find a thread.",
            "Build shelter from shadow and silence."
        ],
        .waters: [
            "Tell a river’s life from spring to delta through those who cross it.",
            "Canoe in fog, navigating by the grammar of rapids.",
            "A flood returns buried letters; choose which to open.",
            "The lake freezes; beneath, whales of sound migrate.",
            "A wetland restoration redeems its keeper—at a cost.",
            "A ferryman accepts silence as fare; why now?",
            "Moonlight cuts lanes across a black lake—swim one.",
            "An oxbow returns after a century, cutting a town in two.",
            "Stones skip like thoughts; which one crosses?",
            "Follow a trout run upstream to a decision.",
            "A ferry runs only at fog; dare the crossing.",
            "River ice breaks in thunder; what goes with it?",
            "Lake-effect snow writes soft borders.",
            "Wet boots teach patience better than sermons.",
            "A spring emerges where maps say none.",
            "Canoe portage reveals kindness between strangers.",
            "A dam removal frees more than water.",
            "River pilots swap myths at midnight locks.",
            "Lily pads chart a quiet labyrinth; paddle gently.",
            "A loon’s call threads dusk; stitch your memory to it."
        ],
        .sky: [
            "A town predicts rain by swallows better than satellites; prove it.",
            "Chasing storms cures a fear you didn’t name.",
            "One hill, a year of sunsets—what changed you, not the light.",
            "Drought ends in an afternoon; gratitude sounds like thunder.",
            "Aurora arrives; describe verbs written on air.",
            "Heatwave etiquette: measures of kindness in shade.",
            "Fog teaches you to move without horizons.",
            "Hail sculpts the land—and a new resolve.",
            "A meteor shower resets calendars; start again.",
            "Learn constellations by mistakes; rename three.",
            "A rainbow repeats as a double; interpret the echo.",
            "Contrails cross; pick a future line.",
            "Lenticular clouds stack over peaks; predict change.",
            "A weather vane lies; trust the willow leaves.",
            "Moon halos foretell snow; prepare without worry.",
            "A pressure drop tastes metallic; describe the prelude.",
            "Birds fall silent before storm; write the interval.",
            "Thermal updrafts teach hawks; ride one briefly.",
            "After the tornado, the town learns calm from canvas.",
            "Dawn’s first blue is a promise; keep it."
        ],
        .creatures: [
            "Track a snow leopard you never see; prove presence with absence.",
            "Migrate with a bird that remembers a route older than maps.",
            "A ranger mediates wolves and ranchers; the first fence is language.",
            "Tidepool politics: who rules when the tide leaves?",
            "A beekeeper listens to hives like organs of a field.",
            "Whale song becomes coordinates; follow them.",
            "A highway cuts a migration; build a promise across it.",
            "A stranded sea turtle rescue knits a community.",
            "Otters teach raft-sleep; try it on land.",
            "A bear visits an orchard; negotiate boundaries.",
            "Fireflies map courtship; walk their grammar.",
            "A heron misses a strike; write about grace.",
            "Ants cross a picnic; practice generosity.",
            "A shepherd learns stars from his flock’s eyes.",
            "A coral nursery rebuilds a reef; measure hope.",
            "Butterflies migrate through a city; escort them.",
            "A bat avoids you by listening to your shape.",
            "A feral cat chooses a home; accept the terms.",
            "Crabs sidestep problems; learn their logic.",
            "A whale calf approaches; practice stillness."
        ],
        .cosmos: [
            "Drift a small craft through quiet stars, docking where silence is deepest.",
            "Navigate by pulsars after the computer forgets your name.",
            "Meet a comet and redefine home.",
            "A tidally locked world teaches balance between scorch and frost.",
            "Shelter inside a hollow asteroid; patience is oxygen.",
            "Two ships trade stories instead of goods; you get the better deal.",
            "First sunrise on a new world—hold your breath and say why.",
            "A gardener astronaut grows memory in microgravity.",
            "A quiet station orbits a blue world; count dawns.",
            "Repair a solar sail by hand and patience.",
            "A derelict probe sends a lullaby; decode it.",
            "Asteroid miners find a fossil of light.",
            "A planet’s rings sing on approach; harmonize.",
            "Sleep between stars while engines whisper; dream maps.",
            "A black hole’s shadow teaches humility; turn away, then write.",
            "A moonquake rattles a secret loose.",
            "Drift through a dust storm on a red world; taste iron.",
            "Build a radio from scrap; hear distant weather.",
            "A cryogenic seed wakes and blooms in orbit.",
            "Plot a homecoming by constellations in your childhood window."
        ],
        .quest: [
            "Bushwhack to a valley mapped only in rumor; verify the gossip.",
            "Freedive a blue hole where depth becomes time.",
            "Thread an ice cave that hoards lightning.",
            "Packraft from glacier to sea with what fits in your hands.",
            "Bikepack a plateau where thunder runs like herds.",
            "Cross peat by intuition and old boardwalks.",
            "A long trail becomes a chain of brief, life-changing strangers.",
            "Sail a high-latitude route threading ice and doubt.",
            "Summit a lighthouse, not a peak; claim the view.",
            "Traverse a border of stone fences and stories.",
            "Hitchhike by river barge; repay in songs.",
            "Follow an eclipse across a continent.",
            "Search for a vanished footbridge; find what replaced it.",
            "Collect dawns from five time zones in a week.",
            "Apprentice to a cartographer who never uses ink.",
            "Walk a pilgrim path backward; discover origins.",
            "Ride the postal roads; deliver one letter you wrote.",
            "Cross a chain of islands by tide table.",
            "Winter camp on a frozen lake; hear it speak.",
            "Navigate a city only by alleys and whispers."
        ],
        .calm: [
            "Moonlit shoreline where foam writes haiku—read three before sleep.",
            "Slow-walk a pine grove after rain, breath pacing footsteps.",
            "Float a still lake; count stars like breaths.",
            "Lanterns in a narrow canyon; shadows lengthen into quiet.",
            "Rest in a meadow of nighttime insects—name the metronomes.",
            "Sit by a desert spring; watch light travel across stones.",
            "Snow hushes a mountain hut; list what you do not need.",
            "Drift through a glasshouse of warm air and soft leaves.",
            "Sip tea beside a rain-beaded window; trace one drop to sleep.",
            "Watch snow fall under a streetlight; count the quiet.",
            "Swing in a hammock as palm shadows lull.",
            "Sit on a pier at dusk; let the water answer.",
            "Listen to a ticking clock until it disappears.",
            "Slow brushstrokes color a blank sky; breathe with each pass.",
            "Page through an old field guide under a quilt.",
            "Rock in a train berth; let the wheels sing you under.",
            "Pet a sleepy dog; map its breathing.",
            "Fold laundry warm from the line; smooth the day.",
            "Beach at dawn: footprints appear after waves retreat.",
            "Candlelight in a power outage; share stories softly."
        ],
        .travel: [
            "Field notes from an island with oral maps; draw one you can speak.",
            "A market at daybreak told by scent and texture.",
            "Sketch a city by its waterways and the lives along them.",
            "A pilgrimage whose destination changes each morning.",
            "Untranslatable words gathered on the road—what did they unlock?",
            "Border crossings marked only by trees and dialect.",
            "A rail journey annotated with recipes from strangers.",
            "Review the world’s benches: view, wind, company.",
            "Cross a city by bakeries; choose the best crumb.",
            "Sleep in a lighthouse hostel; note the beam’s cadence.",
            "Follow tramlines to the oldest cafe.",
            "Trade books at a station library and leave a note.",
            "Map a place by its fountains and who meets there.",
            "Chase the day’s first bus to its last stop.",
            "Collect door knockers; imagine the hands that used them.",
            "Learn to say thank you in ten markets.",
            "Rent a bicycle by the harbor; ride the wind.",
            "Memorize a skyline by its nighttime reflections.",
            "Miss a connection; find a story you’d have missed.",
            "Walk a town’s rooftops by permission and luck."
        ],
        .elements: [
            "Basalt cools into memory; narrate the slow forgetting.",
            "Follow a raindrop through root, vein, sea, and cloud.",
            "Read mountains like torn letters—who wrote them?",
            "A wind farm and a hawk negotiate the sky.",
            "Wildfire teaches succession and second chances.",
            "Permafrost thaws; old stories wake and walk.",
            "A cave forms syllable by syllable in dripstone.",
            "A fault is a sentence waiting for its verb.",
            "Volcanic ash settles like soft memory; write what it covers.",
            "Lightning fuses sand into glass; hold a moment.",
            "Clay remembers hands; throw a bowl with intent.",
            "Granite wears down to patience; measure in grains.",
            "River silt builds a new delta; name it kindly.",
            "Coal becomes diamond under time; tell the pressure’s story.",
            "Fog condenses on spider silk; count pearls.",
            "Frost etches windows; read the morning script.",
            "Sediment layers archive a town’s habits.",
            "Echo maps inside a canyon; shout a thesis.",
            "A geyser’s schedule slips; wait anyway.",
            "Magnetite aligns in lava; find old north."
        ],
        .place: [
            "Write a love letter to the first horizon you trusted.",
            "Return to a childhood shore; inventory what stayed and what didn’t.",
            "The smell of rain on dust unlocks a locked year.",
            "A pocket stone becomes a compass for choices.",
            "Home is where your boots dry.",
            "A borrowed map carries previous owners’ hopes in its folds.",
            "A west-facing porch turns endings into invitations.",
            "Seasonal migration between two towns becomes a ritual.",
            "Adopt a corner cafe; note its changing cast.",
            "A footbridge becomes your hour hand; meet yourself there.",
            "The alley garden thrives by neglect; learn its law.",
            "A borrowed key opens a different version of home.",
            "Your shadow at noon marks a private meridian.",
            "Paint the doorway that taught you thresholds.",
            "The town’s oldest tree holds wedding ribbons; read names.",
            "A cul-de-sac hosts night games; hear laughter echo years.",
            "The bus stop newspaper box archives small heroics.",
            "A storm drain whispers the sea’s address.",
            "Streetlamps switch on like constellations; rename them.",
            "Pack a city into five objects; choose carefully."
        ],
        .insight: [
            "Do vast landscapes humble certainty or enlarge compassion—show, don’t preach.",
            "Is awe an ethical emotion that changes conduct?",
            "Conquest-mindset vs. listening-mindset exploration—argue with a story.",
            "Treat risk as a teacher of meaning, not a toll.",
            "Does solitude clarify or distort the self?",
            "Can wildness exist without witnesses?",
            "Where’s the line between reverence and romanticizing nature?",
            "Maps as promises—and betrayals—of reality.",
            "Are maps promises or betrayals? Argue with a journey.",
            "What does endurance reveal that talent hides?",
            "Can gratitude be practiced like navigation?",
            "Is attention our most renewable resource?",
            "When does naming become possession?",
            "Where is the border between safety and aliveness?",
            "Does beauty demand witness or create it?",
            "Is silence the ground of meaning or its absence?",
            "Can risk be generous?",
            "What’s the ethics of leaving no trace of joy?",
            "Is home a place, a practice, or a person?",
            "What do we owe the places that change us?"
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
        if let interest = interestSeed { parts.append("Interest: \(interest)") }

        if parts.isEmpty { return "Interest: capoeira ao amanhecer" } // final fallback
        return parts.joined(separator: " • ")
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
            speechSpeed: speechSpeed
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
    
    @ViewBuilder private func modeSection() -> some View {
        Section("Mode") {
            let allModes: [GenerationMode] = Array(GenerationMode.allCases)
            Picker("Generation Mode", selection: $mode) {
                ForEach(allModes, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder private func randomTopicSection() -> some View {
        if mode == .random {
            Section("Random Topic") {
                Text(randomTopic)
                    .font(.callout).foregroundStyle(.secondary)

                HStack {
                    Button("Randomize") { randomTopic = buildRandomTopic() }
                    Spacer(minLength: 12)
                    Button { showConfigurator = true } label: {
                        Label("Configure", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder private func promptSection() -> some View {
        if mode == .prompt {
            Section("Prompt") {
                TextEditor(text: $userPrompt)
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                    .padding(.vertical, 2)
                    .focused($promptIsFocused)

                // Random button (left) + category picker (right), no visible label
                HStack {
                    Button {
                        pickRandomPresetPrompt()
                    } label: {
                        Label("Random Prompt", systemImage: "die.face.5") // or "shuffle"
                    }
                    .buttonStyle(.bordered)

                    Spacer(minLength: 8)

                    Picker("", selection: $selectedPromptCategory) {
                        ForEach(PromptCategory.allCases) { cat in
                            Text(cat.rawValue).tag(cat)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    // (Optional) keep this for VoiceOver while hiding the label visually:
                    // .accessibilityLabel("Prompt category")
                }
                .padding(.top, 4)


                Text("Describe instructions, a theme, or paste a source text.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

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
                    Image(systemName: "info.circle")
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About Segmentation")
                // 👇 attach the popover to the *button*, not the Section
                .popover(isPresented: $showSegmentationInfo,
                         attachmentAnchor: .rect(.bounds),
                         arrowEdge: .top) {
                    SegmentationInfoCard()
                        .frame(maxWidth: 360)
                        .padding()
                }
                // On iPhone, show as a sheet automatically
                .presentationCompactAdaptation(.sheet)

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

    @ViewBuilder private func languagesSection() -> some View {
        Section("Languages") {
            Picker("Generate in", selection: $genLanguage) {
                ForEach(allSupportedLanguages, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)

            Picker("Translate to", selection: $transLanguage) {
                ForEach(allSupportedLanguages, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
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

                let req = GeneratorService.Request(
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

                generator.start(req, lessonStore: lessonStore)
            } label: {
                HStack { if generator.isBusy { ProgressView() }
                    Text(generator.isBusy ? "Generating..." : "Generate Lesson")
                }
            }
            .disabled(generator.isBusy || (mode == .prompt && userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))


            Text("Credits: \(serverBalance)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            
            if !generator.status.isEmpty {
                Text(generator.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    
    // MARK: - UI
    var body: some View {
        Form {
                modeSection()
                randomTopicSection()
                promptSection()
                segmentationSection()
                lengthSection()
                speechSpeedSection()
                levelSection()
                languagesSection()
                actionSection()
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
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { promptIsFocused = false }
            }
        }
        // Remove this block OR replace with:
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

        .navigationTitle("Generator")
        .listStyle(.insetGrouped)
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
            do {
                serverBalance = try await GeneratorService.fetchServerBalance()
            } catch {
                balanceError = error.localizedDescription
            }
        }

        .onReceive(NotificationCenter.default.publisher(for: .didPurchaseCredits)) { _ in
            Task {
                do { serverBalance = try await GeneratorService.fetchServerBalance() }
                catch { balanceError = error.localizedDescription }
            }
        }

        .sheet(isPresented: $showBuyCredits, onDismiss: {
            Task { await refreshServerBalance() }
        }) {
            NavigationStack {
                BuyCreditsView(presentation: .modal)
                    .environmentObject(purchases)
            }
        }

        // Refresh balance after a successful generation
        .onChange(of: generator.lastLessonID, initial: false) { _, _ in
            Task { await refreshServerBalance() }
        }


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
                        Text("Splits the text into sentence-sized segments. Great for quicker call-and-response practice.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "circle.fill").font(.caption2) }

                Divider()

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Paragraphs")
                            .font(.subheadline.bold())
                        Text("Keeps multi-sentence blocks together for natural flow and context. Ideal for longer listening and shadowing.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "rectangle.3.offgrid").font(.caption2) }
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
