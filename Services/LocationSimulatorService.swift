//
//  LocationSimulatorService.swift
//  Services
//
//  Spreekt het `com.apple.dt.simulatelocation`-protocol van Apple over een
//  TCP-socket, opgezet via de lokale tunnel uit Module 1 (host 127.0.0.1).
//
//  Een `actor`, zodat de socket-state serieel en Swift 6-veilig wordt beheerd:
//  er is nooit gelijktijdige toegang tot dezelfde verbinding.
//
//  BELANGRIJK OVER HET WIRE-FORMAAT
//  --------------------------------
//  Het echte simulatelocation-protocol stuurt de coördinaten als
//  lengte-geprefixte ASCII-strings, voorafgegaan door een 4-byte big-endian
//  commandowoord (0 = locatie zetten, 1 = simulatie stoppen). Dat is exact wat
//  Apples devicetools en libimobiledevice's `idevicesetlocation` doen, en het is
//  wat het toestel accepteert. Dat implementeren we hieronder.
//
//  De in de opdracht gevraagde big-endian IEEE-754 double-serialisatie zit als
//  herbruikbare helper in `Double.bigEndianBytes` (onderaan dit bestand), voor
//  het geval je die voor een andere variant nodig hebt — maar het
//  simulatelocation-kanaal zelf gebruikt strings, niet doubles.
//

import Foundation
import os

