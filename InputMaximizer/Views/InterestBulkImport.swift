//
//  InterestBulkImport.swift
//  InputMaximizer
//
//  Created by Robin Geske on 03.09.25
//

import SwiftUI
import Foundation

// MARK: - Bulk import sheet for Interests

struct InterestBulkImportView: View {
    @Binding var interestRow: AspectRow
    @Environment(\.dismiss) private var dismiss

    // Input / options
    @State private var pastedText = ""
    @State private var replaceExisting = false
    @State private var dedupe = true

    // Template peek state
    @State private var showTemplatePeek = false
    @State private var didCopyTemplate = false
    @State private var templatePeekPinned = false

    // Keyboard + Info
    @FocusState private var editorFocused: Bool
    @State private var showInfoCard = false

    // Preview UX
    @State private var showOnlyNew = false
    @State private var previewSearch = ""

    // Parsing
    private var parsed: [AspectOption] {
        AspectRow.options(fromBulkText: pastedText)
    }

    // Deduped incoming (before merge)
    private var incoming: [AspectOption] {
        if !dedupe { return parsed }
        var dict: [String: AspectOption] = [:]
        for opt in parsed {
            let key = opt.label.lowercased()
            if dict[key] == nil { dict[key] = opt }
        }
        return Array(dict.values)
    }

    // Keys considered new against existing
    private var newKeys: Set<String> {
        let existingSet = replaceExisting
            ? Set<String>()
            : Set(interestRow.options.map { $0.label.lowercased() })
        return Set(incoming.map { $0.label.lowercased() }).subtracting(existingSet)
    }

    // Final preview list: existing + new (or just new if replaceExisting), new first
    private var mergedPreview: [AspectOption] {
        let existing = replaceExisting ? [] : interestRow.options
        let base: [AspectOption]
        if replaceExisting {
            base = incoming
        } else {
            let set = Set(existing.map { $0.label.lowercased() })
            base = existing + incoming.filter { !set.contains($0.label.lowercased()) }
        }
        let (newOnes, oldOnes) = base.stablePartition { newKeys.contains($0.label.lowercased()) }
        return newOnes + oldOnes
    }

