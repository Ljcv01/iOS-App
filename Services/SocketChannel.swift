//
//  SocketChannel.swift
//  Services
//
//  Async/await-schil rond een rauwe POSIX-TCP-socket met een optionele
//  Secure Transport (SSLContext) TLS-laag die *midden in de stream* kan worden
//  geactiveerd.
//
//  Waarom niet NWConnection? Het lockdown-protocol doet eerst een plaintext
//  StartSession en upgradet daarna dezelfde socket naar TLS (STARTTLS-stijl).
//  NWConnection kan geen TLS starten op een bestaande verbinding — daar moet
//  TLS bij het opzetten al vaststaan. Secure Transport kan met SSLSetIOFuncs
//  wél een willekeurige fd omhullen, en is daarmee de enige manier om deze
//  in-stream upgrade op iOS te doen. SSLContext is deprecated maar functioneel.
//
//  Alle socket- en TLS-toegang loopt over één seriële queue, zodat er nooit
//  gelijktijdige toegang tot de fd of de SSLContext is (Swift 6-veilig).
//

import Foundation
import Darwin
import Security
import os

/// TLS-materiaal, gebundeld als `Sendable` zodat het de queue-grens over mag.
struct TLSCredentials: @unchecked Sendable {
    let identity: SecIdentity
    let pinnedCertificateDER: Data
}

final class SocketChannel: @unchecked Sendable {

    enum ChannelError: LocalizedError, Equatable {
        case resolveFailed(String)
        case connectFailed(String)
        case notConnected
        case closed
        case ioFailed(String)
        case endOfStream
        case tlsHandshakeFailed(OSStatus)
        case tlsSetupFailed(String)
        case certificatePinMismatch

        var errorDescription: String? {
            switch self {
            case .resolveFailed(let host): return "Kon host niet opzoeken: \(host)."
            case .connectFailed(let message): return "Verbinden mislukt: \(message)"
            case .notConnected: return "De socket is niet verbonden."
            case .closed: return "De socket is gesloten."
            case .ioFailed(let message): return "I/O-fout: \(message)"
            case .endOfStream: return "De tegenpartij sloot de verbinding voortijdig."
            case .tlsHandshakeFailed(let status): return "TLS-handshake mislukte (status \(status))."
            case .tlsSetupFailed(let message): return "TLS-opzet mislukte: \(message)"
            case .certificatePinMismatch: return "Het device-certificaat komt niet overeen met de pairing record."
            }
        }
    }

    private let host: String
    private let port: UInt16
    private let queue: DispatchQueue
    private let logger = Logger(subsystem: TunnelConstants.loggingSubsystem, category: "SocketChannel")

