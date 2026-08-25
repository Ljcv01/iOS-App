//
//  IPv4Packet.swift
//  PacketTunnel
//
//  Kleine, pure helper voor het inspecteren van IPv4-pakketten en het lokaal
//  opbouwen van een ICMP echo reply. Bevat geen enkele netwerk-API en doet
//  dus per definitie geen externe verzoeken.
//

import Foundation

enum IPv4Packet {

    static let minimumHeaderLength = 20

    enum Proto: UInt8 {
        case icmp = 1
        case tcp = 6
        case udp = 17
    }

    /// Lengte van de IPv4-header in bytes, of `nil` als het pakket geen geldig
    /// IPv4-pakket is.
    static func headerLength(of packet: Data) -> Int? {
        guard packet.count >= minimumHeaderLength else { return nil }
        let firstByte = packet[packet.startIndex]
        guard firstByte >> 4 == 4 else { return nil }
        let length = Int(firstByte & 0x0F) * 4
        guard length >= minimumHeaderLength, length <= packet.count else { return nil }
        return length
    }

    static func protocolNumber(of packet: Data) -> UInt8? {
        guard packet.count >= minimumHeaderLength else { return nil }
        return packet[packet.startIndex + 9]
    }

    /// Bouwt een ICMP echo reply op basis van een echo request.
    ///
    /// Bron- en bestemmingsadres worden omgedraaid, het ICMP-type wordt 0 en
    /// beide checksums worden opnieuw berekend. Het antwoord wordt rechtstreeks
    /// terug de tunnel in geschreven; er gaat niets naar buiten.
    ///
    /// Geeft `nil` terug als het pakket geen bruikbare echo request is.
    static func makeEchoReply(from packet: Data) -> Data? {
        guard let headerLength = headerLength(of: packet),
              protocolNumber(of: packet) == Proto.icmp.rawValue else {
            return nil
        }

        var bytes = [UInt8](packet)

        // Het pakket mag niet korter zijn dan header + minimale ICMP-header.
        guard bytes.count >= headerLength + 8 else { return nil }

        // Total Length uit de IP-header; eventuele padding erachter knippen we weg.
        let totalLength = Int(bytes[2]) << 8 | Int(bytes[3])
        guard totalLength >= headerLength + 8, totalLength <= bytes.count else { return nil }
        if bytes.count > totalLength {
            bytes.removeSubrange(totalLength...)
        }

        // Fragmenten kunnen we niet zinvol beantwoorden: MF-bit of fragment offset gezet.
        let flagsAndOffset = Int(bytes[6]) << 8 | Int(bytes[7])
        guard flagsAndOffset & 0x3FFF == 0 else { return nil }

        // Type 8 / code 0 == echo request.
        guard bytes[headerLength] == 8, bytes[headerLength + 1] == 0 else { return nil }

        // Bron en bestemming omdraaien.
        for offset in 0..<4 {
            bytes.swapAt(12 + offset, 16 + offset)
        }

        // ICMP: type 0 (echo reply), checksum opnieuw berekenen.
        bytes[headerLength] = 0
        bytes[headerLength + 2] = 0
        bytes[headerLength + 3] = 0
        let icmpChecksum = checksum(bytes[headerLength...])
        bytes[headerLength + 2] = UInt8(truncatingIfNeeded: icmpChecksum >> 8)
        bytes[headerLength + 3] = UInt8(truncatingIfNeeded: icmpChecksum)

        // IP-header: TTL resetten en header-checksum opnieuw berekenen.
        bytes[8] = 64
        bytes[10] = 0
        bytes[11] = 0
        let headerChecksum = checksum(bytes[0..<headerLength])
        bytes[10] = UInt8(truncatingIfNeeded: headerChecksum >> 8)
        bytes[11] = UInt8(truncatingIfNeeded: headerChecksum)

        return Data(bytes)
    }

    /// Standaard internet-checksum (RFC 1071): 16-bits one's complement sum,
    /// daarna geïnverteerd.
    static func checksum<Bytes: Collection>(_ bytes: Bytes) -> UInt16 where Bytes.Element == UInt8 {
        var sum: UInt32 = 0
        var high: UInt8?

        for byte in bytes {
            if let pending = high {
                sum &+= UInt32(pending) << 8 | UInt32(byte)
                high = nil
            } else {
                high = byte
            }
        }
        if let pending = high {
            sum &+= UInt32(pending) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) &+ (sum >> 16)
        }
        return ~UInt16(truncatingIfNeeded: sum)
    }
}
