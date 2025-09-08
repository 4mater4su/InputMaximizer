//
//  ProxyClient.swift
//  InputMaximizer
//
//  Created by Robin Geske on 08.09.25.
//

import Foundation

struct ProxyClient {
    let baseURL: URL

    func spendCredits(deviceId: String, amount: Int = 1) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("credits/spend"))
        req.httpMethod = "POST"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["amount": amount])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 402 {
            throw NSError(domain: "Credits", code: 402, userInfo: [NSLocalizedDescriptionKey: "Insufficient credits"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Server error"
            throw NSError(domain: "Proxy", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    func chat(deviceId: String, body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: baseURL.appendingPathComponent("chat"))
        req.httpMethod = "POST"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return json
    }

    func tts(deviceId: String, text: String, language: String, speed: String = "regular") async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent("tts"))
        req.httpMethod = "POST"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "language": language,
            "speed": speed,
            "format": "mp3",
            "voice": "shimmer"
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
