//
//  VPNControlView.swift
//  iOS-App
//
//  Voorbeeld-UI bovenop VPNManager.
//

import NetworkExtension
import SwiftUI

struct VPNControlView: View {

    @StateObject private var vpn = VPNManager()
    @State private var statistics: TunnelStatistics?

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent("Tunnel", value: vpn.statusDescription)
                    LabeledContent("Profiel geïnstalleerd", value: vpn.isProfileInstalled ? "Ja" : "Nee")
                    LabeledContent("Profiel ingeschakeld", value: vpn.isProfileEnabled ? "Ja" : "Nee")
                }

                Section("Bediening") {
                    if !vpn.isProfileInstalled {
                        Button("Profiel installeren") {
                            // Fouten landen in `vpn.lastError` en worden hieronder getoond.
                            Task { try? await vpn.installProfile() }
                        }
                        .disabled(vpn.isBusy)
                    }

                    Button(vpn.isConnected || vpn.isTransitioning ? "Tunnel uitschakelen" : "Tunnel inschakelen") {
                        Task { try? await vpn.toggle() }
                    }
                    .disabled(vpn.isBusy)

                    if vpn.isProfileInstalled {
                        Button("Profiel verwijderen", role: .destructive) {
                            Task { try? await vpn.removeProfile() }
                        }
                        .disabled(vpn.isBusy)
                    }
                }

                if let statistics {
                    Section("Statistieken") {
                        LabeledContent("Pakketten gelezen", value: "\(statistics.packetsRead)")
                        LabeledContent("Bytes gelezen", value: "\(statistics.bytesRead)")
                        LabeledContent("Echo replies", value: "\(statistics.icmpEchoRepliesSent)")
                        LabeledContent("Pakketten verworpen", value: "\(statistics.packetsDropped)")
                    }
                }

                if let error = vpn.lastError {
                    Section("Fout") {
                        Text(error.localizedDescription)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Loopback Tunnel")
            .task {
                await vpn.refresh()
            }
            .task(id: vpn.status) {
                guard vpn.isConnected else {
                    statistics = nil
                    return
                }
                // Elke seconde de tellers ophalen zolang de tunnel verbonden is.
                while !Task.isCancelled && vpn.isConnected {
                    statistics = try? await vpn.fetchStatistics()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }
}

#Preview {
    VPNControlView()
}