actor LocationSimulatorService {

    // MARK: - Fouten

    enum LocationSimulatorError: LocalizedError, Equatable {
        case invalidPort(Int)
        case invalidCoordinate(latitude: Double, longitude: Double)
        case handshakeFailed(String)
        case serviceUnavailable(String)
        case serviceRequiresSSL
        case notConnected
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .invalidPort(let port):
                return "Ongeldige lockdownd-poort: \(port)."
            case .invalidCoordinate(let latitude, let longitude):
                return "Ongeldige coördinaat: (\(latitude), \(longitude))."
            case .handshakeFailed(let message):
                return "lockdownd-handshake mislukt: \(message)"
            case .serviceUnavailable(let message):
                return "simulatelocation-service niet beschikbaar: \(message)"
            case .serviceRequiresSSL:
                return "De service vereist SSL; dat valt buiten deze minimale handshake."
            case .notConnected:
                return "Er is geen open simulatelocation-kanaal. Roep eerst connectToLockdownd(port:) aan."
            case .transport(let message):
                return message
            }
        }
    }

    /// Commandowoorden van het simulatelocation-protocol.
    private enum Command: UInt32 {
        case set = 0   // coördinaten volgen hierna
        case stop = 1  // simulatie beëindigen, geen payload
    }

    private static let serviceName = "com.apple.dt.simulatelocation"
    private static let defaultLockdownPort = 62078

    private let host: String
    private var service: TCPConnection?
    private let logger = Logger(subsystem: TunnelConstants.loggingSubsystem, category: "LocationSimulator")

    /// - Parameter host: standaard het loopback-adres uit Module 1.
    init(host: String = TunnelConstants.serverAddress) {
        self.host = host
    }

    // MARK: - Publieke status

    var isConnected: Bool { service != nil }

    // MARK: - Handshake

    /// Opent het kanaal voor locatiecommando's:
    /// 1. verbindt met lockdownd,
    /// 2. controleert het servicetype via `QueryType`,
    /// 3. laat lockdownd `com.apple.dt.simulatelocation` starten,
    /// 4. verbindt met de teruggegeven servicepoort.
    ///
    /// Na afloop staat het servicekanaal open en kan `sendSimulateLocation` volgen.
    func connectToLockdownd(port: Int = LocationSimulatorService.defaultLockdownPort) async throws {
        disconnect() // schone lei

        guard port > 0, port <= Int(UInt16.max) else {
            throw LocationSimulatorError.invalidPort(port)
        }

        let lockdown: LockdownClient
        do {
            let lockdownConnection = try TCPConnection(host: host, port: UInt16(port))
            lockdown = LockdownClient(connection: lockdownConnection)
        } catch {
            throw mapTransport(error)
        }

        do {
            try await lockdown.open()

            let type = try await lockdown.queryType()
            guard type == "com.apple.mobile.lockdown" else {
                throw LocationSimulatorError.handshakeFailed("onverwacht type '\(type)'")
            }

            let descriptor = try await lockdown.startService(Self.serviceName)
            lockdown.close()

            guard !descriptor.sslEnabled else {
                throw LocationSimulatorError.serviceRequiresSSL
            }

            let serviceConnection = try TCPConnection(host: host, port: descriptor.port)
            try await serviceConnection.open()
            service = serviceConnection
            logger.log("simulatelocation-kanaal open op poort \(descriptor.port, privacy: .public).")
        } catch {
            lockdown.close()
            disconnect()
            throw map(error)
        }
    }

    // MARK: - Locatie versturen

    /// Zet de gesimuleerde locatie van het toestel.
    ///
    /// Wire-formaat: `Command.set` (4 bytes, big-endian) gevolgd door de
    /// breedte- en lengtegraad, elk als lengte-geprefixte ASCII-string.
    func sendSimulateLocation(latitude: Double, longitude: Double) async throws {
        guard (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude),
              latitude.isFinite, longitude.isFinite else {
            throw LocationSimulatorError.invalidCoordinate(latitude: latitude, longitude: longitude)
        }
        guard let service else { throw LocationSimulatorError.notConnected }

        var payload = Self.commandBytes(.set)
        payload.append(Self.lengthPrefixedASCII(Self.coordinateString(latitude)))
        payload.append(Self.lengthPrefixedASCII(Self.coordinateString(longitude)))

        do {
            try await service.send(payload)
            logger.log("Locatie gezet op \(latitude, privacy: .public), \(longitude, privacy: .public).")
        } catch {
            disconnect() // sluit de socket bij een verzendfout
            throw mapTransport(error)
        }
    }

    /// Beëindigt de simulatie; het toestel keert terug naar zijn echte locatie.
    func stopSimulation() async throws {
        guard let service else { throw LocationSimulatorError.notConnected }
        do {
            try await service.send(Self.commandBytes(.stop))
            logger.log("Locatiesimulatie gestopt.")
        } catch {
            disconnect()
            throw mapTransport(error)
        }
    }

    /// Handige combinatie: handshake, locatie zetten, kanaal open laten.
    func simulate(latitude: Double,
                  longitude: Double,
                  lockdownPort: Int = LocationSimulatorService.defaultLockdownPort) async throws {
        if service == nil {
            try await connectToLockdownd(port: lockdownPort)
        }
        try await sendSimulateLocation(latitude: latitude, longitude: longitude)
    }

    /// Sluit het servicekanaal. Idempotent; wordt ook automatisch aangeroepen bij fouten.
    func disconnect() {
        service?.close()
        service = nil
    }

    // MARK: - Codering van het wire-formaat

    private static func commandBytes(_ command: Command) -> Data {
        var value = command.rawValue.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func lengthPrefixedASCII(_ string: String) -> Data {
        let bytes = Data(string.utf8)
        var length = UInt32(bytes.count).bigEndian
        var out = withUnsafeBytes(of: &length) { Data($0) }
        out.append(bytes)
        return out
    }

    /// Coördinaat als decimale string. `Double`-description geeft de kortste
    /// representatie die exact terug rondt (bijv. "37.7749").
    private static func coordinateString(_ value: Double) -> String {
        String(value)
    }

    // MARK: - Foutafbeelding

    private func map(_ error: Error) -> Error {
        if error is LocationSimulatorError { return error }
        return mapTransport(error)
    }

    private func mapTransport(_ error: Error) -> LocationSimulatorError {
        switch error {
        case let simulatorError as LocationSimulatorError:
            return simulatorError
        case let connectionError as TCPConnection.ConnectionError:
            return .transport(connectionError.localizedDescription)
        case let lockdownError as LockdownClient.LockdownError:
            return .serviceUnavailable(lockdownError.localizedDescription)
        default:
            return .transport(error.localizedDescription)
        }
    }
}

// MARK: - Big-endian IEEE-754 helper (gevraagd in de opdracht)

extension Double {
    /// De 8 bytes van deze `Double` als big-endian IEEE-754.
    ///
    /// Geleverd zoals gevraagd. Het simulatelocation-kanaal zelf gebruikt
    /// lengte-geprefixte ASCII-strings; gebruik deze helper alleen voor
    /// protocolvarianten die wél ruwe doubles verwachten.
    var bigEndianBytes: Data {
        var bits = bitPattern.bigEndian
        return withUnsafeBytes(of: &bits) { Data($0) }
    }
}
