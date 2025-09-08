//
//  DeviceID.swift
//  InputMaximizer
//
//  Created by Robin Geske on 08.09.25.
//

import Foundation

enum DeviceID {
    @UserDefaultsBacked(key: "device.id", defaultValue: UUID().uuidString)
    static var current: String
}

@propertyWrapper
struct UserDefaultsBacked<T> {
    let key: String
    let defaultValue: T
    var wrappedValue: T {
        get { (UserDefaults.standard.object(forKey: key) as? T) ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
