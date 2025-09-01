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
        .background(
            ZStack {
                LinearGradient(
                    colors: [Color.blue, Color.purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(Capsule())

                // soft gloss
                LinearGradient(
                    colors: [Color.white.opacity(0.35), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .clipShape(Capsule())
                .blendMode(.screen)
            }
        )
        .overlay(
            Capsule().stroke(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.purple.opacity(glow ? 0.35 : 0.18), radius: glow ? 10 : 6, x: 0, y: glow ? 6 : 3)
        .contentShape(Rectangle())
        .accessibilityLabel(title)
    }
}
