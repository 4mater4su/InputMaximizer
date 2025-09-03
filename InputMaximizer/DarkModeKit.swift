//
//  DarkModeKit.swift
//  InputMaximizer
//
//  Created by Robin Geske on 04.09.25.
//

import SwiftUI

// MARK: - Color Tokens

extension Color {
    /// App canvas behind scroll views / forms
    static var appBackground: Color {
        Color(UIColor { t in
            t.userInterfaceStyle == .dark
            ? UIColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1)   // deep, not pure black
            : UIColor.systemGroupedBackground
        })
    }

    /// Card surface (buttons, rows, tiles)
    static var surface: Color {
        Color(UIColor { t in
            t.userInterfaceStyle == .dark
            ? UIColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)
            : UIColor.secondarySystemBackground
        })
    }

    /// Slightly more elevated surface
    static var surfaceElev: Color {
        Color(UIColor { t in
            t.userInterfaceStyle == .dark
            ? UIColor(red: 0.15, green: 0.15, blue: 0.17, alpha: 1)
            : UIColor.systemBackground
        })
    }

    /// Subtle 1-pt border that reads well in dark
    static var hairline: Color {
        Color(UIColor { t in
            t.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.separator
        })
    }

    /// Background for current selection highlights
    static var selectionAccent: Color {
        Color(UIColor { t in
            t.userInterfaceStyle == .dark
            ? UIColor.systemBlue.withAlphaComponent(0.20)
            : UIColor.systemBlue.withAlphaComponent(0.10)
        })
    }

    /// Folder tile background
    static var folderTile: Color {
        Color(UIColor { t in
            t.userInterfaceStyle == .dark
            ? UIColor.systemYellow.withAlphaComponent(0.16)
            : UIColor.systemYellow.withAlphaComponent(0.22)
        })
    }
}

// MARK: - Reusable Card Modifier

struct CardBackground: ViewModifier {
    var elevated = false
    func body(content: Content) -> some View {
        content
            .background(elevated ? Color.surfaceElev : Color.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.25),
                    radius: elevated ? 8 : 4,
                    x: 0, y: elevated ? 6 : 2)
    }
}

extension View {
    func cardBackground(elevated: Bool = false) -> some View {
        modifier(CardBackground(elevated: elevated))
    }
}

// MARK: - Gradient used by CTA

extension LinearGradient {
    static var callToAction: LinearGradient {
        LinearGradient(colors: [Color.blue, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

