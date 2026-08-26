//
//  IdeviceLocationClient.swift
//  Services
//
//  Swift-schil rond de C-FFI van `idevice` (https://github.com/jkcoxson/idevice,
//  MIT). Dit is het pad dat op iOS 17+ / iOS 26 werkt:
//
//      pairing file  ──▶  tunnel_create_rppairing   (RemotePairing, poort 49152)
//                    ──▶  remote_server_connect_rsd (DVT over RemoteServiceDiscovery)
//                    ──▶  location_simulation_new / _set / _clear
//
//  De FFI-aanroepen zijn BLOKKEREND. Alles loopt daarom over één seriële queue;
//  de handles worden nooit buiten die queue aangeraakt. De async-methoden
//  hieronder zijn dunne wrappers die de queue op- en afspringen.
//
//  Zonder de idevice-bibliotheek compileert dit bestand nog steeds: de
//  `#if canImport(idevice)`-tak valt terug op een duidelijke foutmelding.
//  Zie de README, "idevice inbouwen".
//

import Foundation
import Darwin
import os

#if canImport(idevice)
import idevice
#endif

/// Fouten uit de idevice-laag, vertaald naar iets leesbaars.
enum IdeviceError: LocalizedError {
    case libraryMissing
    case invalidAddress(String)
    case pairingFileUnreadable(String)
    case tunnelFailed(String)
    case remoteServerFailed(String)
    case locationServiceFailed(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .libraryMissing:
            return "De idevice-bibliotheek is niet aan het project toegevoegd. Zie README → 'idevice inbouwen'."
        case .invalidAddress(let address):
            return "Ongeldig doeladres: \(address)."
        case .pairingFileUnreadable(let message):
            return "Pairing file kon niet gelezen worden: \(message)"
        case .tunnelFailed(let message):
            return "Kon de tunnel naar het toestel niet opzetten: \(message)"
        case .remoteServerFailed(let message):
            return "Kon geen verbinding maken met de developer-services: \(message)"
        case .locationServiceFailed(let message):
            return "Locatiesimulatie mislukte: \(message)"
        case .notConnected:
            return "Er is geen actieve verbinding. Verbind eerst."
        }
    }

    /// Vertaalt de meestvoorkomende oorzaken naar concrete vervolgstappen.
    var recoverySuggestion: String? {
        switch self {
        case .tunnelFailed(let message):
            let lower = message.lowercased()
            if lower.contains("address already in use") || lower.contains("port already in use") {
                return "Een andere app gebruikt de tunnelpoort. Sluit andere JIT-/debug-/VPN-apps, herstart de VPN en probeer opnieuw."
            }
            if lower.contains("connection reset") {
                return "Controleer of de VPN verbonden is en of het doeladres \(TunnelConstants.peerAddress) is. Helpt dat niet, maak dan een verse pairing file."
            }
            if lower.contains("timed out") || lower.contains("timeout") {
                return "Zorg dat het toestel ontgrendeld is, dat Wi-Fi aanstaat en dat de VPN actief is."
            }
            if lower.contains("unreachable") || lower.contains("no route") {
                return "De route naar \(TunnelConstants.peerAddress) ontbreekt. Schakel de VPN uit en weer in."
            }
            return "Controleer of de VPN actief is en of het toestel ontgrendeld is."
        case .remoteServerFailed:
            return "Dit betekent meestal dat de Developer Disk Image niet gemount is. Sluit het toestel één keer op een pc/Mac aan om de DDI te mounten (blijft geldig tot een herstart)."
        case .pairingFileUnreadable:
            return "Maak een nieuwe pairing file met het toestel ontgrendeld en vertrouwd."
        default:
            return nil
        }
    }
}

/// Beheert één RemotePairing-tunnel en de locatiesimulatie daarop.
///
/// De client houdt de tunnel open zolang hij bestaat: een volgende
/// `setLocation` hergebruikt de bestaande sessie en is daardoor vrijwel
/// instant. Valt de sessie weg, dan wordt hij automatisch opnieuw opgebouwd.
final class IdeviceLocationClient: @unchecked Sendable {

    private let queue = DispatchQueue(label: "\(TunnelConstants.loggingSubsystem).idevice", qos: .userInitiated)
    private let logger = Logger(subsystem: TunnelConstants.loggingSubsystem, category: "IdeviceLocation")

    private let host: String
    private let port: UInt16
    private let clientName: String

#if canImport(idevice)
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var locationSimulation: OpaquePointer?
#endif

    init(host: String = TunnelConstants.peerAddress,
         port: UInt16 = TunnelConstants.remotePairingPort,
         clientName: String = "LocationSimulator") {
        self.host = host
        self.port = port
        self.clientName = clientName
    }

    deinit {
        // Direct, zonder `queue.sync`: bij deinit kan geen andere thread dit
        // object meer bereiken, en een sync-hop zou vastlopen als de laatste
        // referentie juist op die queue wordt losgelaten.
        teardown()
    }

    // MARK: - Publieke API

    /// Zet de gesimuleerde locatie. Bouwt de sessie op als die er nog niet is,
    /// en probeert één keer opnieuw als een bestaande sessie is weggevallen.
    func setLocation(latitude: Double, longitude: Double, pairingFile: Data) async throws {
        guard latitude.isFinite, longitude.isFinite,
              (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude) else {
            throw IdeviceError.locationServiceFailed("ongeldige coördinaat (\(latitude), \(longitude))")
        }
        try await onQueue {
            try self.blockingSetLocation(latitude: latitude, longitude: longitude, pairingFile: pairingFile)
        }
    }

