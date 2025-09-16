//
//  ProxyClient.swift
//  InputMaximizer
//
//  Created by Robin Geske on 08.09.25.
//

import Foundation

struct ProxyClient {
    let baseURL: URL

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 45     // per-request inactivity timeout
        cfg.timeoutIntervalForResource = 120   // total time per request
        cfg.waitsForConnectivity = true        // handles transient offline cases
        return URLSession(configuration: cfg)
    }()
    
    // MARK: - Credits: spend
    func spendCredits(deviceId: String, amount: Int = 1) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("/credits/spend"))
        req.httpMethod = "POST"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["amount": amount])

        let (data, resp) = try await ProxyClient.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        if http.statusCode == 402 {
            throw NSError(domain: "Credits", code: 402,
                          userInfo: [NSLocalizedDescriptionKey: "Insufficient credits"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Server error"
            throw NSError(domain: "Proxy", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    // MARK: - Credits: legacy redeem (receipt base64) for < iOS 18
    /// Redeem an App Store receipt (base64) → credits on server.
    /// Returns (granted credits, new server balance).
    @discardableResult
    func redeemReceipt(deviceId: String, receiptBase64: String) async throws -> (granted: Int, balance: Int) {
        var req = URLRequest(url: baseURL.appendingPathComponent("/credits/redeem"))
        req.httpMethod = "POST"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["receipt": receiptBase64])

        let (data, resp) = try await ProxyClient.session.data(for: req)
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

    // MARK: - Credits: new redeem (signed JWS) for iOS 18+
    /// Redeem StoreKit 2 signed transaction(s) (JWS) → credits on server.
    /// Returns (granted credits, new server balance).
    @available(iOS 18.0, *)
    @discardableResult
    func redeemSignedTransactions(deviceId: String, signedTransactions: [String]) async throws -> (granted: Int, balance: Int) {
        var req = URLRequest(url: baseURL.appendingPathComponent("/credits/redeem-signed"))
        req.httpMethod = "POST"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["signedTransactions": signedTransactions])

        let (data, resp) = try await ProxyClient.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        if http.statusCode == 409 {
            // already redeemed; still parse to get up-to-date balance (if your server ever returns 409)
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

    // MARK: - Credits: balance
    func balance(deviceId: String) async throws -> Int {
        var req = URLRequest(url: baseURL.appendingPathComponent("/credits/balance"))
        req.httpMethod = "GET"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")

        let (data, resp) = try await ProxyClient.session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return j?["balance"] as? Int ?? 0
    }

    // MARK: - Chat proxy
    // Ensure 402 bubbles up for chat…
    func chat(deviceId: String, body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: baseURL.appendingPathComponent("/chat"))
        req.httpMethod = "POST"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await ProxyClient.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        if http.statusCode == 402 {
            let msg = String(data: data, encoding: .utf8) ?? "Insufficient credits"
            throw NSError(domain: "Credits", code: 402,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Server error"
            throw NSError(domain: "Proxy", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: - TTS proxy
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

        let (data, resp) = try await ProxyClient.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        if http.statusCode == 402 {
            let msg = String(data: data, encoding: .utf8) ?? "Insufficient credits"
            throw NSError(domain: "Credits", code: 402,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Server error"
            throw NSError(domain: "Proxy", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return data
    }
    
}

// MARK: - Job hold APIs (start/commit/cancel)
private struct JobStartResponse: Decodable {
    let ok: Bool
    let jobId: String
    let reserved: Int
    let balance: Int
}
private struct JobOKResponse: Decodable { let ok: Bool; let balance: Int }

extension ProxyClient {
    func jobStart(deviceId: String, amount: Int = 1, ttlSeconds: Int = 1800) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("/jobs/start"))
        req.httpMethod = "POST"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["amount": amount, "ttlSeconds": ttlSeconds])
        let (data, resp) = try await ProxyClient.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 402 {
            let msg = String(data: data, encoding: .utf8) ?? "Insufficient credits"
            throw NSError(domain: "Credits", code: 402, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Server error"
            throw NSError(domain: "Proxy", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let obj = try JSONDecoder().decode(JobStartResponse.self, from: data)
        return obj.jobId
    }

    func jobCommit(deviceId: String, jobId: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("/jobs/commit"))
        req.httpMethod = "POST"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["jobId": jobId])
        let (data, resp) = try await ProxyClient.session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Server error"
            throw NSError(domain: "Proxy", code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        _ = try? JSONDecoder().decode(JobOKResponse.self, from: data)
    }

    func jobCancel(deviceId: String, jobId: String) async {
        var req = URLRequest(url: baseURL.appendingPathComponent("/jobs/cancel"))
        req.httpMethod = "POST"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["jobId": jobId])
        _ = try? await URLSession.shared.data(for: req) // best-effort
    }
}


