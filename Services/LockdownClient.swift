//
//  LockdownClient.swift
//  Services
//
//  Minimale lockdownd-client: property-list-berichten met een 4-byte big-endian
//  lengte-prefix over een TCP-stroom. Genoeg om `QueryType` te doen en met
//  `StartService` een servicekanaal (zoals com.apple.dt.simulatelocation) te
//  laten openen.
//
//  Let op: lockdownd is een host-side protocol (usbmux). Deze client werkt
//  alleen wanneer er daadwerkelijk een lockdownd-endpoint op de opgegeven poort
//  luistert; op een standaard iOS-toestel is dat vanuit de app-sandbox niet het
//  geval. Zie de README, Module 2.
//

import Foundation
import os

final class LockdownClient {

    enum LockdownError: LocalizedError, Equatable {
        case invalidResponse
        case unexpectedType(String)
        case serviceError(String)
        case messageTooLarge(UInt32)
        case serializationFailed

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "lockdownd stuurde een onbegrijpelijk antwoord."
            case .unexpectedType(let type):
                return "Onverwacht lockdownd-type: \(type)."
            case .serviceError(let message):
                return "lockdownd weigerde de service: \(message)"
            case .messageTooLarge(let length):
                return "lockdownd-bericht te groot: \(length) bytes."
            case .serializationFailed:
                return "Kon het lockdownd-bericht niet (de)serialiseren."
            }
        }
    }

    struct ServiceDescriptor: Equatable {
        let port: UInt16
        let sslEnabled: Bool
    }

    /// Antwoorden groter dan dit accepteren we niet; een lockdownd-plist is klein.
    private static let maximumMessageLength: UInt32 = 1 << 22 // 4 MiB

    private let connection: TCPConnection
    private let logger = Logger(subsystem: TunnelConstants.loggingSubsystem, category: "LockdownClient")

    init(connection: TCPConnection) {
        self.connection = connection
    }

    func open() async throws {
        try await connection.open()
    }

    func close() {
        connection.close()
    }

    // MARK: - Handshake-stappen

    /// Vraagt het servicetype op. Voor lockdownd hoort dat
    /// `com.apple.mobile.lockdown` te zijn.
    @discardableResult
    func queryType() async throws -> String {
        try await send(["Request": "QueryType"])
        let response = try await receive()
        guard let type = response["Type"] as? String else {
            throw LockdownError.invalidResponse
        }
        return type
    }

    /// Vraagt lockdownd om een service te starten en geeft de toegewezen poort terug.
    func startService(_ service: String) async throws -> ServiceDescriptor {
        try await send([
            "Request": "StartService",
            "Service": service
        ])
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

    // MARK: - Bericht-framing

    private func send(_ message: [String: Any]) async throws {
        let body: Data
        do {
            body = try PropertyListSerialization.data(fromPropertyList: message,
                                                      format: .xml,
                                                      options: 0)
        } catch {
            throw LockdownError.serializationFailed
        }
        let length = UInt32(body.count).bigEndian
        var framed = withUnsafeBytes(of: length) { Data($0) }
        framed.append(body)
        try await connection.send(framed)
    }

    private func receive() async throws -> [String: Any] {
        let header = try await connection.receive(exactly: 4)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        guard length > 0 else { throw LockdownError.invalidResponse }
        guard length <= Self.maximumMessageLength else { throw LockdownError.messageTooLarge(length) }

        let body = try await connection.receive(exactly: Int(length))
        guard let plist = try? PropertyListSerialization.propertyList(from: body,
                                                                      options: [],
                                                                      format: nil),
              let dictionary = plist as? [String: Any] else {
            throw LockdownError.invalidResponse
        }
        return dictionary
    }
}
