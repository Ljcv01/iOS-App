//
//  LocationSimulatorService.swift
//  Services
//
//  Spreekt het `com.apple.dt.simulatelocation`-protocol van Apple over een
//  (eventueel TLS-beveiligde) socket, opgezet via de lockdown-handshake met een
//  pairing record.
//
//  Een `actor`, zodat de socket-state serieel en Swift 6-veilig wordt beheerd.
//
//  WIRE-FORMAAT
//  ------------
//  Het simulatelocation-protocol stuurt de coördinaten als lengte-geprefixte
//  ASCII-strings, voorafgegaan door een 4-byte big-endian commandowoord
//  (0 = locatie zetten, 1 = simulatie stoppen). Dat is exact wat Apples
//  devicetools en libimobiledevice's `idevicesetlocation` doen.
//
//  De in de opdracht genoemde big-endian IEEE-754 double-serialisatie zit als
//  herbruikbare helper in `Double.bigEndianBytes` (onderaan) — het
//  simulatelocation-kanaal zelf gebruikt echter strings, geen doubles.
//
//  HAALBAARHEID
//  ------------
//  simulatelocation vereist dat de Developer Disk Image gemount is. Op iOS 17+
//  is dat een gepersonaliseerde DDI die vooraf via een PC/Mac gemount moet zijn,
//  en zijn developer-services bovendien verhuisd naar RemoteServiceDiscovery.
//  Deze client implementeert het klassieke lockdown-pad correct; op moderne iOS
//  werkt hij alleen wanneer dat pad daadwerkelijk beschikbaar is gemaakt.
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
            case .notConnected:
                return "Er is geen open simulatelocation-kanaal. Roep eerst connectToLockdownd(...) aan."
            case .transport(let message):
                return message
            }
        }
    }

    private enum Command: UInt32 {
        case set = 0   // coördinaten volgen hierna
        case stop = 1  // simulatie beëindigen, geen payload
    }

    private static let serviceName = "com.apple.dt.simulatelocation"
    private static let lockdownPort = 62078

    private let host: String
    private var service: SocketChannel?
    private let logger = Logger(subsystem: TunnelConstants.loggingSubsystem, category: "LocationSimulator")

    /// - Parameter host: het Wi-Fi-IP van het toestel, of het loopback-adres uit
    ///   Module 1 wanneer het verkeer daarheen wordt gerouteerd.
    init(host: String = TunnelConstants.serverAddress) {
        self.host = host
    }

    var isConnected: Bool { service != nil }

    // MARK: - Handshake

    /// Opent het kanaal voor locatiecommando's:
    /// 1. verbindt met lockdownd,
    /// 2. controleert het servicetype via `QueryType`,
    /// 3. start een sessie met de pairing record en upgradet naar TLS,
    /// 4. laat lockdownd `com.apple.dt.simulatelocation` starten,
    /// 5. verbindt met de servicepoort (met TLS als de service dat vraagt).
    func connectToLockdownd(pairingRecord: PairingRecord,
                            port: Int = LocationSimulatorService.lockdownPort) async throws {
        disconnect()

        guard port > 0, port <= Int(UInt16.max) else {
            throw LocationSimulatorError.invalidPort(port)
        }

        let lockdown = LockdownClient(channel: SocketChannel(host: host, port: UInt16(port)))
        do {
            try await lockdown.open()

            let type = try await lockdown.queryType()
            guard type == "com.apple.mobile.lockdown" else {
                throw LocationSimulatorError.handshakeFailed("onverwacht type '\(type)'")
            }

            try await lockdown.startSession(pairingRecord: pairingRecord)
            let descriptor = try await lockdown.startService(Self.serviceName)
            try await lockdown.stopSession()
            lockdown.close()

            let serviceChannel = SocketChannel(host: host, port: descriptor.port)
            try await serviceChannel.connect()
            if descriptor.sslEnabled {
                let credentials = TLSCredentials(
                    identity: try pairingRecord.makeClientIdentity(),
                    pinnedCertificateDER: pairingRecord.deviceCertificateDER
                )
                try await serviceChannel.startTLS(credentials: credentials)
            }
            service = serviceChannel
            logger.log("simulatelocation-kanaal open op poort \(descriptor.port, privacy: .public).")
        } catch {
            lockdown.close()
            disconnect()
            throw map(error)
        }
    }

    /// Gemaksvariant die de pairing record uit een bestand inleest.
    func connectToLockdownd(pairingRecordURL: URL,
                            port: Int = LocationSimulatorService.lockdownPort) async throws {
        let record: PairingRecord
        do {
            record = try PairingRecord(url: pairingRecordURL)
        } catch {
            throw map(error)
        }
        try await connectToLockdownd(pairingRecord: record, port: port)
    }

    // MARK: - Locatie versturen

    /// Zet de gesimuleerde locatie van het toestel.
    ///
    /// Wire-formaat: `Command.set` (4 bytes, big-endian) gevolgd door de breedte-
    /// en lengtegraad, elk als lengte-geprefixte ASCII-string.
    func sendSimulateLocation(latitude: Double, longitude: Double) async throws {
        guard latitude.isFinite, longitude.isFinite,
              (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude) else {
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
            disconnect()
            throw map(error)
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
            throw map(error)
        }
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

    private func map(_ error: Error) -> LocationSimulatorError {
        switch error {
        case let simulatorError as LocationSimulatorError:
            return simulatorError
        case let channelError as SocketChannel.ChannelError:
            return .transport(channelError.localizedDescription)
        case let lockdownError as LockdownClient.LockdownError:
            return .serviceUnavailable(lockdownError.localizedDescription)
        case let pairingError as PairingRecord.ParseError:
            return .handshakeFailed(pairingError.localizedDescription)
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
