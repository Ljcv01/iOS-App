//
//  LockdownClient.swift
//  Services
//
//  Lockdownd-client bovenop SocketChannel. Berichten zijn property lists met een
//  4-byte big-endian lengte-prefix. Implementeert de minimale sequentie:
//
//      QueryType  ->  StartSession (met HostID/SystemBUID uit de pairing record)
//                 ->  TLS-upgrade (als EnableSessionSSL)
//                 ->  StartService (bijv. com.apple.dt.simulatelocation)
//
//  Let op: lockdownd is een host-side (usbmux) protocol. Deze client werkt alleen
//  wanneer er echt een lockdownd-endpoint op de opgegeven poort luistert en de
//  pairing record bij dit toestel hoort. Zie de README, Module 2.
//

import Foundation
import os

final class LockdownClient {

    enum LockdownError: LocalizedError, Equatable {
        case invalidResponse
        case unexpectedType(String)
        case sessionRefused(String)
        case serviceError(String)
        case messageTooLarge(UInt32)
        case serializationFailed

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "lockdownd stuurde een onbegrijpelijk antwoord."
            case .unexpectedType(let type): return "Onverwacht lockdownd-type: \(type)."
            case .sessionRefused(let message): return "lockdownd weigerde de sessie: \(message)"
            case .serviceError(let message): return "lockdownd weigerde de service: \(message)"
            case .messageTooLarge(let length): return "lockdownd-bericht te groot: \(length) bytes."
            case .serializationFailed: return "Kon het lockdownd-bericht niet (de)serialiseren."
            }
        }
    }

    struct ServiceDescriptor: Equatable {
        let port: UInt16
        let sslEnabled: Bool
    }

    private static let maximumMessageLength: UInt32 = 1 << 22 // 4 MiB

    private let channel: SocketChannel
    private let logger = Logger(subsystem: TunnelConstants.loggingSubsystem, category: "LockdownClient")
    private var sessionID: String?

    init(channel: SocketChannel) {
        self.channel = channel
    }

    // MARK: - Verbinden

    func open() async throws {
        try await channel.connect()
    }

    func close() {
        channel.close()
    }

    // MARK: - Handshake

    /// Vraagt het servicetype op; voor lockdownd hoort dat
    /// `com.apple.mobile.lockdown` te zijn.
    @discardableResult
    func queryType() async throws -> String {
        try await send(["Request": "QueryType"])
        let response = try await receive()
        guard let type = response["Type"] as? String else { throw LockdownError.invalidResponse }
        return type
    }

    /// Start een sessie met de host-credentials en upgradet de verbinding naar
    /// TLS wanneer lockdownd daarom vraagt (`EnableSessionSSL`).
    func startSession(pairingRecord: PairingRecord) async throws {
        try await send([
            "Request": "StartSession",
            "HostID": pairingRecord.hostID,
            "SystemBUID": pairingRecord.systemBUID
        ])
        let response = try await receive()

        if let error = response["Error"] as? String {
            throw LockdownError.sessionRefused(error)
        }
        sessionID = response["SessionID"] as? String

        if (response["EnableSessionSSL"] as? Bool) == true {
            let credentials = TLSCredentials(
                identity: try pairingRecord.makeClientIdentity(),
                pinnedCertificateDER: pairingRecord.deviceCertificateDER
            )
            try await channel.startTLS(credentials: credentials)
            logger.log("lockdownd-sessie naar TLS geüpgraded.")
        }
    }

    /// Vraagt lockdownd om een service te starten en geeft de toegewezen poort terug.
    func startService(_ service: String) async throws -> ServiceDescriptor {
        try await send(["Request": "StartService", "Service": service])
        let response = try await receive()

        if let error = response["Error"] as? String {
            throw LockdownError.serviceError(error)
        }
        guard let portValue = response["Port"] as? Int,
              portValue > 0, portValue <= Int(UInt16.max) else {
            throw LockdownError.invalidResponse
        }
        let ssl = (response["EnableServiceSSL"] as? Bool) ?? false
        return ServiceDescriptor(port: UInt16(portValue), sslEnabled: ssl)
    }

    /// Sluit de sessie netjes af (best effort).
    func stopSession() async throws {
        guard let sessionID else { return }
        try await send(["Request": "StopSession", "SessionID": sessionID])
        _ = try? await receive()
        self.sessionID = nil
    }

    // MARK: - Bericht-framing

    private func send(_ message: [String: Any]) async throws {
        let body: Data
        do {
            body = try PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
        } catch {
            throw LockdownError.serializationFailed
        }
        let length = UInt32(body.count).bigEndian
        var framed = withUnsafeBytes(of: length) { Data($0) }
        framed.append(body)
        try await channel.send(framed)
    }

    private func receive() async throws -> [String: Any] {
        let header = try await channel.receive(exactly: 4)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        guard length > 0 else { throw LockdownError.invalidResponse }
        guard length <= Self.maximumMessageLength else { throw LockdownError.messageTooLarge(length) }

        let body = try await channel.receive(exactly: Int(length))
        guard let plist = try? PropertyListSerialization.propertyList(from: body, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            throw LockdownError.invalidResponse
        }
        return dictionary
    }
}
