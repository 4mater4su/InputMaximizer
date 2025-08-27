//
//  GeneratorView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 27.08.25.
//

import SwiftUI

struct GeneratorView: View {
    @State private var apiKey: String = ""         // store/retrieve from Keychain in real use
    @State private var lessonID: String = "Lesson001"
    @State private var title: String = "Lesson 1"
    @State private var sentencesPerSegment = 1
    @State private var isBusy = false
    @State private var status = ""

    var body: some View {
        Form {
            Section("OpenAI") {
                SecureField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            }
            Section("Lesson") {
                TextField("Lesson ID (folder)", text: $lessonID)
                TextField("Title", text: $title)
                Stepper("Sentences per segment: \(sentencesPerSegment)", value: $sentencesPerSegment, in: 1...3)
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
                .disabled(apiKey.isEmpty || isBusy)
                if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Generator")
    }

    struct Seg: Codable { let id:Int; let pt_text:String; let en_text:String; let pt_file:String; let en_file:String }
    struct LessonEntry: Codable, Identifiable, Hashable { let id:String; let title:String; let folderName:String }

    func save(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func generateTextPT() async throws -> String {
        // Equivalent to your Python prompt; keep it short for demo.
        let prompt = """
        Escreva um texto curto em Português do Brasil, claro e factual, ~150–200 palavras, sobre capoeira ao amanhecer. Frases curtas. Inclua 1 detalhe numérico.
        """
        let body: [String:Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role":"system","content":"Seja claro e concreto."],
                ["role":"user","content": prompt]
            ],
            "temperature": 0.7
        ]
        return try await chat(body: body)
    }

    func translateToEN(_ pt:String) async throws -> String {
        let body: [String:Any] = [
            "model":"gpt-5-nano",
            "messages":[["role":"user","content":"Translate to natural English:\n\n\(pt)"]],
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
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func generate() async {
        isBusy = true; status = "Generating PT text…"
        do {
            // 1) text
            let pt = try await generateTextPT()
            status = "Translating to EN…"
            let en = try await translateToEN(pt)

            // 2) segment
            func split(_ txt:String) -> [String] {
                txt.split(whereSeparator: { ".!?".contains($0) })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) + "." }
                    .filter{ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
            let sPT = split(pt)
            let sEN = split(en)
            let count = min(sPT.count, sEN.count)
            let ptSegs = Array(sPT.prefix(count))
            let enSegs = Array(sEN.prefix(count))

            // 3) write files in Documents/Lessons/<lessonID>
            let base = FileManager.docsLessonsDir.appendingPathComponent(lessonID, isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

            var rows: [Seg] = []
            for i in 0..<count {
                status = "TTS \(i+1)/\(count) PT…"
                let ptFile = "pt_\(lessonID)_\(i+1).mp3"
                _ = try await tts(ptSegs[i], filename: ptFile, folder: base)

                status = "TTS \(i+1)/\(count) EN…"
                let enFile = "en_\(lessonID)_\(i+1).mp3"
                _ = try await tts(enSegs[i], filename: enFile, folder: base)

                rows.append(.init(id: i+1, pt_text: ptSegs[i], en_text: enSegs[i], pt_file: ptFile, en_file: enFile))
            }

            // 4) segments_<lesson>.json
            let segJSON = base.appendingPathComponent("segments_\(lessonID).json")
            let segData = try JSONEncoder().encode(rows)
            try save(segData, to: segJSON)

            // 5) update lessons.json in Documents
            struct Manifest: Codable { var id:String; var title:String; var folderName:String }
            let manifestURL = FileManager.docsLessonsDir.appendingPathComponent("lessons.json")
            var list: [Manifest] = []
            if let d = try? Data(contentsOf: manifestURL) {
                list = (try? JSONDecoder().decode([Manifest].self, from: d)) ?? []
                list.removeAll{ $0.id == lessonID }
            }
            list.append(.init(id: lessonID, title: title, folderName: lessonID))
            let out = try JSONEncoder().encode(list)
            try save(out, to: manifestURL)

            status = "Done. Open the lesson list and pull to refresh."
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
        isBusy = false
    }
}
