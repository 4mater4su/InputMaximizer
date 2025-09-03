//
//  InterestBulkImport.swift
//  InputMaximizer
//
//  Created by Robin Geske on 03.09.25.
//

// MARK: - Bulk import sheet for Interests

import SwiftUI

struct InterestBulkImportView: View {
    @Binding var interestRow: AspectRow
    @Environment(\.dismiss) private var dismiss

    @State private var pastedText = ""
    @State private var replaceExisting = false
    @State private var dedupe = true

    private var parsed: [AspectOption] {
        AspectRow.options(fromBulkText: pastedText)
    }

    private var mergedPreview: [AspectOption] {
        var existing = replaceExisting ? [] : interestRow.options
        let incoming = dedupe
            ? parsed.reduce(into: [String:AspectOption]()) { dict, opt in
                let key = opt.label.lowercased()
                dict[key] = dict[key] ?? opt
            }.map(\.value)
            : parsed

        if replaceExisting {
            return incoming
        } else {
            let set = Set(existing.map { $0.label.lowercased() })
            return existing + incoming.filter { !set.contains($0.label.lowercased()) }
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Paste list") {
                    TextEditor(text: $pastedText)
                        .frame(minHeight: 180)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15)))
                        .font(.callout.monospaced())

                    HStack {
                        Button {
                            UIPasteboard.general.string = InterestBulkImportView.template
                        } label: {
                            Label("Copy Template", systemImage: "doc.on.doc")
                        }
                        Spacer()
                        Button {
                            pastedText = InterestBulkImportView.example
                        } label: {
                            Label("Paste Example", systemImage: "text.badge.plus")
                        }
                    }
                }

                Section("Options") {
                    Toggle("Replace existing", isOn: $replaceExisting)
                    Toggle("Deduplicate by label", isOn: $dedupe)
                }

                Section("Preview") {
                    let parsedCount = parsed.count
                    let finalCount = mergedPreview.count
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Parsed: \(parsedCount) • After merge: \(finalCount)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if parsedCount == 0 {
                            Text("No items detected. Make sure your list follows the template.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            // show the first 12 as a glance
                            ForEach(mergedPreview.prefix(12), id: \.id) { opt in
                                HStack {
                                    Text(opt.label)
                                    Spacer()
                                    Image(systemName: opt.enabled ? "checkmark.circle" : "circle")
                                        .foregroundStyle(opt.enabled ? .green : .secondary)
                                }
                            }
                            if finalCount > 12 {
                                Text("…and \(finalCount - 12) more")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Bulk Import Interests")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        interestRow.options = mergedPreview
                        if interestRow.options.isEmpty == false {
                            interestRow.isActive = true
                        }
                        dismiss()
                    }
                    .disabled(parsed.isEmpty)
                }
            }
        }
    }

    // The official scheme v1 template users can copy.
    static let template: String =
    """
    # Interests Import — Scheme v1
    # One per line. Start with '-' or '*'.
    # Optional attributes after a '|', e.g. enabled=false
    - Northern lights
    - Tea rituals | enabled=true
    - Living maps | enabled=false
    """

    // A short example they can paste to see it working.
    static let example: String =
    """
    - Morning capoeira
    - Everyday balance
    - Meditative parkour
    - Whale songs | enabled=false
    - Ancient libraries
    """
}