    // Filtered preview (search + showOnlyNew)
    private var filteredPreview: [AspectOption] {
        let q = previewSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let list = mergedPreview
        let keys = newKeys
        let onlyNew = showOnlyNew

        if q.isEmpty {
            return onlyNew
            ? list.filter { keys.contains($0.label.lowercased()) }
            : list
        } else {
            return list.filter { opt in
                let label = opt.label.lowercased()
                let matches = label.contains(q)
                let passesNew = !onlyNew || keys.contains(label)
                return matches && passesNew
            }
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // === Form (Paste + Options + Summary) ===
                Form {
                    Section("Paste list") {
                        TextEditor(text: $pastedText)
                            .frame(minHeight: 180)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15)))
                            .font(.callout.monospaced())
                            .focused($editorFocused)

                        HStack(spacing: 12) {
                            Button {
                                UIPasteboard.general.string = InterestBulkImportView.template
                                didCopyTemplate = true
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                    showTemplatePeek = true
                                }
                                Task {
                                    try? await Task.sleep(nanoseconds: 4_000_000_000) // ~4s
                                    if !templatePeekPinned {
                                        withAnimation(.easeInOut(duration: 0.25)) { showTemplatePeek = false }
                                    }
                                    try? await Task.sleep(nanoseconds: 600_000_000)
                                    didCopyTemplate = false
                                }
                            } label: {
                                Label(didCopyTemplate ? "Copied" : "Copy Template",
                                      systemImage: didCopyTemplate ? "checkmark.circle.fill" : "doc.on.doc")
                            }
                            .buttonStyle(.plain)

                            Spacer(minLength: 8)

                            Button {
                                pastedText = InterestBulkImportView.example
                            } label: {
                                Label("Paste Example", systemImage: "text.badge.plus")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Section("Options") {
                        Toggle("Replace existing", isOn: $replaceExisting)
                        Toggle("Deduplicate by label", isOn: $dedupe)
                    }

                    Section("Preview Summary") {
                        let parsedCount = parsed.count
                        let finalCount = mergedPreview.count
                        let newCount = newKeys.count

                        PreviewSummaryView(parsedCount: parsedCount,
                                               finalCount: finalCount,
                                               newCount: newCount)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollContentBackground(.hidden)
                .background(Color.appBackground)

                // === Preview Header Controls ===
                PreviewControls(showOnlyNew: $showOnlyNew, searchText: $previewSearch, total: mergedPreview.count, newTotal: newKeys.count)

                // === Sophisticated Preview OUTSIDE the Form ===
                PreviewList(
                    items: filteredPreview,
                    isNew: { newKeys.contains($0.label.lowercased()) }
                )
                .frame(maxWidth: .infinity)
                .background(Color.appBackground)
            }
            .navigationTitle("Bulk Import Interests")
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .toolbar {
                // Cancel
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                // Import
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        var tx = Transaction()
                        tx.disablesAnimations = true
                        withTransaction(tx) {
                            interestRow.options = mergedPreview
                            if !interestRow.options.isEmpty { interestRow.isActive = true }
                            dismiss()
                        }
                    }
                    .disabled(parsed.isEmpty)
                }
                // Info button
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showInfoCard = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .popover(isPresented: $showInfoCard) {
                        BulkImportInfoCard()
                            .padding()
                            .frame(maxWidth: 520)
                    }
                }
                // Keyboard toolbar
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editorFocused = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
            // Tap anywhere to dismiss keyboard without eating button taps
            .simultaneousGesture(TapGesture().onEnded {
                if editorFocused { editorFocused = false }
            })
            // Template peek
            .overlay(alignment: .top) {
                if showTemplatePeek {
                    TemplatePeek(
                        text: Self.template,
                        isPinned: $templatePeekPinned,
                        onClose: {
                            withAnimation(.easeInOut(duration: 0.2)) { showTemplatePeek = false }
                        }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Template & Example

    static let template: String =
    """
    # Interests Import — Scheme v1
    # One per line. Start with '-' or '*'.
    # Optional attributes after a '|', e.g. enabled=false
    - Northern lights
    - Tea rituals | enabled=true
    - Living maps | enabled=false
    """

    static let example: String =
    """
    - Morning capoeira
    - Everyday balance
    - Meditative parkour
    - Whale songs | enabled=false
    - Ancient libraries
    """
}

// MARK: - Preview Controls

private struct PreviewControls: View {
    @Binding var showOnlyNew: Bool
    @Binding var searchText: String
    let total: Int
    let newTotal: Int

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $showOnlyNew) {
                HStack(spacing: 6) {
                    Text("Show only NEW")
                    Text("\(newTotal)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: .accentColor))

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").opacity(0.6)
                TextField("Filter preview…", text: $searchText)
                    .textFieldStyle(.plain)
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.appBackground)
    }
}

// MARK: - Preview (outside Form)

private struct PreviewList: View {
    let items: [AspectOption]
    let isNew: (AspectOption) -> Bool

    var body: some View {
        VStack(spacing: 8) {
            // Fancy header bar with counts
            HStack {
                Text("Preview")
                    .font(.headline)
                Spacer()
                Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            // Plain ScrollView to avoid UICollectionView loops
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items, id: \.label) { opt in
                        PreviewRow(opt: opt, isNew: isNew(opt))
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
                .transaction { $0.animation = nil } // no implicit animations
            }
            .background(Color.appBackground)
        }
        .padding(.top, 8)
    }
}

// MARK: - Count Badge

private struct CountBadge: View {
    let title: String
    let count: Int
    var tinted: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((tinted ? Color.accentColor : Color.secondary).opacity(0.15), in: Capsule())
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Preview Row

private struct PreviewRow: View {
    let opt: AspectOption
    let isNew: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .frame(width: 8, height: 8)
                .foregroundStyle(isNew ? Color.accentColor : Color.secondary.opacity(0.4))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(opt.label)
                        .fontWeight(isNew ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if isNew {
                        Text("NEW")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.tint.opacity(0.18), in: Capsule())
                            .overlay(Capsule().stroke(.tint.opacity(0.35), lineWidth: 0.5))
                            .accessibilityLabel("Newly parsed")
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: opt.enabled ? "checkmark.circle" : "circle")
                    Text(opt.enabled ? "Enabled" : "Disabled")
                }
                .font(.caption)
                .foregroundStyle(opt.enabled ? .green : .secondary)
                .accessibilityLabel(opt.enabled ? "Enabled" : "Disabled")
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isNew ? Color.accentColor.opacity(0.07) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isNew ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}


// MARK: - Preview Summary View

private struct PreviewSummaryView: View {
    let parsedCount: Int
    let finalCount: Int
    let newCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                CountBadge(title: "Parsed", count: parsedCount)
                CountBadge(title: "After merge", count: finalCount)
                CountBadge(title: "NEW", count: newCount, tinted: true)
            }

            HStack(spacing: 12) {
                Label("Enabled", systemImage: "checkmark.circle")
                Label("Disabled", systemImage: "circle")
                HStack(spacing: 6) {
                    Text("NEW")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.tint.opacity(0.18), in: Capsule())
                        .overlay(Capsule().stroke(.tint.opacity(0.35), lineWidth: 0.5))
                    Text("newly parsed")
                }
                .font(.caption)
            }
            .foregroundStyle(.secondary)

            if parsedCount == 0 {
                Text("No items detected. Use the template format or paste a JSON array / CSV first column.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}


// MARK: - Template Peek Overlay

private struct TemplatePeek: View {
    let text: String
    @Binding var isPinned: Bool
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.doc")
                    Text("Template copied")
                        .font(.headline)
                }

                Spacer()

                Button {
                    withAnimation(.snappy) { isPinned.toggle() }
                } label: {
                    Label(isPinned ? "Keep open: On" : "Keep open: Off",
                          systemImage: isPinned ? "pin.fill" : "pin")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.large)
                        .opacity(0.8)
                }
                .buttonStyle(.borderless)
                .padding(.leading, 4)
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Divider().opacity(0.15)

            ScrollView {
                Text(text)
                    .font(.callout.monospaced())
                    .padding()
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
        }
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.secondary.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.top, 8)
        .shadow(radius: 16, y: 8)
        .frame(maxWidth: 560, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(1)
    }
}

// MARK: - Bulk Import Info Card (with AI tip)

private struct BulkImportInfoCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down")
                    .imageScale(.large)
                Text("About Bulk Import")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Paste a list")
                            .font(.subheadline.bold())
                        Text("Add one interest per line. You can also paste a JSON array of strings or CSV/TSV—only the first column is used.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "text.alignleft").font(.caption2)
                }