    private var fd: Int32 = -1
    private var sslContext: SSLContext?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        self.queue = DispatchQueue(label: "\(TunnelConstants.loggingSubsystem).socket.\(port)")
    }

    var isSecure: Bool {
        queue.sync { sslContext != nil }
    }

    // MARK: - Queue-helper

    /// Voert `body` serieel op de socket-queue uit en levert het resultaat async.
    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: - Verbinden

    func connect(timeout: TimeInterval = 15) async throws {
        try await onQueue { try self.blockingConnect(timeout: timeout) }
    }

    private func blockingConnect(timeout: TimeInterval) throws {
        var hints = addrinfo(ai_flags: 0,
                             ai_family: AF_UNSPEC,
                             ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0,
                             ai_canonname: nil,
                             ai_addr: nil,
                             ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        let resolveStatus = getaddrinfo(host, String(port), &hints, &info)
        guard resolveStatus == 0, let first = info else {
            throw ChannelError.resolveFailed(host)
        }
        defer { freeaddrinfo(info) }

        var lastError = "onbekende fout"
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let entry = candidate {
            let socketFD = socket(entry.pointee.ai_family,
                                  entry.pointee.ai_socktype,
                                  entry.pointee.ai_protocol)
            if socketFD < 0 {
                lastError = String(cString: strerror(errno))
                candidate = entry.pointee.ai_next
                continue
            }

            applyTimeouts(socketFD, seconds: timeout)
            var noSignalPipe: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignalPipe, socklen_t(MemoryLayout<Int32>.size))

            if Darwin.connect(socketFD, entry.pointee.ai_addr, entry.pointee.ai_addrlen) == 0 {
                fd = socketFD
                logger.log("Verbonden met \(self.host, privacy: .public):\(self.port, privacy: .public).")
                return
            }
            lastError = String(cString: strerror(errno))
            close(socketFD)
            candidate = entry.pointee.ai_next
        }
        throw ChannelError.connectFailed(lastError)
    }

    private func applyTimeouts(_ socketFD: Int32, seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: - TLS-upgrade

    /// Upgradet de bestaande verbinding naar TLS met een client-identity en pint
    /// de peer op het meegegeven device-certificaat.
    func startTLS(credentials: TLSCredentials) async throws {
        try await onQueue { try self.blockingStartTLS(credentials: credentials) }
    }

    private func blockingStartTLS(credentials: TLSCredentials) throws {
        guard fd >= 0 else { throw ChannelError.notConnected }
        guard let context = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw ChannelError.tlsSetupFailed("SSLCreateContext gaf nil")
        }

        var status = SSLSetIOFuncs(context, socketChannelSSLRead, socketChannelSSLWrite)
        guard status == errSecSuccess else { throw ChannelError.tlsSetupFailed("SSLSetIOFuncs \(status)") }

        // De fd-waarde reist als connection-pointer mee; hij wordt nooit
        // gedereferenceerd, alleen teruggelezen in de I/O-callbacks.
        guard let connection = UnsafeRawPointer(bitPattern: Int(fd)) else {
            throw ChannelError.tlsSetupFailed("ongeldige fd")
        }
        status = SSLSetConnection(context, connection)
        guard status == errSecSuccess else { throw ChannelError.tlsSetupFailed("SSLSetConnection \(status)") }

        // Client-certificaat (host-identity uit de pairing record).
        status = SSLSetCertificate(context, [credentials.identity] as CFArray)
        guard status == errSecSuccess else { throw ChannelError.tlsSetupFailed("SSLSetCertificate \(status)") }

        // Pairing-TLS gebruikt zelfondertekende certificaten; we onderbreken de
        // handshake om de peer zelf te pinnen in plaats van keten-validatie.
        SSLSetSessionOption(context, .breakOnServerAuth, true)
        // Lockdownd draait een oude TLS-stack; sta een lage ondergrens toe.
        SSLSetProtocolVersionMin(context, .tlsProtocol1)

        handshakeLoop: while true {
            let handshakeStatus = SSLHandshake(context)
            switch handshakeStatus {
            case errSecSuccess:
                break handshakeLoop
            case errSSLWouldBlock:
                continue
            case errSSLServerAuthCompleted:
                try verifyPeer(context, pinnedDER: credentials.pinnedCertificateDER)
                continue
            default:
                throw ChannelError.tlsHandshakeFailed(handshakeStatus)
            }
        }

        sslContext = context
        logger.log("TLS-upgrade voltooid op \(self.host, privacy: .public):\(self.port, privacy: .public).")
    }

    private func verifyPeer(_ context: SSLContext, pinnedDER: Data) throws {
        var trust: SecTrust?
        let status = SSLCopyPeerTrust(context, &trust)
        guard status == errSecSuccess, let trust else {
            throw ChannelError.tlsSetupFailed("SSLCopyPeerTrust \(status)")
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            throw ChannelError.certificatePinMismatch
        }
        guard (SecCertificateCopyData(leaf) as Data) == pinnedDER else {
            throw ChannelError.certificatePinMismatch
        }
    }

    // MARK: - Versturen / ontvangen

    func send(_ data: Data) async throws {
        try await onQueue { try self.blockingSend(data) }
    }

    private func blockingSend(_ data: Data) throws {
        guard fd >= 0 else { throw ChannelError.notConnected }
        if let context = sslContext {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var total = 0
                while total < data.count {
                    var processed = 0
                    let status = SSLWrite(context, base.advanced(by: total), data.count - total, &processed)
                    total += processed
                    if status == errSSLWouldBlock { continue }
                    guard status == errSecSuccess else { throw ChannelError.ioFailed("SSLWrite \(status)") }
                }
            }
        } else {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var total = 0
                while total < data.count {
                    let written = Darwin.send(fd, base.advanced(by: total), data.count - total, 0)
                    if written > 0 { total += written; continue }
                    if written < 0 && errno == EINTR { continue }
                    throw ChannelError.ioFailed(String(cString: strerror(errno)))
                }
            }
        }
    }

    /// Ontvangt exact `count` bytes of gooit `.endOfStream`.
    func receive(exactly count: Int) async throws -> Data {
        try await onQueue { try self.blockingReceive(exactly: count) }
    }

    private func blockingReceive(exactly count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        guard fd >= 0 else { throw ChannelError.notConnected }

        var buffer = Data(count: count)
        var total = 0
        try buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while total < count {
                if let context = sslContext {
                    var processed = 0
                    let status = SSLRead(context, base.advanced(by: total), count - total, &processed)
                    total += processed
                    if status == errSSLWouldBlock { continue }
                    if status == errSSLClosedGraceful || (status == errSecSuccess && processed == 0) { break }
                    guard status == errSecSuccess else { throw ChannelError.ioFailed("SSLRead \(status)") }
                } else {
                    let read = Darwin.recv(fd, base.advanced(by: total), count - total, 0)
                    if read > 0 { total += read; continue }
                    if read == 0 { break } // EOF
                    if errno == EINTR { continue }
                    throw ChannelError.ioFailed(String(cString: strerror(errno)))
                }
            }
        }
        guard total == count else { throw ChannelError.endOfStream }
        return buffer
    }

    // MARK: - Sluiten

    func close() {
        queue.sync {
            if let context = sslContext {
                SSLClose(context)
                sslContext = nil
            }
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
        }
    }
}

