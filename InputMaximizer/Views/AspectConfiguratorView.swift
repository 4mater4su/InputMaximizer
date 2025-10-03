//
//  AspectConfiguratorView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 03.09.25.
//

import SwiftUI

// MARK: - AspectConfiguratorView

struct AspectConfiguratorView: View {
    @Binding var styleTable: AspectTable
    @Binding var interestRow: AspectRow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.editMode) private var editMode

    @State private var showResetStyleConfirm = false
    @State private var showResetInterestsConfirm = false
    @State private var showBulkImport = false

    // New row prompt
    @State private var showNewRowPrompt = false
    @State private var newRowTitle = ""

    var body: some View {
        NavigationView {
            List {
                // ===== Style Table =====
                Section {
                    // Iterate by VALUE, derive binding by ID to avoid stale indices.
                    ForEach(styleTable.rows) { row in
                        AspectRowEditor(row: bindingForRow(row))
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                            .cardBackground()
                            .padding(.vertical, 4)
                            // Safe swipe delete: delete by ID
                            .swipeActions {
                                Button(role: .destructive) {
                                    deleteRow(withID: row.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    // Edit-mode multi-delete, implemented via IDs (not direct indices)
                    .onDelete(perform: deleteRows)

                    HStack(spacing: 12) {
                        Button {
                            showNewRowPrompt = true
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
                                interestRow.options = interestRow.options.map {
                                    var o = $0; o.enabled = true; return o
                                }
                            }
                            Button("Disable All", role: .destructive) {
                                interestRow.isActive = false
                                interestRow.options = interestRow.options.map {
                                    var o = $0; o.enabled = false; return o
                                }
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
                        Button("Reset Style Aspects…", role: .destructive) {
                            showResetStyleConfirm = true
                        }
                        Button("Reset Interests…", role: .destructive) {
                            showResetInterestsConfirm = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showBulkImport) {
                InterestBulkImportView(interestRow: $interestRow)
            }

            // Separate confirmations (style vs interests)
            .confirmationDialog(
                "Reset style aspects to defaults?",
                isPresented: $showResetStyleConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset Style Aspects", role: .destructive) {
                    styleTable = .defaults()
                }
                Button("Cancel", role: .cancel) { }
            }

            .confirmationDialog(
                "Reset interests to defaults?",
                isPresented: $showResetInterestsConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset Interests", role: .destructive) {
                    interestRow = AspectTable.defaultInterestsRow()
                }
                Button("Cancel", role: .cancel) { }
            }

            // Name-on-add (iOS 17+). If you support iOS 16-, replace with a small sheet.
            .alert("New Row Name", isPresented: $showNewRowPrompt) {
                TextField("e.g. Tone, Format, Persona", text: $newRowTitle)
                Button("Add") {
                    let title = newRowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    styleTable.rows.append(AspectRow(title: title.isEmpty ? "New Row" : title, options: []))
                    newRowTitle = ""
                }
                Button("Cancel", role: .cancel) {
                    newRowTitle = ""
                }
            } message: {
                Text("Enter a name for the new style row.")
            }
        }
    }

    // MARK: Helpers

    /// Create a binding for a row by stable ID to avoid stale indices after deletes.
    private func bindingForRow(_ row: AspectRow) -> Binding<AspectRow> {
        Binding<AspectRow>(
            get: {
                styleTable.rows.first(where: { $0.id == row.id }) ?? row
            },
            set: { newValue in
                if let idx = styleTable.rows.firstIndex(where: { $0.id == row.id }) {
                    styleTable.rows[idx] = newValue
                }
            }
        )
    }

    private func enabledCount(in table: AspectTable) -> Int {
        table.rows.reduce(0) { $0 + $1.options.filter { $0.enabled }.count }
    }

    /// Edit-mode multi-delete by IDs (robust to list mutations).
    private func deleteRows(at offsets: IndexSet) {
        let ids = offsets.compactMap { index in
            styleTable.rows.indices.contains(index) ? styleTable.rows[index].id : nil
        }
        guard !ids.isEmpty else { return }
        styleTable.rows.removeAll { ids.contains($0.id) }
    }

    /// Swipe-to-delete by ID (no captured index).
    private func deleteRow(withID id: AspectRow.ID) {
        if let idx = styleTable.rows.firstIndex(where: { $0.id == id }) {
            styleTable.rows.remove(at: idx)
        }
    }
}

// MARK: - AspectRowEditor

struct AspectRowEditor: View {
    @Binding var row: AspectRow
    @State private var newOptionText: String = ""
    @Environment(\.editMode) private var editMode

    // Confirm delete for options
    @State private var pendingDeleteOptionID: AspectOption.ID?

    // adaptive wrap with nice minimum width
    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 240), spacing: 8, alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Header
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if editMode?.wrappedValue.isEditing == true {
                    TextField("Row name", text: $row.title)
                        .textFieldStyle(.roundedBorder)
                        .font(.headline)
                } else {
                    Text(row.title)
                        .font(.headline)
                }

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

            // Chips grid — iterate by ID (no indices).
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(row.options) { option in
                    let isOnBinding = Binding<Bool>(
                        get: { bindingForOption(option).wrappedValue.enabled },
                        set: { newValue in
                            var updated = bindingForOption(option).wrappedValue
                            updated.enabled = newValue
                            bindingForOption(option).wrappedValue = updated
                        }
                    )

                    Chip(
                        text: option.label,
                        isOn: isOnBinding,
                        isEnabled: row.isActive,
                        onDelete: {
                            // Ask for confirmation instead of deleting right away
                            pendingDeleteOptionID = option.id
                        }
                    )
                }
            }
            .padding(.top, 2)
        }
        .padding(12)
        // Confirm delete option dialog
        .confirmationDialog(
            "Delete this option?",
            isPresented: Binding(
                get: { pendingDeleteOptionID != nil },
                set: { newValue in if !newValue { pendingDeleteOptionID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteOptionID,
                   let idx = row.options.firstIndex(where: { $0.id == id }) {
                    row.options.remove(at: idx)
                }
                pendingDeleteOptionID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteOptionID = nil
            }
        }
    }

    private func addOption() {
        let trimmed = newOptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        row.options.append(AspectOption(label: trimmed))
        newOptionText = ""
    }

    /// Binding for an option by stable ID.
    private func bindingForOption(_ option: AspectOption) -> Binding<AspectOption> {
        Binding<AspectOption>(
            get: {
                row.options.first(where: { $0.id == option.id }) ?? option
            },
            set: { newValue in
                if let idx = row.options.firstIndex(where: { $0.id == option.id }) {
                    row.options[idx] = newValue
                }
            }
        )
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

