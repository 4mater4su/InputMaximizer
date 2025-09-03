//
//  MatrixConfiguratorView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 03.09.25.
//

import SwiftUI

struct MatrixConfiguratorView: View {
    @Binding var styleMatrix: SelectableMatrix
    @Binding var interestMatrix: SelectableMatrix
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                MatrixEditor(title: styleMatrix.title, matrix: $styleMatrix)
                MatrixEditor(title: interestMatrix.title, matrix: $interestMatrix)
            }
            .navigationTitle("Configure Matrices")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct MatrixEditor: View {
    let title: String
    @Binding var matrix: SelectableMatrix

    var body: some View {
        Section(title) {
            HStack {
                Button("Enable All") { matrix.enableAll() }
                Button("Disable All") { matrix.disableAll() }
                Spacer()
                Text("\(matrix.enabled.count) selected").font(.footnote).foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Rows ↓ / Cols →").font(.footnote)
                            .frame(width: 140, alignment: .leading).foregroundStyle(.secondary)
                        ForEach(matrix.cols.indices, id: \.self) { c in
                            Text(matrix.cols[c]).font(.footnote).lineLimit(2)
                                .frame(width: 140, alignment: .leading)
                        }
                    }
                    ForEach(matrix.rows.indices, id: \.self) { r in
                        HStack(alignment: .top) {
                            Text(matrix.rows[r]).font(.footnote)
                                .frame(width: 140, alignment: .leading).foregroundStyle(.secondary)
                            ForEach(matrix.cols.indices, id: \.self) { c in
                                let cell = MatrixCell(r: r, c: c)
                                let isOn = matrix.enabled.contains(cell)
                                Button {
                                    if isOn { matrix.enabled.remove(cell) } else { matrix.enabled.insert(cell) }
                                } label: {
                                    HStack {
                                        Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                        Text(" ").accessibilityHidden(true)
                                    }
                                    .frame(width: 140, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(matrix.rows[r]) × \(matrix.cols[c])")
                                .accessibilityValue(isOn ? "Enabled" : "Disabled")
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}
