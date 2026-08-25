//
//  IPv4PacketTests.swift
//  Tests
//
//  Verifieert de pakketverwerking zonder dat er een tunnel of netwerk aan te pas komt.
//

import Testing
import Foundation
@testable import PacketTunnel

struct IPv4PacketTests {

    /// Bouwt een geldige ICMP echo request van 198.18.0.1 naar 1.1.1.1.
    private func makeEchoRequest(payload: [UInt8] = Array(0..<32)) -> Data {
        var icmp: [UInt8] = [8, 0, 0, 0, 0x12, 0x34, 0x00, 0x01] + payload
        let icmpChecksum = IPv4Packet.checksum(icmp)
        icmp[2] = UInt8(truncatingIfNeeded: icmpChecksum >> 8)
        icmp[3] = UInt8(truncatingIfNeeded: icmpChecksum)

        let totalLength = 20 + icmp.count
        var header: [UInt8] = [
            0x45, 0x00,
            UInt8(truncatingIfNeeded: totalLength >> 8), UInt8(truncatingIfNeeded: totalLength),
            0xAB, 0xCD,
            0x00, 0x00,
            64, 1,
            0, 0,
            198, 18, 0, 1,
            1, 1, 1, 1
        ]
        let headerChecksum = IPv4Packet.checksum(header)
        header[10] = UInt8(truncatingIfNeeded: headerChecksum >> 8)
        header[11] = UInt8(truncatingIfNeeded: headerChecksum)

        return Data(header + icmp)
    }

    @Test func checksumOfValidPacketIsZero() {
        let packet = [UInt8](makeEchoRequest())
        #expect(IPv4Packet.checksum(packet[0..<20]) == 0)
        #expect(IPv4Packet.checksum(packet[20...]) == 0)
    }

    @Test func echoReplySwapsAddressesAndKeepsPayload() throws {
        let request = makeEchoRequest()
        let reply = try #require(IPv4Packet.makeEchoReply(from: request))
        let bytes = [UInt8](reply)

        #expect(bytes.count == request.count)
        #expect(Array(bytes[12..<16]) == [1, 1, 1, 1])
        #expect(Array(bytes[16..<20]) == [198, 18, 0, 1])
        #expect(bytes[20] == 0)                                   // type: echo reply
        #expect(Array(bytes[24..<28]) == [0x12, 0x34, 0x00, 0x01]) // id en sequence blijven staan
        #expect(Array(bytes[28...]) == Array(0..<32))              // payload blijft staan
        #expect(bytes[8] == 64)                                    // TTL gereset
        #expect(IPv4Packet.checksum(bytes[0..<20]) == 0)
        #expect(IPv4Packet.checksum(bytes[20...]) == 0)
    }

    @Test func paddingBeyondTotalLengthIsTrimmed() throws {
        let request = makeEchoRequest()
        let padded = request + Data([0, 0, 0])
        let reply = try #require(IPv4Packet.makeEchoReply(from: padded))
        #expect(reply.count == request.count)
    }

    @Test func nonICMPPacketIsRejected() {
        var bytes = [UInt8](makeEchoRequest())
        bytes[9] = 17 // UDP
        #expect(IPv4Packet.makeEchoReply(from: Data(bytes)) == nil)
    }

    @Test func fragmentIsRejected() {
        var bytes = [UInt8](makeEchoRequest())
        bytes[6] = 0x20 // More Fragments
        #expect(IPv4Packet.makeEchoReply(from: Data(bytes)) == nil)
    }

    @Test func truncatedPacketIsRejected() {
        let request = makeEchoRequest()
        #expect(IPv4Packet.makeEchoReply(from: request.prefix(12)) == nil)
    }
}
