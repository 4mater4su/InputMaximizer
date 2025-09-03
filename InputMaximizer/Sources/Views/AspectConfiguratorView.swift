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

    var body: some View {
        NavigationView {
            Form {
                Section(styleTable.title) {
                    ForEach($styleTable.rows) { $row in
                        AspectRowEditor(row: $row)
                    }
                    HStack {
                        Menu("Bulk Actions") {
                            Button("Enable All") { styleTable.enableAll() }
                            Button("Disable All", role: .destructive) { styleTable.disableAll() }
                        }
                        Spacer()
                        Text("\(enabledCount(in: styleTable)) enabled")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(interestRow.title) {
                    AspectRowEditor(row: $interestRow)

                    HStack {
                        Menu("Bulk Actions") {
                            Button("Enable All") {
                                interestRow.isActive = true
                                interestRow.options = interestRow.options.map { var o = $0; o.enabled = true; return o }
                            }
                            Button("Disable All", role: .destructive) {
                                interestRow.isActive = false
                                interestRow.options = interestRow.options.map { var o = $0; o.enabled = false; return o }
                            }
                        }
                        Spacer()
                        Text("\(interestRow.options.filter { $0.enabled }.count) enabled")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

            }
            .navigationTitle("Configure Aspects")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func enabledCount(in table: AspectTable) -> Int {
        table.rows.reduce(0) { $0 + $1.options.filter { $0.enabled }.count }
    }
}

struct AspectRowEditor: View {
    @Binding var row: AspectRow
    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(row.title).font(.headline)
                Spacer()
                Toggle("Include", isOn: $row.isActive)
                    .labelsHidden()
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(row.options.indices, id: \.self) { idx in
                    let enabled = row.options[idx].enabled
                    Button {
                        row.options[idx].enabled.toggle()
                    } label: {
                        Text(row.options[idx].label)
                            .lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(enabled ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(enabled ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1)
                            )
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .disabled(!row.isActive)
                    .opacity(row.isActive ? 1.0 : 0.35)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}


