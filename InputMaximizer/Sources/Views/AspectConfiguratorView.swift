//
//  AspectConfiguratorView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 03.09.25.
//

import SwiftUI

struct AspectConfiguratorView: View {
    @Binding var styleTable: AspectTable
    @Binding var interestRow: AspectRow
    @Environment(\.dismiss) private var dismiss

    @State private var showResetConfirm = false
    @State private var showBulkImport = false

    var body: some View {
        NavigationView {
            List {
                // ===== Style Table =====
                Section {
                    ForEach($styleTable.rows) { $row in
                        AspectRowEditor(row: $row)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                            .cardBackground()
                            .padding(.vertical, 4)
                    }
                    .onDelete { styleTable.rows.remove(atOffsets: $0) }

                    HStack(spacing: 12) {
                        Button {
                            styleTable.rows.append(AspectRow(title: "New Row", options: []))
                        } label: {
                            Label("Add Row", systemImage: "plus")
                        }

                        Spacer()

                        Menu {
                            Button("Enable All") { styleTable.enableAll() }
                            Button("Disable All", role: .destructive) { styleTable.disableAll() }
                        } label: {
                            Label("Bulk Actions", systemImage: "line.3.horizontal.decrease.circle")
                        }

                        Text("\(enabledCount(in: styleTable)) enabled")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                } header: {
                    Text(styleTable.title)
                }

                // ===== Interests =====
                Section {
                    AspectRowEditor(row: $interestRow)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .cardBackground()
                        .padding(.vertical, 4)

                    HStack(spacing: 12) {
                        Menu {
                            Button("Enable All") {
                                interestRow.isActive = true
                                interestRow.options = interestRow.options.map { var o = $0; o.enabled = true; return o }
                            }
                            Button("Disable All", role: .destructive) {
                                interestRow.isActive = false
                                interestRow.options = interestRow.options.map { var o = $0; o.enabled = false; return o }
                            }
                        } label: {
                            Label("Bulk Actions", systemImage: "line.3.horizontal.decrease.circle")
                        }

                        Button {
                            showBulkImport = true
                        } label: {
                            Label("Bulk Import", systemImage: "square.and.arrow.down.on.square")
                        }

                        Spacer()

                        Text("\(interestRow.options.filter { $0.enabled }.count) enabled")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(interestRow.title)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Configure Aspects")
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Reset to Defaults", role: .destructive) {
                            showResetConfirm = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .confirmationDialog(
                        "Reset to defaults?",
                        isPresented: $showResetConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Reset All", role: .destructive) {
                            styleTable = .defaults()
                            interestRow = AspectTable.defaultInterestsRow()
                        }
                        Button("Cancel", role: .cancel) { }
                    }
                }
            }
            .sheet(isPresented: $showBulkImport) {
                InterestBulkImportView(interestRow: $interestRow)
            }
        }
    }

    private func enabledCount(in table: AspectTable) -> Int {
        table.rows.reduce(0) { $0 + $1.options.filter { $0.enabled }.count }
    }
}

struct AspectRowEditor: View {
    @Binding var row: AspectRow
    @State private var newOptionText: String = ""

    // adaptive wrap with nice minimum width
    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 240), spacing: 8, alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Header
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.title)
                    .font(.headline)
                Spacer()
                Toggle(isOn: $row.isActive) {
                    Text("Include")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                .labelsHidden()
            }

            // Add field
            HStack(spacing: 8) {
                HStack {
                    TextField("Add option…", text: $newOptionText)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .padding(.vertical, 8)
                    if !newOptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            addOption()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .imageScale(.large)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add option")
                    }
                }
                .padding(.horizontal, 12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
                .opacity(row.isActive ? 1 : 0.5)

                if !row.options.isEmpty {
                    Text("\(row.options.filter { $0.enabled }.count)/\(row.options.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(.tertiarySystemBackground))
                        )
                }
            }
            .disabled(!row.isActive)

            // Chips grid
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(row.options.indices, id: \.self) { idx in
                    let opt = row.options[idx]
                    Chip(
                        text: opt.label,
                        isOn: Binding(
                            get: { row.options[idx].enabled },
                            set: { row.options[idx].enabled = $0 }
                        ),
                        isEnabled: row.isActive,
                        onDelete: { row.options.remove(at: idx) }
                    )
                }
            }
            .padding(.top, 2)
        }
        .padding(12)
    }

    private func addOption() {
        let trimmed = newOptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        row.options.append(AspectOption(label: trimmed))
        newOptionText = ""
    }
}

// MARK: - Chip

private struct Chip: View {
    let text: String
    @Binding var isOn: Bool
    var isEnabled: Bool = true
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.subheadline)
                .lineLimit(2)
                .minimumScaleFactor(0.9)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.small)
                    .opacity(0.9)
                    .accessibilityLabel("Delete \(text)")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isOn ? Color.selectionAccent : Color.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isOn ? Color.accentColor.opacity(0.6) : Color.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(radius: isOn ? 0.5 : 0)
        .opacity(isEnabled ? 1 : 0.35)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isEnabled else { return }
            isOn.toggle()
        }
        .contextMenu {
            Text(text)
            Button(isOn ? "Disable" : "Enable") { isOn.toggle() }
            Button("Copy") {
                #if canImport(UIKit)
                UIPasteboard.general.string = text
                #endif
            }
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityAddTraits(.isButton)
    }
}

