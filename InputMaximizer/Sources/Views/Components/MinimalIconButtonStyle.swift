//
//  MinimalIconButtonStyle.swift
//  InputMaximizer
//
//  Created by Robin Geske on 18.08.25.
//

import SwiftUI
import UIKit
import AVFoundation

// MARK: - Minimal Icon Button Style
struct MinimalIconButtonStyle: ButtonStyle {
    var size: CGFloat = 70
    var color: Color = .accentColor
    var cornerRadius: CGFloat = 14   // 👈 add this
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(color)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 6)
            .animation(.spring(response: 0.25, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }
}
