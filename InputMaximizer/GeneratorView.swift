
//
//  GeneratorView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 27.08.25.
//

import SwiftUI

struct GeneratorView: View {
    @EnvironmentObject private var lessonStore: LessonStore
    @Environment(\.dismiss) private var dismiss   // optional, if you want to auto-close the screen
    
    // MARK: - State
    @State private var apiKey: String = ""
         // store/retrieve from Keychain in real use
    @State private var sentencesPerSegment = 1
    @State private var isBusy = false
    @State private var status = ""

    // Auto-filled from model output
    @State private var lessonID: String = "Lesson001"
    @State private var title: String = ""          // filled from generated PT title

    @State private var genLanguage: String = "Português do Brasil"
    @State private var transLanguage: String = "English"
    @State private var wordCount: Int = 180
    
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
            Section("OpenAI") {
                SecureField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            }

            Section("Mode") {
                Picker("Generation Mode", selection: $mode) {
                    ForEach(GenerationMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }

            if mode == .prompt {
                Section("Prompt") {
                    TextEditor(text: $userPrompt)
                        .frame(minHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                        .padding(.vertical, 2)
                    Text("Describe instructions, a theme, or paste a source text.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Options") {
                Stepper("Sentences per segment: \(sentencesPerSegment)", value: $sentencesPerSegment, in: 1...3)

                Stepper("Approx. words: \(wordCount)", value: $wordCount, in: 50...1000, step: 50)

                Picker("Generate in", selection: $genLanguage) {
                    ForEach(supportedLanguages, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)

                Picker("Translate to", selection: $transLanguage) {
                    ForEach(supportedLanguages, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }

            Section {
                Button {
                    Task { await generate() }
                } label: {
                    HStack {
                        if isBusy { ProgressView() }
                        Text(isBusy ? "Generating..." : "Generate Lesson")
                    }
                }
                .disabled(apiKey.isEmpty || isBusy || (mode == .prompt && userPrompt.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty))
                if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Generator")
    }

    // MARK: - Models
    struct Seg: Codable { let id:Int; let pt_text:String; let en_text:String; let pt_file:String; let en_file:String }
    struct LessonEntry: Codable, Identifiable, Hashable { let id:String; let title:String; let folderName:String }

    // MARK: - Utils
    func slugify(_ input: String) -> String {
        // remove diacritics, keep alphanumerics, dash, underscore; replace spaces with underscores
        var s = input.folding(options: .diacriticInsensitive, locale: .current)
        s = s.replacingOccurrences(of: " ", with: "_")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        s = String(s.unicodeScalars.filter { allowed.contains($0) })
        if s.isEmpty { s = "Lesson_" + String(Int(Date().timeIntervalSince1970)) }
        return s
    }

    func save(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - LLM prompts
    func generateText(topic: String, targetLang: String, wordCount: Int) async throws -> String {
        let prompt = """
        Write a short, clear, factual text (~\(wordCount) words) in \(targetLang) about: \(topic).

        Rules:
        1) First line: TITLE only (no quotes).
        2) Blank line.
        3) Body in short sentences.
        4) Include exactly one plausible numeric detail in the body.
        """
        let body: [String:Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role":"system","content":"Be clear, concrete, and factual."],
                ["role":"user","content": prompt]
            ],
            "temperature": 0.7
        ]
        return try await chat(body: body)
    }

    func generateText(fromPrompt promptText: String, targetLang: String, wordCount: Int) async throws -> String {
        let prompt = """
        The user will provide instructions, a theme, or even a source text. Write a short, clear, factual text (~\(wordCount) words) in \(targetLang).

        Rules:
        1) First line: TITLE only (no quotes).
        2) Blank line.
        3) Body in short sentences.
        4) Include exactly one plausible numeric detail in the body.

        User input:
        \(promptText)
        """
        let body: [String:Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role":"system","content":"Follow the user's input. Be clear, concrete, and factual."],
                ["role":"user","content": prompt]
            ],
            "temperature": 0.7
        ]
        return try await chat(body: body)
    }


    func translate(_ text: String, to targetLang: String) async throws -> String {
        let body: [String:Any] = [
            "model":"gpt-5-nano",
            "messages":[
                ["role":"system","content":"Translate naturally and idiomatically."],
                ["role":"user","content":"Translate into \(targetLang):\n\n\(text)"]
            ],
            "temperature": 1.0
        ]
        return try await chat(body: body)
    }

    func chat(body: [String:Any]) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let j = try JSONSerialization.jsonObject(with: data) as! [String:Any]
        let content = (((j["choices"] as? [[String:Any]])?.first?["message"] as? [String:Any])?["content"] as? String) ?? ""
        return content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    func tts(_ text:String, filename:String, folder:URL) async throws -> URL {
        let url = URL(string: "https://api.openai.com/v1/audio/speech")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String:Any] = [
            "model": "gpt-4o-mini-tts",
            "voice": "shimmer",
            "input": text,
            "format": "mp3"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let out = folder.appendingPathComponent(filename)
        try save(data, to: out)
        return out
    }

    func languageSlug(_ name: String) -> String {
        let s = slugify(name).lowercased()
        // keep it short but unique-ish
        return String(s.prefix(6))   // e.g., "portug", "englis", "deutsc"
    }
    
    // MARK: - Generate
    func generate() async {
        isBusy = true
        defer { isBusy = false }

        do {
            // 1) Build text (title + body) depending on mode
            let fullText: String
            switch mode {
            case .random:
                let topic = interests.randomElement() ?? "capoeira rodas ao amanhecer"
                status = "Generating… (Random)\nTopic: \(topic)\nLang: \(genLanguage) • ~\(wordCount) words"
                fullText = try await generateText(topic: topic, targetLang: genLanguage, wordCount: wordCount)
            case .prompt:
                let cleaned = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { status = "Please enter a prompt."; return }
                status = "Generating… (Prompt)\nLang: \(genLanguage) • ~\(wordCount) words"
                fullText = try await generateText(fromPrompt: cleaned, targetLang: genLanguage, wordCount: wordCount)
            }


            // 2) Parse title + body from the model output
            // Parse title + body from the model output
            let lines = fullText.split(separator: "\n", omittingEmptySubsequences: false)
            let generatedTitle = lines.first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "Sem Título"
            let bodyPrimary = lines.dropFirst().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            self.title = generatedTitle
            var folder = slugify(generatedTitle)

            let baseRoot = FileManager.docsLessonsDir
            var base = baseRoot.appendingPathComponent(folder, isDirectory: true)
            if (try? base.checkResourceIsReachable()) == true {
                folder += "_" + String(Int(Date().timeIntervalSince1970))
                base = baseRoot.appendingPathComponent(folder, isDirectory: true)
            }
            self.lessonID = folder

            status = "Translating to \(transLanguage)…\nTítulo: \(generatedTitle)"

            // Avoid translating into the same language
            let secondaryText: String
            if genLanguage.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                == transLanguage.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
                secondaryText = bodyPrimary
            } else {
                secondaryText = try await translate(bodyPrimary, to: transLanguage)
            }

            // 5) Segment: chunk into groups of N sentences
            func sentences(_ txt: String) -> [String] {
                txt.split(whereSeparator: { ".!?".contains($0) })
                    .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { s in
                        if s.hasSuffix(".") || s.hasSuffix("!") || s.hasSuffix("?") { return s }
                        return s + "."
                    }
            }
            func chunk<T>(_ array: [T], size: Int) -> [[T]] {
                guard size > 0 else { return [] }
                return stride(from: 0, to: array.count, by: size).map { i in
                    Array(array[i..<min(i + size, array.count)])
                }
            }

            let sentPrimary = sentences(bodyPrimary)
            let sentSecondary = sentences(secondaryText)

            let segsPrimary: [String] = chunk(sentPrimary, size: sentencesPerSegment).map { $0.joined(separator: " ") }
            let segsSecondary: [String] = chunk(sentSecondary, size: sentencesPerSegment).map { $0.joined(separator: " ") }

            let count = min(segsPrimary.count, segsSecondary.count)
            let ptSegs = Array(segsPrimary.prefix(count))
            let enSegs = Array(segsSecondary.prefix(count))

            status = "Preparing audio… \(count) segments × \(sentencesPerSegment) sentences"

            // 6) Create folder and TTS
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

            var rows: [Seg] = []
            
            let src = languageSlug(genLanguage)
            let dst = languageSlug(transLanguage)

            for i in 0..<count {
                status = "TTS \(i+1)/\(count) \(genLanguage)…"
                let ptFile = "\(src)_\(lessonID)_\(i+1).mp3"
                _ = try await tts(ptSegs[i], filename: ptFile, folder: base)

                status = "TTS \(i+1)/\(count) \(transLanguage)…"
                let enFile = "\(dst)_\(lessonID)_\(i+1).mp3"
                _ = try await tts(enSegs[i], filename: enFile, folder: base)

                rows.append(.init(id: i+1, pt_text: ptSegs[i], en_text: enSegs[i], pt_file: ptFile, en_file: enFile))
            }

            // 7) segments_<lesson>.json
            let segJSON = base.appendingPathComponent("segments_\(lessonID).json")
            let segData = try JSONEncoder().encode(rows)
            try save(segData, to: segJSON)

            // 8) update lessons.json in Documents
            struct Manifest: Codable { var id:String; var title:String; var folderName:String }
            let manifestURL = FileManager.docsLessonsDir.appendingPathComponent("lessons.json")
            var list: [Manifest] = []
            if let d = try? Data(contentsOf: manifestURL) {
                list = (try? JSONDecoder().decode([Manifest].self, from: d)) ?? []
                list.removeAll { $0.id == lessonID }
            }
            list.append(.init(id: lessonID, title: title, folderName: lessonID))
            let out = try JSONEncoder().encode(list)
            try save(out, to: manifestURL)
            
            await MainActor.run {
                lessonStore.load()    // refresh the list without restarting
                // dismiss()          // <- uncomment if you want to auto-close Generator after success
            }

            status = "Done. Open the lesson list and pull to refresh."
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }

}
