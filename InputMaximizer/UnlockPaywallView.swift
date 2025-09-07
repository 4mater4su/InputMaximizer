//
//  UnlockPaywallView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 07.09.25.
//

import SwiftUI
import StoreKit

struct UnlockPaywallView: View {
    @EnvironmentObject var purchases: PurchaseManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 56))
                Text("Unlock Generator").font(.title).bold()
                Text("One-time purchase. Includes \(purchases.initialUnlockCredits) starter credits.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                if purchases.isLoading {
                    ProgressView("Loading…")
                } else if let p = purchases.unlockProduct {
                    Button {
                        Task { await purchases.buyUnlock() }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(p.displayName).bold()
                                Text(p.description).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(p.displayPrice).font(.headline)
                        }
                        .padding()
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                } else {
                    Text("Product unavailable.").foregroundStyle(.secondary)
                    if let err = purchases.lastError {
                        Text(err).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Button("Restore Purchase") {
                    Task { await purchases.restore() }
                }
                .font(.footnote)

                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle("Upgrade")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onChange(of: purchases.hasProUnlock) { if $0 { dismiss() } }
        }
    }
}
