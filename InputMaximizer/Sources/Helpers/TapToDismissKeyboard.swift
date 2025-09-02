//
//  TapToDismissKeyboard.swift
//  InputMaximizer
//
//  Created by Robin Geske on 02.09.25.
//

import SwiftUI

struct TapToDismissKeyboard: UIViewRepresentable {
    let onTap: () -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        let gr = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        gr.cancelsTouchesInView = false // <- key: don't block buttons
        v.addGestureRecognizer(gr)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject {
        let onTap: () -> Void
        init(onTap: @escaping () -> Void) { self.onTap = onTap }
        @objc func handleTap() { onTap() }
    }
}