                Divider()

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use the template")
                            .font(.subheadline.bold())
                        Text("Tap “Copy Template” to see the supported format. Optional attributes like “| enabled=false” are supported.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "doc.on.doc").font(.caption2)
                }

                Divider()

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Options")
                            .font(.subheadline.bold())
                        Text("“Replace existing” discards current interests. “Deduplicate by label” keeps only one per label (case-insensitive).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "slider.horizontal.3").font(.caption2)
                }

                Divider()

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Preview")
                            .font(.subheadline.bold())
                        Text("All items are shown. Newly parsed items are marked “NEW” and placed at the top. The checkmark means the item will be enabled.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "eye").font(.caption2)
                }

                Divider()

                // NEW: AI tip
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pro tip")
                            .font(.subheadline.bold())
                        Text("Copy the template and paste it into an AI chatbot to generate lots of interest ideas in the same format. Then paste the output back here to import instantly.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "sparkles").font(.caption2)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(radius: 8, y: 4)
        )
    }
}

// MARK: - Small utilities

private extension Array {
    /// Stable partition: returns (matching, nonMatching), preserving order.
    func stablePartition(_ isMatching: (Element) -> Bool) -> ([Element], [Element]) {
        var yes: [Element] = []
        var no: [Element] = []
        yes.reserveCapacity(count / 2)
        no.reserveCapacity(count / 2)
        for e in self {
            if isMatching(e) {
                yes.append(e)
            } else {
                no.append(e)
            }
        }
        return (yes, no)
    }
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
                let label = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
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

