//
//  LocationSimulatorEncodingTests.swift
//  Tests
//
//  Verifieert de codering van het simulatelocation-wire-formaat en de
//  big-endian double-helper. De tests draaien puur op geheugen; er komt geen
//  socket of tunnel aan te pas.
//
//  De coderingsfuncties in LocationSimulatorService zijn `private`; deze tests
//  bevatten daarom een 1-op-1 referentie-implementatie en controleren daarnaast
//  de publieke `Double.bigEndianBytes`-helper.
//

import Testing
import Foundation
@testable import Services

struct LocationSimulatorEncodingTests {

    private func uint32BE(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
         UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private func encodeSetLocation(latitude: Double, longitude: Double) -> [UInt8] {
        var bytes = uint32BE(0) // command: set
        for coordinate in [String(latitude), String(longitude)] {
            let ascii = Array(coordinate.utf8)
            bytes += uint32BE(UInt32(ascii.count))
            bytes += ascii
        }
        return bytes
    }

    @Test func setLocationPayloadRoundTrips() throws {
        let latitude = 37.7749
        let longitude = -122.4194
        let bytes = encodeSetLocation(latitude: latitude, longitude: longitude)

        // Commandowoord 0.
        #expect(Array(bytes[0..<4]) == [0, 0, 0, 0])

        var offset = 4
        func readString() throws -> String {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                       | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            let slice = Array(bytes[offset..<offset + length])
            offset += length
            return try #require(String(bytes: slice, encoding: .ascii))
        }

        let decodedLatitude = try readString()
        let decodedLongitude = try readString()
        #expect(offset == bytes.count)
        #expect(Double(decodedLatitude) == latitude)
        #expect(Double(decodedLongitude) == longitude)
    }

    @Test func bigEndianDoubleHelperMatchesIEEE754() {
        let value = 37.7749
        let bytes = [UInt8](value.bigEndianBytes)
        #expect(bytes.count == 8)

        // Big-endian bitpattern handmatig terugbouwen.
        var bitPattern: UInt64 = 0
        for byte in bytes {
            bitPattern = (bitPattern << 8) | UInt64(byte)
        }
        #expect(Double(bitPattern: bitPattern) == value)
        // Bekende referentiewaarde uit struct.pack(">d", 37.7749).
        #expect(bytes == [0x40, 0x42, 0xe3, 0x2f, 0xec, 0x56, 0xd5, 0xd0])
    }

    @Test func stopCommandIsFourBigEndianBytes() {
        let stop: UInt32 = 1
        let bytes = uint32BE(stop)
        #expect(bytes == [0, 0, 0, 1])
    }
}
