//
//  DeviceID.swift
//  InputMaximizer
//
//  Created by Robin Geske on 08.09.25.
//

import Foundation
import Security

enum DeviceID {
    static var current: String = {
        let service = "io.robinfederico.InputMaximizer.deviceid"
        let account = "device"
        if let existing = Keychain.load(service: service, account: account),
           let s = String(data: existing, encoding: .utf8),
           !s.isEmpty {
            return s
        }
        let id = UUID().uuidString
        _ = Keychain.save(service: service, account: account, data: Data(id.utf8))
        return id
    }()
}

private enum Keychain {
    static func load(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func save(service: String, account: String, data: Data) -> Bool {
        // Try update first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }
}
