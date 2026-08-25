//
//  PacketRelay.swift
//  PacketTunnel
//
//  Leest pakketten van de virtuele interface en verwerkt ze volledig lokaal.
//  Er wordt nooit een socket geopend en er gaat nooit iets naar buiten.
//
//  De relay is een los, thread-safe object (en dus `Sendable`), zodat de
//  provider zelf geen `self` hoeft mee te geven aan escaping closures. Dat
//  houdt de code schoon onder strict concurrency van Swift 6.
//

import Foundation
import NetworkExtension
import os

final class PacketRelay: @unchecked Sendable {

    private let packetFlow: NEPacketTunnelFlow
    private let configuration: TunnelConfiguration
    private let logger: Logger

    private let lock = NSLock()
    private var isRunning = false
    private var stats = TunnelStatistics()

    init(packetFlow: NEPacketTunnelFlow, configuration: TunnelConfiguration) {
        self.packetFlow = packetFlow
        self.configuration = configuration
        self.logger = Logger(subsystem: TunnelConstants.loggingSubsystem, category: "PacketRelay")
    }

    // MARK: - Levenscyclus

    func start() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !isRunning else { return false }
            isRunning = true
            stats = TunnelStatistics()
            stats.startedAt = Date()
            return true
        }
        guard shouldStart else { return }

        logger.log("Packet relay gestart; al het IPv4-verkeer wordt lokaal afgehandeld.")
        scheduleRead()
    }

    func stop() {
        lock.withLock { isRunning = false }
        logger.log("Packet relay gestopt.")
    }

    var statistics: TunnelStatistics {
        lock.withLock { stats }
    }

    func resetStatistics() {
        lock.withLock {
            let startedAt = stats.startedAt
            stats = TunnelStatistics()
            stats.startedAt = startedAt
        }
    }

    private var isActive: Bool {
        lock.withLock { isRunning }
    }

    // MARK: - Leeslus

    /// `readPackets` levert precies één batch per aanroep, dus na elke batch
    /// plannen we de volgende leesactie. De closure vangt alleen `self` (een
    /// `Sendable` type), niet de provider.
    private func scheduleRead() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, self.isActive else { return }
            self.handle(packets: packets, protocols: protocols)
            self.scheduleRead()
        }
    }

    private func handle(packets: [Data], protocols: [NSNumber]) {
        var replies: [Data] = []
        var replyProtocols: [NSNumber] = []

        var readCount = 0
        var readBytes = 0
        var dropped = 0

        for (index, packet) in packets.enumerated() {
            readCount += 1
            readBytes += packet.count

            let family = index < protocols.count ? protocols[index].int32Value : AF_INET
            guard family == AF_INET else {
                // Alleen IPv4 wordt afgehandeld; IPv6 staat in de netwerkinstellingen uit.
                dropped += 1
                continue
            }

            if configuration.respondsToICMPEcho,
               let reply = IPv4Packet.makeEchoReply(from: packet) {
                replies.append(reply)
                replyProtocols.append(NSNumber(value: AF_INET))
            } else {
                // Alle overige pakketten eindigen hier: de tunnel is een sink.
                dropped += 1
            }
        }

        let writtenBytes = replies.reduce(0) { $0 + $1.count }
        if !replies.isEmpty {
            packetFlow.writePackets(replies, withProtocols: replyProtocols)
        }

        lock.withLock {
            stats.packetsRead += readCount
            stats.bytesRead += readBytes
            stats.packetsDropped += dropped
            stats.packetsWritten += replies.count
            stats.bytesWritten += writtenBytes
            stats.icmpEchoRepliesSent += replies.count
        }
    }
}
