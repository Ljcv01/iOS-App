//
//  TCPConnection.swift
//  Services
//
//  Dunne async/await-schil rond NWConnection (Network.framework) voor één
//  bidirectionele TCP-stroom. Bewust `@unchecked Sendable`: NWConnection is een
//  class die zijn callbacks op een eigen serial queue levert; de state die we
//  delen zit achter die queue en achter continuations die precies één keer
//  worden hervat.
//

import Foundation
import Network
import os

final class TCPConnection: @unchecked Sendable {

    enum ConnectionError: LocalizedError, Equatable {
        case invalidPort(Int)
        case failed(String)
        case cancelled
        case sendFailed(String)
        case receiveFailed(String)
        case endOfStream

        var errorDescription: String? {
            switch self {
            case .invalidPort(let port):
                return "Ongeldige TCP-poort: \(port)."
            case .failed(let message):
                return "Verbinding mislukt: \(message)"
            case .cancelled:
                return "De verbinding is gesloten."
            case .sendFailed(let message):
                return "Versturen mislukt: \(message)"
            case .receiveFailed(let message):
                return "Ontvangen mislukt: \(message)"
            case .endOfStream:
                return "De tegenpartij sloot de verbinding voortijdig."
            }
        }
    }

    /// Zorgt dat een continuation hoogstens één keer wordt hervat, ongeacht in
    /// welke volgorde de NWConnection-states binnenkomen.
    private final class ResumeOnce<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?

        init(_ continuation: CheckedContinuation<Value, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: Value) {
            take()?.resume(returning: value)
        }

        func resume(throwing error: Error) {
            take()?.resume(throwing: error)
        }

        private func take() -> CheckedContinuation<Value, Error>? {
            lock.lock(); defer { lock.unlock() }
            let pending = continuation
            continuation = nil
            return pending
        }
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let logger = Logger(subsystem: TunnelConstants.loggingSubsystem, category: "TCPConnection")

    init(host: String, port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ConnectionError.invalidPort(Int(port))
        }
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        // De tunnel uit Module 1 leidt loopback lokaal af; laat het pad daar buiten.
        parameters.prohibitedInterfaceTypes = [.cellular]

        self.connection = NWConnection(host: NWEndpoint.Host(host),
                                       port: endpointPort,
                                       using: parameters)
        self.queue = DispatchQueue(label: "\(TunnelConstants.loggingSubsystem).tcp")
    }

    // MARK: - Levenscyclus

    /// Start de verbinding en keert pas terug wanneer de socket `.ready` is.
    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ResumeOnce(continuation)
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    gate.resume(returning: ())
                case .failed(let error):
                    self?.logger.error("TCP mislukt: \(error.localizedDescription, privacy: .public)")
                    gate.resume(throwing: ConnectionError.failed(error.localizedDescription))
                case .waiting(let error):
                    // Voor een lokale service die er hoort te zijn behandelen we
                    // "waiting" (bijv. connection refused) als een harde fout in
                    // plaats van eindeloos te blijven wachten.
                    self?.logger.error("TCP wacht: \(error.localizedDescription, privacy: .public)")
                    gate.resume(throwing: ConnectionError.failed(error.localizedDescription))
                case .cancelled:
                    gate.resume(throwing: ConnectionError.cancelled)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Verbreekt de verbinding. Idempotent.
    func close() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    // MARK: - Versturen

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ConnectionError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    // MARK: - Ontvangen

    /// Ontvangt exact `count` bytes, of gooit `.endOfStream` als de tegenpartij
    /// eerder sluit. Handig voor lengte-geprefixte protocollen.
    func receive(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        var buffer = Data()
        buffer.reserveCapacity(count)
        while buffer.count < count {
            let remaining = count - buffer.count
            let chunk = try await receiveChunk(minimum: remaining, maximum: remaining)
            guard !chunk.isEmpty else { throw ConnectionError.endOfStream }
            buffer.append(chunk)
        }
        return buffer
    }

    private func receiveChunk(minimum: Int, maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: ConnectionError.receiveFailed(error.localizedDescription))
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                // Lege data + isComplete == EOF; dat signaleren we als lege buffer.
                continuation.resume(returning: Data())
                _ = isComplete
            }
        }
    }
}
