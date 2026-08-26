//
//  PairingRecord.swift
//  Services
//
//  Leest een MobileDevice pairing record (.plist / .bplist) in om hem te
//  VALIDEREN en samen te vatten voor de UI.
//
//  De echte handshake doet `idevice` zelf (`rp_pairing_file_from_bytes`); we
//  parsen hier alleen zodat een kapot of verkeerd bestand meteen bij het
//  importeren opvalt, in plaats van pas als de tunnel faalt.
//
//  PropertyListSerialization leest zowel XML- als binaire plists.
//

import Foundation

struct PairingRecord: Sendable {

    enum ParseError: LocalizedError {
        case invalidPlist
        case missingField(String)
        case invalidCertificateOrKey(String)

        var errorDescription: String? {
            switch self {
            case .invalidPlist:
                return "Dit is geen geldige property list. Kies het pairing-bestand dat je via de pc hebt gemaakt."
            case .missingField(let field):
                return "Ontbrekend veld in de pairing record: \(field)."
            case .invalidCertificateOrKey(let field):
                return "Kon '\(field)' niet als certificaat/sleutel inlezen."
            }
        }
    }

    let hostID: String
    let systemBUID: String
    let hostCertificateDER: Data
    let hostPrivateKeyDER: Data
    let deviceCertificateDER: Data
    let rootCertificateDER: Data?
    let escrowBag: Data?
    let wifiMACAddress: String?

    // MARK: - Inlezen

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    init(data: Data) throws {
        guard let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                      options: [],
                                                                      format: nil),
              let dictionary = plist as? [String: Any] else {
            throw ParseError.invalidPlist
        }

        hostID = try Self.string(dictionary, "HostID")
        systemBUID = try Self.string(dictionary, "SystemBUID")
        hostCertificateDER = try Self.der(dictionary, "HostCertificate")
        hostPrivateKeyDER = try Self.der(dictionary, "HostPrivateKey")
        deviceCertificateDER = try Self.der(dictionary, "DeviceCertificate")
        rootCertificateDER = try? Self.der(dictionary, "RootCertificate")
        escrowBag = dictionary["EscrowBag"] as? Data
        wifiMACAddress = dictionary["WiFiMACAddress"] as? String
    }

    private static func string(_ plist: [String: Any], _ key: String) throws -> String {
        guard let value = plist[key] as? String, !value.isEmpty else {
            throw ParseError.missingField(key)
        }
        return value
    }

    /// Leest een veld en normaliseert het (PEM of ruwe DER) naar DER.
    private static func der(_ plist: [String: Any], _ key: String) throws -> Data {
        let raw: Data
        if let data = plist[key] as? Data {
            raw = data
        } else if let text = plist[key] as? String, let utf8 = text.data(using: .utf8) {
            raw = utf8
        } else {
            throw ParseError.missingField(key)
        }
        guard let der = PEM.normalizeToDER(raw) else {
            throw ParseError.invalidCertificateOrKey(key)
        }
        return der
    }
}
