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
        var req = URLRequest(url: baseURL.appendingPathComponent("/credits/spend"))
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
    
    func redeemReceipt(deviceId: String, receiptBase64: String) async throws -> (granted: Int, balance: Int) {
        var req = URLRequest(url: baseURL.appendingPathComponent("/credits/redeem"))
        req.httpMethod = "POST"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["receipt": receiptBase64])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        if http.statusCode == 409 {
            // already redeemed; still parse to get up-to-date balance
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let balance = (obj?["balance"] as? Int) ?? 0
            return (granted: 0, balance: balance)
        }

        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Server error"
            throw NSError(domain: "Proxy", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }

        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["granted"] as? Int ?? 0, obj?["balance"] as? Int ?? 0)
    }
    
    // Balance
    func balance(deviceId: String) async throws -> Int {
        var req = URLRequest(url: baseURL.appendingPathComponent("/credits/balance"))
        req.httpMethod = "GET"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return j?["balance"] as? Int ?? 0
    }
    
    /// Redeem an Apple IAP transaction (signed JWS) → credits on server.
    /// Returns (granted credits, new server balance)
    func redeemIAP(deviceId: String, jws: String) async throws -> (granted: Int, balance: Int) {
        var req = URLRequest(url: baseURL.appendingPathComponent("/credits/redeem-iap"))
        req.httpMethod = "POST"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["jws": jws])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        if http.statusCode == 409 {
            // already redeemed; still parse response to get balance
            let obj = try JSONSerialization.jsonObject(with: data) as? [String:Any]
            let balance = (obj?["balance"] as? Int) ?? 0
            return (granted: 0, balance: balance)
        }

        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Server error"
            throw NSError(domain: "Proxy", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String:Any]
        return ((obj?["granted"] as? Int) ?? 0, (obj?["balance"] as? Int) ?? 0)
    }

    // Ensure 402 bubbles up for chat…
    func chat(deviceId: String, body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: baseURL.appendingPathComponent("/chat"))
        req.httpMethod = "POST"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 402 {
            let msg = String(data: data, encoding: .utf8) ?? "Insufficient credits"
            throw NSError(domain: "Credits", code: 402, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Server error"
            throw NSError(domain: "Proxy", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // …and TTS
    func tts(deviceId: String, text: String, language: String, speed: String = "regular") async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent("/tts"))
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
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 402 {
            let msg = String(data: data, encoding: .utf8) ?? "Insufficient credits"
            throw NSError(domain: "Credits", code: 402, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Server error"
            throw NSError(domain: "Proxy", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return data
    }
}
