//
//  ToastBanner.swift
//  InputMaximizer
//
//  Created by Robin Geske on 01.09.25.
//

import SwiftUI

struct ToastBanner: View {
    let message: String
    let isSuccess: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: isSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .imageScale(.large)
                Text(message)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background((isSuccess ? Color.green : Color.red).opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityAddTraits(.isButton)
    }
}
