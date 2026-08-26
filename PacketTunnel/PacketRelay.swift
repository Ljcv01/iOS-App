//
//  PacketRelay.swift
//  PacketTunnel
//
//  Kaatst IPv4-verkeer terug naar het toestel zelf (een NAT-hairpin), zodat de
//  app de systeemservices van het toestel kan bereiken via een adres dat er
//  voor iOS uitziet als een externe host in hetzelfde subnet.
//
//      app  ──▶  dst = 10.7.0.1 (peer)        src = 10.7.0.0 (device)
//      relay ──▶ dst = 10.7.0.0 (device)      src = 10.7.0.1 (peer)
//      → het pakket komt binnen op de eigen interface, ogenschijnlijk van een
//        andere host, en de developer-services accepteren de verbinding.
//
//  Dit is dezelfde techniek als StosVPN / LocalDevVPN, de tunnels waar
//  StikDebug en SideStore op draaien.
//
//  Er wordt bewust GEEN checksum herberekend. Dat klinkt fout, maar de
//  bewezen implementaties doen het ook niet: op een utun-interface worden de
//  IP/TCP-checksums van geïnjecteerde pakketten niet gevalideerd. Ga hier niet
//  "verbeteren" — checksums bijwerken zonder de TCP-pseudoheader mee te nemen
//  breekt de verbinding juist.
//

import Foundation
import NetworkExtension
import os

final class PacketRelay: @unchecked Sendable {

    private let packetFlow: NEPacketTunnelFlow
    private let deviceAddress: UInt32
    private let peerAddress: UInt32
    private let logger: Logger

    private let lock = NSLock()
    private var isRunning = false
    private var stats = TunnelStatistics()

    init(packetFlow: NEPacketTunnelFlow, configuration: TunnelConfiguration) {
        self.packetFlow = packetFlow
        self.deviceAddress = Self.ipv4Value(configuration.deviceAddress)
        self.peerAddress = Self.ipv4Value(configuration.peerAddress)
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

        logger.log("Packet relay gestart (hairpin actief).")
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
        let device = deviceAddress
        let peer = peerAddress

        var rewritten = packets
        var bytes = 0
        var translated = 0

        for index in rewritten.indices {
            bytes += rewritten[index].count

            guard index < protocols.count,
                  protocols[index].int32Value == AF_INET,
                  rewritten[index].count >= 20 else {
                continue
            }

            // Bron staat op byte 12..15, bestemming op 16..19 — ook als de
            // header opties bevat (IHL > 5).
            let didTranslate = rewritten[index].withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                let words = base.assumingMemoryBound(to: UInt32.self)
                var changed = false
                if UInt32(bigEndian: words[3]) == device {
                    words[3] = peer.bigEndian
                    changed = true
                }
                if UInt32(bigEndian: words[4]) == peer {
                    words[4] = device.bigEndian
                    changed = true
                }
                return changed
            }
            if didTranslate { translated += 1 }
        }

        packetFlow.writePackets(rewritten, withProtocols: protocols)

        lock.withLock {
            stats.packetsRead += packets.count
            stats.bytesRead += bytes
            stats.packetsWritten += rewritten.count
            stats.bytesWritten += bytes
            stats.packetsTranslated += translated
        }
    }

    // MARK: - Helpers

    /// Zet een dotted-quad om naar een host-order `UInt32`. Geeft 0 terug bij
    /// een ongeldig adres, wat simpelweg betekent dat er niets matcht.
    static func ipv4Value(_ address: String) -> UInt32 {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return 0 }
        var value: UInt32 = 0
        for part in parts {
            guard let byte = UInt8(part) else { return 0 }
            value = (value << 8) | UInt32(byte)
        }
        return value
    }
}
