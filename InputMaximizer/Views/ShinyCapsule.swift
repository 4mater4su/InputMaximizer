//
//  ShinyCapsule.swift
//  InputMaximizer
//
//  Created by Robin Geske on 01.09.25.
//

import SwiftUI

struct ShinyCapsule: View {
    let title: String
    let systemImage: String
    var glow: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .background(LinearGradient.callToAction.clipShape(Capsule()))
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: Color.purple.opacity(glow ? 0.28 : 0.16),
                radius: glow ? 10 : 6,
                x: 0, y: glow ? 6 : 3)
        .contentShape(Rectangle())
        .accessibilityLabel(title)
    }
}

