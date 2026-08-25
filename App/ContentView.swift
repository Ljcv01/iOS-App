//
//  ContentView.swift
//  iOS-App
//
//  Module 4 — SwiftUI-frontend. Kaart om een doel te prikken, importer voor het
//  .bplist Pairing File, status-badges voor VPN (Module 1) en protocol (Module 2),
//  en één knop die de hele keten start.
//
//  Zet deze view als root in je App-struct:
//
//      @main
//      struct LocationSimulatorApp: App {
//          var body: some Scene { WindowGroup { ContentView() } }
//      }
//

import MapKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {

    @StateObject private var vpn = VPNManager()
    @StateObject private var model = SpoofingViewModel()

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 52.3676, longitude: 4.9041),
                           span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4))
    )
    @State private var showingImporter = false

    /// bplist is een property list; sta ook ruwe data toe voor exports zonder UTI.
    private let pairingFileTypes: [UTType] = [.propertyList, .data]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                mapLayer
                controlCard
            }
            .navigationTitle("Location Simulator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Pairing File", systemImage: "doc.badge.plus")
                    }
                }
            }
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: pairingFileTypes,
                          onCompletion: model.importPairingFile)
            .alert(item: $model.alert) { alert in
                Alert(title: Text(alert.title),
                      message: Text(alert.message),
                      dismissButton: .default(Text("OK")))
            }
            .task { await vpn.refresh() }
        }
    }

    // MARK: - Kaart

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                if let coordinate = model.selectedCoordinate {
                    Marker("Doel", systemImage: "mappin", coordinate: coordinate)
                        .tint(.red)
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .ignoresSafeArea(edges: .top)
            .onTapGesture { screenPoint in
                guard let coordinate = proxy.convert(screenPoint, from: .local) else { return }
                model.selectedCoordinate = coordinate
                Task { await model.updateActiveLocation() }
            }
        }
    }

    // MARK: - Bedieningskaart

    private var controlCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                StatusBadge(title: "VPN",
                            value: vpn.statusDescription,
                            systemImage: "network.badge.shield.half.filled",
                            tint: vpnTint)
                StatusBadge(title: "Protocol",
                            value: model.protocolStatusText,
                            systemImage: "antenna.radiowaves.left.and.right",
                            tint: protocolTint)
            }

            coordinateRow
            pairingRow
            hostRow
            actionButton
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }

    private var coordinateRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(.red)
            if let coordinate = model.selectedCoordinate {
                Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                    .font(.callout.monospacedDigit())
            } else {
                Text("Tik op de kaart om een doel te kiezen")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pairingRow: some View {
        HStack(spacing: 10) {
            Image(systemName: model.hasPairingFile ? "checkmark.seal.fill" : "doc.questionmark")
                .foregroundStyle(model.hasPairingFile ? .green : .secondary)
            Text(model.pairingFileName ?? "Geen Pairing File geïmporteerd")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(model.hasPairingFile ? .primary : .secondary)
            Spacer()
            Button("Kies") { showingImporter = true }
                .font(.callout.weight(.semibold))
                .buttonStyle(.borderless)
        }
    }

    private var hostRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
            TextField("Host (bijv. 127.0.0.1)", text: $model.host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .font(.callout.monospaced())
                .disabled(model.isRunning || model.phase.isBusy)
        }
    }

    private var actionButton: some View {
        Button {
            Task {
                if model.isRunning {
                    await model.stopSpoofing(using: vpn)
                } else {
                    await model.startSpoofing(using: vpn)
                }
            }
        } label: {
            HStack {
                if model.phase.isBusy {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: model.isRunning ? "stop.fill" : "location.fill")
                }
                Text(buttonTitle)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(model.isRunning ? .red : .accentColor)
        .disabled(!model.isRunning && !model.canStart)
    }

    private var buttonTitle: String {
        switch model.phase {
        case .startingVPN: return "VPN starten…"
        case .pairing: return "Koppelen…"
        case .sending: return "Versturen…"
        case .active: return "Stop Spoofing"
        case .idle, .failed: return "Start Spoofing"
        }
    }

    // MARK: - Badge-kleuren

    private var vpnTint: Color {
        switch vpn.status {
        case .connected: return .green
        case .connecting, .reasserting, .disconnecting: return .orange
        case .invalid: return .gray
        default: return .secondary
        }
    }

    private var protocolTint: Color {
        switch model.phase {
        case .active: return .green
        case .failed: return .red
        case .idle: return model.hasPairingFile ? .blue : .gray
        default: return .orange
        }
    }
}

// MARK: - Herbruikbare status-badge

private struct StatusBadge: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(tint)

            Text(value)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    ContentView()
}
