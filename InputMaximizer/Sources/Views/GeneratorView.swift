//
//  GeneratorView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 27.08.25.
//

import SwiftUI

struct GeneratorView: View {
    @EnvironmentObject private var lessonStore: LessonStore
    @EnvironmentObject private var generator: GeneratorService
    @Environment(\.dismiss) private var dismiss   // optional, if you want to auto-close the screen
    
    
    // MARK: - Length preset
    enum LengthPreset: Int, CaseIterable, Identifiable {
        case short, medium, long, veryLong
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .short: return "Short"
            case .medium: return "Medium"
            case .long: return "Long"
            case .veryLong: return "Very Long"
            }
        }
        var words: Int {
            switch self {
            case .short: return 100
            case .medium: return 300
            case .long: return 600
            case .veryLong: return 1000
            }
        }
    }
    @State private var lengthPreset: LengthPreset = .medium
    
    // MARK: - State
    @State private var apiKey: String = "" // store/retrieve from Keychain in real use
    @State private var isBusy = false
    @State private var status = ""

    // Auto-filled from model output
    @State private var lessonID: String = "Lesson001"
    @State private var title: String = ""          // filled from generated PT title

    @State private var genLanguage: String = "Portuguese"
    @State private var transLanguage: String = "English"
    
    @State private var randomTopic: String?
    
    @FocusState private var promptIsFocused: Bool
    
    private let supportedLanguages: [String] = [
        "Afrikaans","Arabic","Armenian","Azerbaijani","Belarusian","Bosnian","Bulgarian","Catalan","Chinese","Croatian",
        "Czech","Danish","Dutch","English","Estonian","Finnish","French","Galician","German","Greek","Hebrew","Hindi",
        "Hungarian","Icelandic","Indonesian","Italian","Japanese","Kannada","Kazakh","Korean","Latvian","Lithuanian",
        "Macedonian","Malay","Marathi","Maori","Nepali","Norwegian","Persian","Polish","Portuguese","Romanian","Russian",
        "Serbian","Slovak","Slovenian","Spanish","Swahili","Swedish","Tagalog","Tamil","Thai","Turkish","Ukrainian",
        "Urdu","Vietnamese","Welsh"
    ]
    
    // Modes
    enum GenerationMode: String, CaseIterable, Identifiable {
        case random = "Random"
        case prompt = "Prompt"
        var id: String { rawValue }
    }
    @State private var mode: GenerationMode = .random
    @State private var userPrompt: String = ""

    // MARK: - Segmentation
    enum Segmentation: String, CaseIterable, Identifiable {
        case sentences = "Sentences"
        case paragraphs = "Paragraphs"
        var id: String { rawValue }
    }
    @State private var segmentation: Segmentation = .sentences
    
    // MARK: - Random topic source
    private let interests: [String] = [
        // 🌱 Movement / Embodied Practices
        "capoeira rodas ao amanhecer",
        "princípios e filosofia do jiu-jítsu",
        "kuzushi (desequilibrar) aplicado ao cotidiano",
        "respiração sob estresse (breathwork)",
        "rituais do surf e leitura do swell",
        "treino de apneia e mergulho livre",
        "taiji ao amanhecer em neblina de montanha",
        "peregrinações a pé e seus rituais",
        "dança improvisada como narrativa corporal",
        "movimento animal inspirado no ido portal",
        "caminhar descalço em terras desconhecidas",
        "jogos de equilíbrio em pontes naturais",
        "parkour como meditação urbana",
        "cartografar o corpo em quedas e rolamentos",
        "dança trance em desertos ao luar",
        "apneia em cavernas submersas",
        "treinos com pesos não convencionais (pedras, troncos)",
        "formas elementares inspiradas no dobrar da água, fogo, ar e terra",
        "movimento em espiral como fluxo de ar",
        "meditar em equilíbrio sobre troncos flutuantes",
        "prática de ‘cloud hands’ em picos nevados",
        "dançar ao redor de fogueiras como invocação",
        "explorar o ‘improviso marcial’ — luta como diálogo criativo",
        "imitar o voo de pássaros em exercícios de salto",
        "navegar movimentos de multidão como se fosse água",

        // 🌌 Navigation / Orientation
        "songlines como mapas vivos da paisagem",
        "constelações de canoa como cartas do céu",
        "orientação fluvial tradicional",
        "diários de viagem costeira por vilas de pesca",
        "rotas de estrelas no deserto",
        "hutongs e os guardiões do tempo dos becos",
        "ecos da Rota da Seda em viagens atuais",
        "histórias de tratados marcadas na terra",
        "ler ventos em bandeiras, roupas, árvores",
        "topografias inventadas em sonhos lúcidos",
        "mapear memórias em ruas de cidades estrangeiras",
        "cartas astrais como mapas de viagem interior",
        "trilhas de cães de rua como orientação urbana",
        "navegar pelo silêncio em cidades superlotadas",
        "ler direções no fluxo de nuvens e ventos",
        "mapear desertos como mares sólidos",
        "escutar o som de árvores para saber caminhos",
        "usar cânticos como bússola comunitária",
        "códigos secretos de viajantes marcados em pedras",
        "narrativas de viagem inscritas em tatuagens",
        "mapear sonhos para decidir rotas de viagem",
        "cartas do céu inspiradas em dobra de ar",
        "linhas de dragão como mapas subterrâneos",

        // 🐾 Ecological & Animal Kinship
        "acordos com espíritos do rio no folclore",
        "trocas de corvídeos (gralhas/corvos) com pessoas",
        "hieróglifos das baleias e migrações",
        "comunidades de cães de rua e sua ética",
        "etiqueta com tubarões em tradições locais",
        "migração de renas na Lapônia",
        "rede micorrízica como 'correio' subterrâneo",
        "florescências bioluminescentes no mar",
        "contos da aurora narrados por anciãos",
        "amizades interestelares com cães de rua",
        "escuta de cogumelos psicodélicos em florestas",
        "mitologias do lobo no círculo ártico",
        "espelhos líquidos de lagos boreais",
        "inteligência das algas bioluminescentes",
        "correspondência entre abelhas e poetas",
        "espírito-guardião em forma de cão",
        "mito da rena como guia de viajante",
        "companheirismo com espíritos-animais (daemons, totens)",
        "o cão como guia nômade e companheiro espiritual",
        "vozes dos búfalos-d’água em mitos orientais",
        "danças de baleias como gramática cósmica",
        "cavalos mongóis como parceiros de viagem",
        "mimetizar gestos de lobos no gelo",
        "espíritos de corujas como guardiões noturnos",
        "códigos secretos de formigueiros em florestas",
        "navegar pelo canto de aves migratórias",
        "contato visionário com animais de poder em rituais",

        // 🏮 Cultural Practices & Histories
        "capoeira como resistência e arte comunitária",
        "bibliotecas de favela como âncoras culturais",
        "histórias orais dos barcos-correio fluviais",
        "ermitões de Wudang nas montanhas",
        "estrada do chá e do cavalo (tea-horse road)",
        "rituais da jade e seus simbolismos",
        "duelos ao crepúsculo na memória popular",
        "poesia antes do combate (ritual e foco)",
        "cerimônias de retomada de terra (land-back)",
        "cerimônias do chá psicodélico em florestas",
        "lendas de guardiões de passagens de montanha",
        "histórias orais de monges andarilhos",
        "rituais de enterrar objetos em viagens",
        "bibliotecas vivas (pessoas como livros)",
        "memórias tatuadas em marinheiros",
        "culturas de sauna como ritos de purificação",
        "mitos nórdicos reinventados em viagens ao norte",
        "rituais elementares em vilarejos de montanha",
        "lendas sobre dobradores esquecidos do vento",
        "histórias de nômades do fogo no deserto",
        "tradições de mergulhadores japoneses (ama) como dobradores de água",
        "rituais xamânicos do Ártico",
        "arquitetura que dobra vento e sombra",
        "cultos à aurora como renascimento espiritual",
        "histórias dos faróis como dobradores de luz",
        "narrativas sobre os primeiros mapas mundiais",
        "contos de povos que viajavam apenas pelo som",

        // 📓 Observational / Field Notes
        "notas de campo em cavernas de permafrost",
        "roteiros de expedição para ver a aurora",
        "marginalia em manuscritos antigos",
        "rolos de receitas de cozinhas costeiras",
        "registros de bordo durante marés de tempestade",
        "a voz de um cinto gasto de jiu-jítsu (objeto-narrador)",
        "boletins de auditorias do cofre de sementes",
        "histórias orais dos anos de seca",
        "perfil de um guardião de marégrafo",
        "diários de sonhos como guias de viagem",
        "cartas a um daemon imaginário",
        "croquis de mochileiro em abrigos improvisados",
        "notas sobre diálogos com estranhos em trens noturnos",
        "mapas desenhados na areia antes da maré subir",
        "registros sobre luzes do norte como oráculos",
        "descrições de sinestesias induzidas por cogumelos",
        "crônicas de cães-guia invisíveis em viagens",
        "cadernos de campo sobre movimentos elementares",
        "esboços de aurora como símbolos arquetípicos",
        "mapas de vento rabiscados em diários de viagem",
        "fragmentos de mitos recolhidos em feiras e mercados",
        "ilustrações de constelações inventadas",
        "histórias recolhidas em banhos públicos tradicionais",

        // 🌀 Philosophical / Mind Axis
        "instantes de wu wei na vida diária",
        "despir identidades em peregrinações",
        "fenomenologia na chuva (perceber e descrever)",
        "o Navio de Teseu em decisões pessoais",
        "azar moral e escolhas pequenas",
        "o ritual da paz merecida após conflito",
        "paradoxos como trilhas de pensamento",
        "meditar sobre o vazio em florestas boreais",
        "identidade dissolvida em festivais nômades",
        "eterno retorno como bússola interior",
        "psicodélicos como mestres filosóficos",
        "wu wei aplicado ao nomadismo digital",
        "a sombra junguiana em viagens solitárias",
        "arqueologia da imaginação",
        "a dobra do ar como metáfora para wu wei",
        "psicodélicos como portais para elementos internos",
        "a leveza do ser como dobra do vento",
        "raízes como símbolo de permanência (dobra da terra)",
        "chamas internas como desejo e transformação",
        "a água como memória e esquecimento",
        "meditar em paradoxos como exercício de dobra",
        "daemons como reflexos da alma junguiana",
        "trilhas nômades como metáforas de identidade fluida",
        "unir corpo e mente como dobrar os cinco elementos ocultos",

        // ✨ Bonus: Practice + Place blends
        "princípios de alavanca do jiu-jítsu aplicados a negociações",
        "mapear um bairro caminhando em silêncio",
        "aprender correntes e ventos com pescadores",
        "cadernos de campo sobre pontes e travessias",
        "cultura de feira livre e seus sinais",
        "rituais do chá como cronômetro social",
        "museus ao ar livre em costas rochosas",
        "histórias de faróis e seus guardiões",
        "aprendizados de navegação com estrelas em praias urbanas",
        "aprender linguagens locais através de canções de feira",
        "rituais com cães de rua em portos estrangeiros",
        "poesia improvisada em cafés de esquina",
        "andarilho psicodélico em Lapônia",
        "códigos de movimento lidos em escadas de metrô",
        "banhos de rio como meditação coletiva",
        "navegar cidades pelo cheiro de especiarias",
        "cerimônias do pôr do sol em praias desconhecidas",
        "meditar em fontes termais como dobra da água e fogo",
        "aprendendo idiomas com viajantes ao redor da fogueira",
        "caminhar em silêncio em florestas boreais",
        "dançar sob auroras como ritual de viagem",
        "tecer mapas de vento em praias urbanas",
        "cerimônias de chá psicodélico na Lapônia",
        "conversar com anciãos do norte sobre mitos de gelo",
        "rituais elementares recriados em desertos",
        "diários de viagem em cidades que lembram a Ba Sing Se"
    ]


    // MARK: - UI
    var body: some View {
        Form {
            // OpenAI
            Section("OpenAI") {
                SecureField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            }

            // Mode
            Section("Mode") {
                Picker("Generation Mode", selection: $mode) {
                    ForEach(GenerationMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            if mode == .random {
                Section("Random Topic") {
                    Text(randomTopic ?? "Tap Randomize to pick a topic")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button("Randomize") {
                        randomTopic = interests.randomElement()
                    }
                }
            }

            if mode == .prompt {
                Section("Prompt") {
                    TextEditor(text: $userPrompt)
                        .frame(minHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                        .padding(.vertical, 2)
                        .focused($promptIsFocused)
                    Text("Describe instructions, a theme, or paste a source text.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            // === Options split into three separate cards ===

            // 1) Segmentation card
            Section("Segmentation") {
                Picker("Segment by", selection: $segmentation) {
                    ForEach(Segmentation.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
            }

            // 2) Length card
            Section("Length") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Length")
                        Spacer()
                        Text("\(lengthPreset.label) · ~\(lengthPreset.words) words")
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(lengthPreset.rawValue) },
                            set: { lengthPreset = LengthPreset(rawValue: Int($0.rounded())) ?? .medium }
                        ),
                        in: 0...Double(LengthPreset.allCases.count - 1),
                        step: 1
                    )
                    HStack {
                        Text("Short")
                        Spacer()
                        Text("Very Long")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            // 3) Languages card
            Section("Languages") {
                Picker("Generate in", selection: $genLanguage) {
                    ForEach(supportedLanguages, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)

                Picker("Translate to", selection: $transLanguage) {
                    ForEach(supportedLanguages, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }

            // Action
            Section {
                Button {
                    let req = GeneratorService.Request(
                        apiKey: apiKey,
                        mode: (mode == .prompt ? .prompt : .random),
                        userPrompt: userPrompt,
                        genLanguage: genLanguage,
                        transLanguage: transLanguage,
                        segmentation: (segmentation == .paragraphs ? .paragraphs : .sentences),
                        lengthWords: lengthPreset.words,
                        userChosenTopic: randomTopic,      // 🔽 pass current selection from UI (may be nil)
                        topicPool: interests               // 🔽 pass the full list so service can randomize

                    )
                    generator.start(req, lessonStore: lessonStore)
                } label: {
                    HStack {
                        if generator.isBusy { ProgressView() }
                        Text(generator.isBusy ? "Generating..." : "Generate Lesson")
                    }
                }
                .disabled(apiKey.isEmpty || generator.isBusy || (mode == .prompt && userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

                if !generator.status.isEmpty {
                    Text(generator.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle()) // ensures taps on empty space register
        .onTapGesture {
            if mode == .prompt { promptIsFocused = false }
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Generator")
        .listStyle(.insetGrouped)
    }
}
