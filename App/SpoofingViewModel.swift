//
//  SpoofingViewModel.swift
//  iOS-App
//
//  Orkestreert de keten van Module 4: VPN-tunnel activeren (Module 1) →
//  koppelen met de pairing record en TLS-handshake (Module 2) → coördinaten
//  versturen. Houdt de UI-state vast en vertaalt fouten naar alerts.
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
        case pairing
        case sending
        case active
        case failed

        var isBusy: Bool {
            self == .startingVPN || self == .pairing || self == .sending
        }
    }

    /// Eenvoudig alert-model voor `.alert(item:)`.
    struct AlertItem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    // MARK: - Gepubliceerde state

    @Published var selectedCoordinate: CLLocationCoordinate2D?
    @Published var host: String = TunnelConstants.serverAddress
    @Published private(set) var pairingFileName: String?
    @Published private(set) var phase: Phase = .idle
    @Published var alert: AlertItem?

    private var pairingData: Data?
    private var service: LocationSimulatorService?

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
        case .pairing: return "Koppelen met lockdownd…"
        case .sending: return "Coördinaten versturen…"
        case .active: return "Locatie actief"
        case .failed: return "Mislukt"
        }
    }

    // MARK: - Pairing file importeren

    /// Verwerkt het resultaat van de `.fileImporter`. Leest het bestand binnen de
    /// security-scoped toegang in en valideert het meteen als pairing record, zodat
    /// een fout hier al zichtbaar wordt in plaats van pas tijdens de handshake.
    func importPairingFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                _ = try PairingRecord(data: data) // vroege validatie
                pairingData = data
                pairingFileName = url.lastPathComponent
                if phase == .failed { phase = .idle }
            } catch {
                presentAlert("Ongeldig pairing-bestand", error.localizedDescription)
            }
        case .failure(let error):
            presentAlert("Import mislukt", error.localizedDescription)
        }
    }

    // MARK: - De keten

    /// Start de volledige keten: VPN → pairing/TLS → coördinaten.
    func startSpoofing(using vpn: VPNManager) async {
        guard let coordinate = selectedCoordinate else {
            presentAlert("Geen locatie", "Tik eerst op de kaart om een doel te kiezen.")
            return
        }
        guard let pairingData else {
            presentAlert("Geen pairing file", "Importeer eerst het .bplist Pairing File.")
            return
        }

        do {
            // 1. VPN-tunnel activeren en wachten tot hij daadwerkelijk verbindt.
            phase = .startingVPN
            try await vpn.start()
            guard await waitForVPNConnected(vpn, timeout: 8) else {
                throw Failure("De VPN-tunnel kwam niet tot stand (status: \(vpn.statusDescription)).")
            }

            // 2. Pairing record inlezen en het lockdown-kanaal openen (incl. TLS).
            phase = .pairing
            let record = try PairingRecord(data: pairingData)
            let service = LocationSimulatorService(host: host)
            self.service = service
            try await service.connectToLockdownd(pairingRecord: record)

            // 3. Coördinaten versturen.
            phase = .sending
            try await service.sendSimulateLocation(latitude: coordinate.latitude,
                                                   longitude: coordinate.longitude)

            phase = .active
        } catch {
            phase = .failed
            await service?.disconnect()
            service = nil
            presentAlert("Spoofing mislukt", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Stopt de simulatie en zet alles terug.
    func stopSpoofing(using vpn: VPNManager) async {
        if let service {
            try? await service.stopSimulation()
            await service.disconnect()
        }
        service = nil
        vpn.stop()
        phase = .idle
    }

    /// Verstuurt een nieuw doel terwijl de keten al actief is (verplaatst de speld).
    func updateActiveLocation() async {
        guard phase == .active, let service, let coordinate = selectedCoordinate else { return }
        do {
            try await service.sendSimulateLocation(latitude: coordinate.latitude,
                                                   longitude: coordinate.longitude)
        } catch {
            phase = .failed
            await service.disconnect()
            self.service = nil
            presentAlert("Kon locatie niet bijwerken", error.localizedDescription)
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

    private func presentAlert(_ title: String, _ message: String) {
        alert = AlertItem(title: title, message: message)
    }

    /// Interne fout met een leesbare beschrijving.
    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
