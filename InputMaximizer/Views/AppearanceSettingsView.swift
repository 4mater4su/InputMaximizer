//
//  AppearanceSettingsView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 01.09.25.
//

import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var purchases: PurchaseManager
    @AppStorage("appearancePreference") private var appearanceRaw: String = AppearancePreference.system.rawValue
    
    @State private var showBuyCredits = false
    
    @State private var serverBalance: Int = 0
    @State private var serverError: String?
    
    @State private var redeemCode: String = ""
    @State private var redeemStatus: String?
    
    private func refreshServerBalance() async {
        do {
            serverBalance = try await GeneratorService.fetchServerBalance()
            serverError = nil
        } catch {
            serverError = error.localizedDescription
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("App Appearance", selection: $appearanceRaw) {
                    ForEach(AppearancePreference.allCases) { pref in
                        Text(pref.title).tag(pref.rawValue)
                    }
                }
                .pickerStyle(.inline)
                
                Section("Billing & Credits") {
                    HStack {
                        Text("Device ID")
                        Spacer()
                        Text(DeviceID.current)
                            .textSelection(.enabled) // lets you copy the ID
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Credits")
                        Spacer()
                        Text("\(serverBalance)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    if let serverError {
                        Text("Server balance error: \(serverError)")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    NavigationLink("Buy Credits…") {
                        BuyCreditsView(presentation: .push)
                            .environmentObject(purchases)
                    }

                    HStack {
                        TextField("Redeem Code", text: $redeemCode)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .textFieldStyle(.roundedBorder)
                        
                        Button("Redeem") {
                            Task {
                                do {
                                    guard !redeemCode.isEmpty else { return }
                                    let url = URL(string: "https://inputmax-proxy.inputmax.workers.dev/credits/review-grant")!
                                    var req = URLRequest(url: url)
                                    req.httpMethod = "POST"
                                    req.addValue(DeviceID.current, forHTTPHeaderField: "X-Device-Id")
                                    req.addValue("application/json", forHTTPHeaderField: "Content-Type")
                                    req.httpBody = try JSONEncoder().encode(["code": redeemCode])
                                    
                                    let (data, resp) = try await URLSession.shared.data(for: req)
                                    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                                        throw URLError(.badServerResponse)
                                    }
                                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                                    if let ok = json?["ok"] as? Bool, ok == true {
                                        redeemStatus = "Redeemed! +\(json?["granted"] ?? 0) credits"
                                        await refreshServerBalance()
                                    } else {
                                        redeemStatus = "Invalid code"
                                    }
                                } catch {
                                    redeemStatus = "Error: \(error.localizedDescription)"
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    if let status = redeemStatus {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    /*
                    Button("Reload Products") {
                        Task { await purchases.refresh() }
                    }
                     */
                }

            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Appearance")
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await refreshServerBalance() }
        .onReceive(NotificationCenter.default.publisher(for: .didPurchaseCredits)) { _ in
            Task { await refreshServerBalance() }
        }
    }
}

