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

    @State private var speechSpeed: SpeechSpeed = .regular

    
    // MARK: - Prompt categories

    enum PromptCategory: String, CaseIterable, Identifiable {
        case all = "All"
        case sea = "Sea"
        case mountains = "Mountains"
        case forest = "Forest"
        case desert = "Desert"
        case riversLakes = "Rivers & Lakes"
        case sky = "Sky"
        case wildlife = "Wildlife"
        case space = "Space"
        case adventure = "Adventure"
        case calm = "Calm"
        case travel = "Travel"
        case reflection = "Reflection"
        case city = "City"
        case familyFriends = "Family & Friends"
        case food = "Food"
        case artMusic = "Art & Music"
        case history = "History"
        case movement = "Movement"
        case pets = "Pets"
        case natureCloseUp = "Nature Close-Up"
        case gratitude = "Gratitude"
        case mystery = "Mystery"
        case tech = "Tech"
        case ethics = "Ethics"
        case humor = "Humor"
        case dreams = "Dreams"

        var id: String { rawValue }
    }

    @State private var selectedPromptCategory: PromptCategory = .all

    private let promptsByCategory: [PromptCategory: [String]] = [
        // --- Outdoor & Exploration ---
        .sea: [
            "Describe a dawn paddle through fog. Include kelp scent, gull shadows, and a rip current. End by dropping into your first clean wave.",
            "Tell a beach rescue from the lifeguard’s view: red flag, torn leash, sprint, hand to wrist.",
            "Plan a low-tide reef entry: urchins underfoot, timing the surge, following a spotted ray to a safe channel.",
            "Describe leaving harbor by sound and smell: diesel, bell, rope slip, foghorn cut short, then the fog opens.",
            "Night-dive where each kick blooms blue; a curious seal circles; choose a heading under Orion."
        ],
        .mountains: [
            "Write a summit push in present tense: crampons on blue ice, rope calls, cornice decision, turn back 50 meters.",
            "Navigate a whiteout: leave the tent, take a bearing, pace by breath counts, probe for crevasses, find the next cairn.",
            "Cross a sunrise ridge: alpenglow, thin air, penitentes, a raven gliding; end with the valley lighting up.",
            "Lose the altimeter: steer by sun angle, snow texture, and breath counts to a safe notch and coffee steam.",
            "Lightning bivouac; hair lifts under the zipper; count flash to thunder; share chocolate until the storm walks away."
        ],
        .forest: [
            "Hike at dusk with a red headlamp. Note moths in the beam, wet cedar, and the moment you step into a clearing.",
            "Track after rain: read a split hoof, crushed mint, and a snapped fern; explain where the animal turned off.",
            "Cross through the canopy: harness creak, bark under fingers, wind like a tide; name one new shade of green.",
            "Learn woodpecker code: three cadences, what each means, and the tree that answers back.",
            "Storm-fall reveals a root doorway; soil like tea, beetle spirals; leave a small offering before you step through."
        ],
        .desert: [
            "Walk a sunrise dune line. Include cold sand squeak, first edge of heat, and a lark sharing your shadow.",
            "Build shelter in a dust storm: sky turns copper, tie the scarf, make a lee wall, count breaths until calm.",
            "Cross a salt flat: explain mirage rules, manage blisters, and reach a shoreline that maps got wrong.",
            "Find water by reading wind ripples on sand. Mark how you confirmed it before digging.",
            "At high noon the canyon speaks once; step into the beam, ask one question, and accept the answer."
        ],
        .riversLakes: [
            "Ferry-glide a foggy river bend: bow angle, eddy lines, heron lift-off; land in a quiet backwater.",
            "Write a flood cleanup scene: mud lines on walls, borrowed pumps, one found photo, hot stew shared.",
            "Describe first lake ice: singing cracks, safety checks, breath clouds, one clean skate line.",
            "Portage around a waterfall: rising roar, slick moss, shoulder ache; launch where water carries, not fights.",
            "Night swim under a bright moon; cold shock, quick laughter, stars repeating in ripples."
        ],
        .sky: [
            "Capture the air before rain: metallic taste, pressure drop, swallows low, first heavy drops.",
            "Watch a thunderstorm from a safe porch: sheet lightning, counting seconds, roof drum, quiet after.",
            "Teach three constellations from a rooftop blanket using story, not lines. Explain one common mistake.",
            "Describe the afternoon a drought breaks: smell arrives, dust darkens, neighbors step outside.",
            "Aurora writes in verbs; choose one and act by morning."
        ],
        .wildlife: [
            "Track a big cat by absence: undisturbed snow, clear crossing points, one soft print at the edge.",
            "Explain how to watch a migrating flock without changing its path. Describe one reason they detoured.",
            "Resolve a fence problem between wolves and ranchers using language, not wire. Show the new rule.",
            "Hold a tidepool vote: who eats, who hides, who yields; explain why yielding wins.",
            "An injured raptor lands on your glove uninvited; accept the oath implied."
        ],
        .space: [
            "Navigate a small craft through a meteor shower. Explain the upward fall and how you steer through it.",
            "Chart by pulsars after the nav computer forgets your name. Show the pattern you trust.",
            "Dock at a station over a blue world; find the quiet room and who goes there.",
            "Choose noon or midnight on a tidally locked planet. Describe the culture on your side.",
            "A derelict probe broadcasts a lullaby; translate without waking what listens."
        ],
        .adventure: [
            "Use a rumor map to find a moving valley. Explain how you caught it on a cloudy day.",
            "Free-dive a blue hole where depth feels like time. Bring back one minute you lost and why.",
            "Packraft from glacier to sea. List the hazards, the questions you carried, and which one you let sink.",
            "Sail a new coastline with paper charts. Log one correction for the next sailor.",
            "An ice cave hoards lightning; thread the chambers without waking the light."
        ],
        .calm: [
            "Walk a night beach. Read three short lines the tide writes and keep one.",
            "Make tea while rain starts. Time the scene by steam and window sound.",
            "Watch snow under a streetlamp. Count silence between flakes until thoughts thin.",
            "Ride a slow train through dark fields. List what you leave behind by the mile.",
            "Lanterns lead through a narrow canyon; let shadows finish the sentences."
        ],
        .travel: [
            "Open a street market at daybreak. Follow three smells to three stalls and the story that links them.",
            "Map an island with no cars. Measure distance by footsteps and ferry schedules.",
            "Walk a city by its waterways. Collect two secrets from bridges.",
            "Stay a night in a lighthouse hostel. Describe the beam’s pattern and what it teaches.",
            "Taste a town by its bakeries. Choose a winner and justify the choice."
        ],
        .reflection: [
            "Show how a big landscape made you humbler or braver by one changed habit.",
            "Explain one lesson risk taught you that talent did not.",
            "Describe how solitude changed what you noticed and what noticed you.",
            "Draw the line between naming a place and trying to own it. Use one example.",
            "Write your code for treating places well, then apply it once."
        ],

        // --- People & Life ---
        .city: [
            "Map one block at sunrise by smell: bakery, rain, coffee, and what each says about the day.",
            "Follow one bee from a rooftop garden to its secret stopover. Describe why it chose that route.",
            "Write a late-night subway car with four strangers, one shared truth, and how it surfaces.",
            "Ride a river ferry through downtown. Stitch two lives together during one crossing.",
            "Rain turns crosswalks into mirrors; meet your reflection doing something braver and catch up."
        ],
        .familyFriends: [
            "Keep a family tradition that started by accident. Show how you keep the accident on purpose.",
            "Write the thank-you you never said and the reply you hope for.",
            "Cook together and recover when it goes wrong. Show the moment that saves the night.",
            "End a disagreement in understanding, not victory. Quote the sentence that turned it.",
            "Repay moving-day helpers without money. Make the payback matter."
        ],
        .food: [
            "Tell a trip through three meals. Let each plate change your plan.",
            "Use a handed-down recipe that only works when you break one rule. Explain the rule and why.",
            "Wait in a long street-food line. Share the lesson the line taught, not just the flavor.",
            "Bake bread and name the moment the room forgives the day.",
            "Open five spices, link each aroma to a memory, then make one new promise."
        ],
        .artMusic: [
            "A busker changes the street’s pace. Pay with a story that earns an encore.",
            "Stand before one painting that will not let you pass. Settle the unpaid debt it claims.",
            "Learn an instrument and mark the first clean note that rearranges your day.",
            "Interview a wall about a new mural and the neighbors who watched it appear.",
            "Backstage before curtain, show the bargain performers make with fear."
        ],
        .history: [
            "Find the hinge day when a quiet town changed. Name who felt it first.",
            "Answer a letter that crossed a century and arrived late. Close the loop.",
            "Play a reenactor who doubts the script. Choose truth or role and live the result.",
            "Restore a photo missing a corner. Tell the part outside the frame.",
            "Open a time capsule. Decide which item returns to earth and which to memory."
        ],
        .movement: [
            "Balance on a board for the first time. Mark the instant you trusted friction.",
            "Run before sunrise and claim one empty mile as your own.",
            "Describe the cue that finally unlocked a yoga pose for you.",
            "Climb on belay and show what the rope holds besides weight.",
            "Learn a kayak stroke on moving water. Explain the correction that kept you straight."
        ],
        .pets: [
            "Write one day from your pet’s view. Include one secret you missed and why they kept it.",
            "Record the exact cue that made a training session click for both of you.",
            "Describe the moment during adoption when you knew this was your animal.",
            "Script a calm vet visit. Show the kindness that made it work for everyone.",
            "Care for an aging pet with dignity. Invent one new way to play."
        ],
        .natureCloseUp: [
            "Study a single leaf until it becomes a landscape. Chart its rivers and ridges.",
            "Stage a tidepool drama with one protagonist, one obstacle, one tiny triumph.",
            "Describe an anthill by sound and motion. Explain what is being built.",
            "Follow one raindrop from cloud to soil to river to sea to cloud. List every helper.",
            "Frost writes on glass; speak one sentence aloud and mean it."
        ],
        .gratitude: [
            "Name three unseen helpers from this week and repay each in one line of action.",
            "Thank a place that steadies you. Say what you take and what you give back.",
            "Honor an ordinary object by counting its quiet saves today.",
            "Write to a mentor you never thanked and include the lesson you resisted first.",
            "Thank your body for one small competence. Be precise."
        ],
        .mystery: [
            "A key postmarked tomorrow arrives. Choose the first door you try and describe what happens.",
            "Footprints start in the middle of a field and end at your door. Decide whether to invite or refuse.",
            "A door appears only at dusk. Enter once and set one rule you will keep.",
            "Your radio plays yesterday’s news. Correct one story and note what changes tonight.",
            "A map without a legend marks a spot with a heartbeat. Go there and report what beats."
        ],
        .tech: [
            "Design a tiny tool that removes one daily friction. Narrate the first user’s delight.",
            "Fix an algorithm’s charming human mistake without killing the charm.",
            "Spend a day offline. Map what returns to your attention and keep one piece.",
            "Automate a small task. Show the before and after in human terms.",
            "Choose privacy over convenience once today. Capture the trade and the relief."
        ],
        .ethics: [
            "Write a traveler’s code for places you visit. Test it on one hard case.",
            "Describe a bystander moment and the action you chose. Explain why.",
            "Braid truth and kindness when they pull apart. Show the result.",
            "Draw the line where you refuse to trade privacy for convenience. Keep it.",
            "Tell how turning back saved more than safety. Name what else it saved."
        ],
        .humor: [
            "Let a day derail in small ways and land perfectly. Recount the chain that made it work.",
            "Play a polite misunderstanding that snowballs but keeps everyone likable.",
            "Give a grocery mishap heroic stakes and play it straight.",
            "Recover from a frozen video call face in a way that wins the room.",
            "Turn a kitchen disaster into applause. Show the pivot."
        ],
        .dreams: [
            "A recurring dream changes one detail. Follow the change to its source.",
            "Walk a city that exists only when you sleep. Bring back one law and one street.",
            "Fly in thick air. Learn the technique and teach it once.",
            "Meet your future self on a bench. Ask one question you will obey.",
            "Climb a staircase that loops. Record what changes each pass."
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
        Section {
            let allModes: [GenerationMode] = Array(GenerationMode.allCases)
            Picker("Generation Mode", selection: $mode) {
                ForEach(allModes, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            HStack(spacing: 6) {
                Text("Mode")
                Button {
                    showModeInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About Mode")

                // iPad/regular width
                .modifier(RegularWidthPopover(isPresented: $showModeInfo) {
                    ModeInfoCard()
                        .frame(maxWidth: 360)
                        .padding()
                })

                // iPhone/compact width
                .sheet(isPresented: Binding(
                    get: { hSize == .compact && showModeInfo },
                    set: { showModeInfo = $0 }
                )) {
                    ModeInfoCard()
                        .presentationDetents([.fraction(0.35), .medium])
                        .presentationDragIndicator(.visible)
                }

                Spacer()
            }
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
