//
//  BuyCreditsView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 07.09.25.
//

import SwiftUI
import StoreKit

struct BuyCreditsView: View {
    @EnvironmentObject var purchases: PurchaseManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Need more credits?").font(.title2).bold()
                Text("Credits are used each time you generate a lesson.")
                    .foregroundStyle(.secondary)
                Text("Balance: \(purchases.creditBalance)")
                    .font(.headline)
                    .padding(.top, 4)

                if purchases.isLoading {
                    ProgressView("Loading…")
                } else if purchases.creditProducts.isEmpty {
                    Text("No credit packs available.").foregroundStyle(.secondary)
                    if let err = purchases.lastError {
                        Text(err).font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 12) {
                        ForEach(purchases.creditProducts, id: \.id) { product in
                            Button {
                                Task { await purchases.buyCredits(product) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(product.displayName).bold()
                                        Text("\(purchases.credits(for: product)) credits")
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(product.displayPrice).font(.headline)
                                }
                                .padding()
                                .background(.thinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                        }
                    }
                    .padding(.top, 8)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Buy Credits")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                // Only refresh if we don't have products yet
                if purchases.creditProducts.isEmpty {
                    await purchases.refresh()
                }
            }

        }
    }
}