    /// Beëindigt de simulatie; het toestel keert terug naar zijn echte locatie.
    func clearLocation() async throws {
        try await onQueue { try self.blockingClearLocation() }
    }

    /// Sluit de tunnel en geeft alle handles vrij.
    func disconnect() async {
        try? await onQueue { self.teardown() }
    }

    var isConnected: Bool {
#if canImport(idevice)
        queue.sync { locationSimulation != nil }
#else
        false
#endif
    }

    // MARK: - Queue-helper

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: - Implementatie

#if canImport(idevice)

    private func blockingSetLocation(latitude: Double, longitude: Double, pairingFile: Data) throws {
        // Bestaande sessie hergebruiken; dat scheelt een volledige handshake.
        if let simulation = locationSimulation {
            if let ffiError = location_simulation_set(simulation, latitude, longitude) {
                logger.warning("Bestaande locatiesessie faalde, opnieuw opbouwen: \(Self.message(ffiError), privacy: .public)")
                Self.free(ffiError)
                teardown()
            } else {
                return
            }
        }

        try blockingConnect(pairingFile: pairingFile)

        guard let simulation = locationSimulation else {
            throw IdeviceError.locationServiceFailed("locatiesessie ontbreekt na verbinden")
        }
        if let ffiError = location_simulation_set(simulation, latitude, longitude) {
            let message = Self.message(ffiError)
            Self.free(ffiError)
            teardown()
            throw IdeviceError.locationServiceFailed(message)
        }
        logger.log("Locatie gezet op \(latitude, privacy: .public), \(longitude, privacy: .public).")
    }

    private func blockingClearLocation() throws {
        guard let simulation = locationSimulation else {
            throw IdeviceError.notConnected
        }
        let ffiError = location_simulation_clear(simulation)
        teardown()
        if let ffiError {
            let message = Self.message(ffiError)
            Self.free(ffiError)
            throw IdeviceError.locationServiceFailed(message)
        }
        logger.log("Locatiesimulatie gestopt.")
    }

    /// Bouwt tunnel → remote server → locatiesessie op.
    private func blockingConnect(pairingFile: Data) throws {
        teardown()

        // 1. Doeladres.
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw IdeviceError.invalidAddress(host)
        }

        // 2. Pairing file inlezen (rechtstreeks uit geheugen, geen tijdelijk bestand).
        var pairingHandle: OpaquePointer?
        let pairingError = pairingFile.withUnsafeBytes { raw -> UnsafeMutablePointer<IdeviceFfiError>? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return rp_pairing_file_from_bytes(base, raw.count, &pairingHandle)
        }
        if let pairingError {
            let message = Self.message(pairingError)
            Self.free(pairingError)
            throw IdeviceError.pairingFileUnreadable(message)
        }
        guard let pairingHandle else {
            throw IdeviceError.pairingFileUnreadable("lege handle")
        }
        defer { rp_pairing_file_free(pairingHandle) }

        // 3. RemotePairing-tunnel opzetten.
        let tunnelError = clientName.withCString { name in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    tunnel_create_rppairing(
                        sockaddrPointer,
                        socklen_t(MemoryLayout<sockaddr_in>.stride),
                        name,
                        pairingHandle,
                        nil,   // pin_callback: niet nodig bij een bestaande pairing
                        nil,   // pin_context
                        &adapter,
                        &handshake
                    )
                }
            }
        }
        if let tunnelError {
            let message = Self.message(tunnelError)
            Self.free(tunnelError)
            teardown()
            throw IdeviceError.tunnelFailed(message)
        }
        guard adapter != nil, handshake != nil else {
            teardown()
            throw IdeviceError.tunnelFailed("tunnel zonder geldige handles")
        }

        // 4. DVT remote server over RSD.
        var remoteServer: OpaquePointer?
        if let serverError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
            let message = Self.message(serverError)
            Self.free(serverError)
            teardown()
            throw IdeviceError.remoteServerFailed(message)
        }
        guard let remoteServer else {
            teardown()
            throw IdeviceError.remoteServerFailed("lege handle")
        }

        // 5. Locatiesessie. Bij succes neemt deze de remote server over.
        var simulation: OpaquePointer?
        if let simulationError = location_simulation_new(remoteServer, &simulation) {
            let message = Self.message(simulationError)
            Self.free(simulationError)
            remote_server_free(remoteServer)
            teardown()
            throw IdeviceError.locationServiceFailed(message)
        }
        guard let simulation else {
            remote_server_free(remoteServer)
            teardown()
            throw IdeviceError.locationServiceFailed("lege handle")
        }
        // Eigendom van `remoteServer` is overgedragen aan `simulation`; niet vrijgeven.
        locationSimulation = simulation
        logger.log("Verbonden met \(self.host, privacy: .public):\(self.port, privacy: .public).")
    }

    /// Geeft alle handles vrij, in omgekeerde volgorde van aanmaak.
    private func teardown() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    // MARK: - Foutafhandeling

    private static func message(_ error: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        let code = error.pointee.code
        if let raw = error.pointee.message, let text = String(validatingUTF8: raw), !text.isEmpty {
            return "\(text) (code \(code))"
        }
        return "idevice-fout \(code)"
    }

    private static func free(_ error: UnsafeMutablePointer<IdeviceFfiError>) {
        idevice_error_free(error)
    }

#else

    // idevice is niet gelinkt: alle paden falen met een duidelijke uitleg.
    private func blockingSetLocation(latitude: Double, longitude: Double, pairingFile: Data) throws {
        throw IdeviceError.libraryMissing
    }

    private func blockingClearLocation() throws {
        throw IdeviceError.libraryMissing
    }

    private func teardown() {}

#endif
}