// MARK: - Secure Transport I/O-callbacks (bestandsniveau, C-compatibel)

/// Leest van de fd die als connection-pointer is meegegeven.
private func socketChannelSSLRead(_ connection: SSLConnectionRef,
                                  _ data: UnsafeMutableRawPointer,
                                  _ dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let fd = Int32(Int(bitPattern: connection))
    let requested = dataLength.pointee
    var total = 0
    while total < requested {
        let read = Darwin.recv(fd, data.advanced(by: total), requested - total, 0)
        if read > 0 { total += read; continue }
        if read == 0 { dataLength.pointee = total; return errSSLClosedGraceful }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK { dataLength.pointee = total; return errSSLWouldBlock }
        dataLength.pointee = total
        return errSSLClosedAbort
    }
    dataLength.pointee = total
    return errSecSuccess
}

/// Schrijft naar de fd die als connection-pointer is meegegeven.
private func socketChannelSSLWrite(_ connection: SSLConnectionRef,
                                   _ data: UnsafeRawPointer,
                                   _ dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
    let fd = Int32(Int(bitPattern: connection))
    let requested = dataLength.pointee
    var total = 0
    while total < requested {
        let written = Darwin.send(fd, data.advanced(by: total), requested - total, 0)
        if written > 0 { total += written; continue }
        if written == 0 { dataLength.pointee = total; return errSSLClosedGraceful }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK { dataLength.pointee = total; return errSSLWouldBlock }
        dataLength.pointee = total
        return errSSLClosedAbort
    }
    dataLength.pointee = total
    return errSecSuccess
}
