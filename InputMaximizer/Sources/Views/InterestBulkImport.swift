//
//  InterestBulkImport.swift
//  InputMaximizer
//
//  Created by Robin Geske on 03.09.25.
//

import SwiftUI
import Foundation

// MARK: - Bulk import sheet for Interests

struct InterestBulkImportView: View {
    @Binding var interestRow: AspectRow
    @Environment(\.dismiss) private var dismiss

    @State private var pastedText = ""
    @State private var replaceExisting = false
    @State private var dedupe = true

    private var parsed: [AspectOption] {
        AspectRow.options(fromBulkText: pastedText)   // ← uses the extension below
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
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Bulk Import Interests")
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
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

// MARK: - Bulk import parsing (AspectRow extension)

extension AspectRow {
    /// Parses a bulk list of options from text.
    /// Official Scheme v1 (recommended):
    ///   - Lines beginning with "-" or "*" followed by the label.
    ///   - Optional attributes after a "|" pipe, e.g.:  "- Northern lights | enabled=false"
    ///
    /// Also accepted (friendly extras):
    ///   • Plain lines (one label per line)
    ///   • JSON array of strings: ["A","B","C"]
    ///   • CSV/TSV first column used as label (header ignored)
    static func options(fromBulkText raw: String) -> [AspectOption] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        // 1) Try JSON array of strings
        if let data = text.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            let labels = arr.compactMap { $0 as? String }
            if !labels.isEmpty {
                return labels
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { AspectOption(label: $0, enabled: true) }
            }
        }

        // 2) Try CSV/TSV (take first column, skip header if it looks like one)
        if text.contains(",") || text.contains("\t") {
            let lines = text.components(separatedBy: .newlines)
            var out: [AspectOption] = []
            for (i, line) in lines.enumerated() {
                let parts = line.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "\t" })
                guard let first = parts.first else { continue }
                var label = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { continue }
                // skip header-ish first cell
                if i == 0, label.lowercased().contains("label") { continue }
                out.append(.init(label: label))
            }
            if !out.isEmpty { return out }
        }

        // 3) Official Scheme v1 + plain-lines fallback
        var results: [AspectOption] = []

        text.components(separatedBy: .newlines).forEach { line in
            var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return }
            if s.hasPrefix("#") { return } // comment

            // Strip leading bullet
            if s.hasPrefix("- ") { s.removeFirst(2) }
            else if s.hasPrefix("* ") { s.removeFirst(2) }

            // Split attributes via "|"
            let parts = s.split(separator: "|", maxSplits: 8, omittingEmptySubsequences: true)
                         .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            guard let head = parts.first, !head.isEmpty else { return }
            var enabled = true
            if parts.count > 1 {
                for attr in parts.dropFirst() {
                    // enabled=true/false (case-insensitive)
                    let kv = attr.split(separator: "=", maxSplits: 1)
                                 .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    if kv.count == 2, kv[0].lowercased() == "enabled" {
                        enabled = (kv[1].lowercased() == "true" || kv[1] == "1" || kv[1].lowercased() == "yes")
                    }
                }
            }
            results.append(.init(label: head, enabled: enabled))
        }

        return results
    }
}

