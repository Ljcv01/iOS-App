//
//  SpoofingViewModel.swift
//  iOS-App
//
//  Orkestreert de keten: VPN-tunnel activeren (Module 1) → RemotePairing-tunnel
//  met de pairing file → locatie zetten via de developer-services (Module 2).
//

import Combine
import CoreLocation
import Foundation
import NetworkExtension

@MainActor
final class SpoofingViewModel: ObservableObject {

    /// Waar de keten zich bevindt. Bepaalt de knop en de protocol-badge.
    enum Phase: Equatable {
        case idle
        case startingVPN
        case connecting
        case sending
        case active
        case failed

        var isBusy: Bool {
            self == .startingVPN || self == .connecting || self == .sending
        }
    }

    struct AlertItem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    // MARK: - Gepubliceerde state

    @Published var selectedCoordinate: CLLocationCoordinate2D?
    @Published var host: String = TunnelConstants.peerAddress
    @Published private(set) var pairingFileName: String?
    @Published private(set) var pairingSummary: String?
    @Published private(set) var phase: Phase = .idle
    @Published var alert: AlertItem?

    private var pairingData: Data?
    private var client: IdeviceLocationClient?

    // MARK: - Afgeleide UI-waarden

    var isRunning: Bool { phase == .active }
    var hasPairingFile: Bool { pairingData != nil }

    var canStart: Bool {
        selectedCoordinate != nil && hasPairingFile && !host.isEmpty && !phase.isBusy
    }

    var protocolStatusText: String {
        switch phase {
        case .idle: return hasPairingFile ? "Gereed" : "Wacht op pairing file"
        case .startingVPN: return "VPN starten…"
        case .connecting: return "Tunnel opzetten…"
        case .sending: return "Locatie versturen…"
        case .active: return "Locatie actief"
        case .failed: return "Mislukt"
        }
    }

    // MARK: - Pairing file importeren

    /// Verwerkt het resultaat van de `.fileImporter`. Leest het bestand binnen de
    /// security-scoped toegang in en valideert het meteen, zodat een fout hier al
    /// zichtbaar wordt in plaats van pas tijdens de handshake.
    func importPairingFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let record = try PairingRecord(data: data)
                pairingData = data
                pairingFileName = url.lastPathComponent
                pairingSummary = "HostID \(record.hostID.prefix(8))…"
                if phase == .failed { phase = .idle }
            } catch {
                presentAlert("Ongeldig pairing-bestand", describe(error))
            }
        case .failure(let error):
            presentAlert("Import mislukt", describe(error))
        }
    }

    // MARK: - De keten

    /// Start de volledige keten: VPN → RemotePairing-tunnel → locatie.
    func startSpoofing(using vpn: VPNManager) async {
        guard let coordinate = selectedCoordinate else {
            presentAlert("Geen locatie", "Tik eerst op de kaart om een doel te kiezen.")
            return
        }
        guard let pairingData else {
            presentAlert("Geen pairing file", "Importeer eerst het pairing-bestand dat je via de pc hebt gemaakt.")
            return
        }

        do {
            // 1. Loopback-tunnel activeren en wachten tot hij echt verbonden is.
            phase = .startingVPN
            try await vpn.start()
            guard await waitForVPNConnected(vpn, timeout: 10) else {
                throw Failure("De VPN-tunnel kwam niet tot stand (status: \(vpn.statusDescription)).")
            }

            // 2 + 3. Tunnel opzetten en locatie zetten. De client doet de
            // RemotePairing-handshake en de RSD-verbinding in één keer.
            phase = .connecting
            let client = self.client ?? IdeviceLocationClient(host: host)
            self.client = client

            phase = .sending
            try await client.setLocation(latitude: coordinate.latitude,
                                         longitude: coordinate.longitude,
                                         pairingFile: pairingData)
            phase = .active
        } catch {
            phase = .failed
            await client?.disconnect()
            client = nil
            presentAlert("Spoofing mislukt", describe(error))
        }
    }

    /// Stopt de simulatie en zet alles terug.
    func stopSpoofing(using vpn: VPNManager) async {
        if let client {
            try? await client.clearLocation()
            await client.disconnect()
        }
        client = nil
        vpn.stop()
        phase = .idle
    }

    /// Verstuurt een nieuw doel terwijl de keten al actief is (verplaatst de speld).
    func updateActiveLocation() async {
        guard phase == .active,
              let client,
              let pairingData,
              let coordinate = selectedCoordinate else { return }
        do {
            try await client.setLocation(latitude: coordinate.latitude,
                                         longitude: coordinate.longitude,
                                         pairingFile: pairingData)
        } catch {
            phase = .failed
            await client.disconnect()
            self.client = nil
            presentAlert("Kon locatie niet bijwerken", describe(error))
        }
    }

    // MARK: - Helpers

    private func waitForVPNConnected(_ vpn: VPNManager, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if vpn.status == .connected { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return vpn.status == .connected
    }

    /// Voegt de herstelsuggestie toe als die er is — dat scheelt zoeken.
    private func describe(_ error: Error) -> String {
        guard let localized = error as? LocalizedError else {
            return error.localizedDescription
        }
        let description = localized.errorDescription ?? error.localizedDescription
        if let suggestion = localized.recoverySuggestion {
            return "\(description)\n\n\(suggestion)"
        }
        return description
    }

    private func presentAlert(_ title: String, _ message: String) {
        alert = AlertItem(title: title, message: message)
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
