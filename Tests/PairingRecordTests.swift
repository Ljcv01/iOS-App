//
//  PairingRecordTests.swift
//  Tests
//
//  Verifieert de PEM/DER-helper en de pairing-record-parser. Er komt geen echte
//  crypto of keychain aan te pas: we bouwen een plist met bekende velden en
//  controleren of de parser ze correct terugleest.
//

import Testing
import Foundation
@testable import Services

struct PairingRecordTests {

    // "DER"-bytes zijn hier willekeurige binaire testdata.
    private let deviceDER = Data([0x30, 0x82, 0x01, 0x0A, 0xDE, 0xAD, 0xBE, 0xEF])
    private let hostDER = Data([0x30, 0x82, 0x02, 0x20, 0x01, 0x02, 0x03, 0x04])
    private let keyDER = Data([0x30, 0x82, 0x04, 0xA4, 0x05, 0x06, 0x07, 0x08])

    private func pem(_ label: String, _ der: Data) -> Data {
        let body = der.base64EncodedString()
        let text = "-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----\n"
        return Data(text.utf8)
    }

    private func makePlistData(pemEncoded: Bool) throws -> Data {
        let dictionary: [String: Any] = [
            "HostID": "AABBCCDD-1122-3344-5566-77889900AABB",
            "SystemBUID": "11112222-3333-4444-5555-666677778888",
            "HostCertificate": pemEncoded ? pem("CERTIFICATE", hostDER) : hostDER,
            "HostPrivateKey": pemEncoded ? pem("RSA PRIVATE KEY", keyDER) : keyDER,
            "DeviceCertificate": pemEncoded ? pem("CERTIFICATE", deviceDER) : deviceDER,
            "WiFiMACAddress": "aa:bb:cc:dd:ee:ff"
        ]
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    @Test func pemDecodeStripsMarkersAndDecodesBase64() throws {
        let der = Data([0x00, 0x01, 0x02, 0xFF, 0xFE])
        let text = "-----BEGIN CERTIFICATE-----\n\(der.base64EncodedString())\n-----END CERTIFICATE-----"
        #expect(PEM.decode(text) == der)
    }

    @Test func normalizeAcceptsRawDER() {
        let der = Data([0x30, 0x03, 0x02, 0x01, 0x00])
        #expect(PEM.normalizeToDER(der) == der)
    }

    @Test func parsesPEMEncodedRecord() throws {
        let record = try PairingRecord(data: makePlistData(pemEncoded: true))
        #expect(record.hostID == "AABBCCDD-1122-3344-5566-77889900AABB")
        #expect(record.systemBUID == "11112222-3333-4444-5555-666677778888")
        #expect(record.hostCertificateDER == hostDER)
        #expect(record.hostPrivateKeyDER == keyDER)
        #expect(record.deviceCertificateDER == deviceDER)
        #expect(record.wifiMACAddress == "aa:bb:cc:dd:ee:ff")
    }

    @Test func parsesRawDERRecord() throws {
        let record = try PairingRecord(data: makePlistData(pemEncoded: false))
        #expect(record.hostCertificateDER == hostDER)
        #expect(record.deviceCertificateDER == deviceDER)
    }

    @Test func missingFieldThrows() throws {
        let dictionary: [String: Any] = ["HostID": "only-host-id"]
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        #expect(throws: PairingRecord.ParseError.self) {
            _ = try PairingRecord(data: data)
        }
    }
}
