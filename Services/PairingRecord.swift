//
//  PairingRecord.swift
//  Services
//
//  Parser voor een MobileDevice pairing record (.plist / .bplist). De record
//  bevat de host-credentials waarmee lockdownd een sessie naar TLS upgradet:
//  HostID, SystemBUID, het host-certificaat + de bijbehorende private key, en
//  het device-certificaat waarop we de TLS-verbinding pinnen.
//
//  PropertyListSerialization leest zowel XML- als binaire plists.
//

import Foundation
import Security

struct PairingRecord: Sendable {

    enum ParseError: LocalizedError {
        case invalidPlist
        case missingField(String)
        case invalidCertificateOrKey(String)

        var errorDescription: String? {
            switch self {
            case .invalidPlist:
                return "Het pairing-bestand is geen geldige property list."
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
        guard let plist = try PropertyListSerialization.propertyList(from: data,
                                                                     options: [],
                                                                     format: nil) as? [String: Any] else {
            throw ParseError.invalidPlist
        }

        hostID = try Self.string(plist, "HostID")
        systemBUID = try Self.string(plist, "SystemBUID")
        hostCertificateDER = try Self.der(plist, "HostCertificate")
        hostPrivateKeyDER = try Self.der(plist, "HostPrivateKey")
        deviceCertificateDER = try Self.der(plist, "DeviceCertificate")
        rootCertificateDER = try? Self.der(plist, "RootCertificate")
        escrowBag = plist["EscrowBag"] as? Data
        wifiMACAddress = plist["WiFiMACAddress"] as? String
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

    // MARK: - Crypto-objecten

    /// Het device-certificaat als `SecCertificate`, gebruikt om de TLS-peer op
    /// te pinnen.
    func makeDeviceCertificate() throws -> SecCertificate {
        guard let certificate = SecCertificateCreateWithData(nil, deviceCertificateDER as CFData) else {
            throw ParseError.invalidCertificateOrKey("DeviceCertificate")
        }
        return certificate
    }

    /// Bouwt de client-`SecIdentity` (host-certificaat + private key) die we als
    /// client-certificaat aan de TLS-handshake meegeven.
    ///
    /// iOS kent geen directe `SecIdentityCreate`; de ondersteunde route is beide
    /// delen in de keychain zetten en de identity die de keychain daaruit vormt
    /// weer opvragen. We labelen de items met de HostID zodat we ze kunnen
    /// terugvinden en opruimen.
    func makeClientIdentity() throws -> SecIdentity {
        let tag = "com.example.iOSApp.pairing.\(hostID)"

        guard let certificate = SecCertificateCreateWithData(nil, hostCertificateDER as CFData) else {
            throw ParseError.invalidCertificateOrKey("HostCertificate")
        }

        var keyError: Unmanaged<CFError>?
        let keyAttributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ]
        guard let privateKey = SecKeyCreateWithData(hostPrivateKeyDER as CFData,
                                                    keyAttributes as CFDictionary,
                                                    &keyError) else {
            throw ParseError.invalidCertificateOrKey("HostPrivateKey")
        }

        try Self.addToKeychain(certificate: certificate, tag: tag)
        try Self.addToKeychain(privateKey: privateKey, tag: tag)

        // De keychain koppelt cert en key tot een identity; haal die op door de
        // identity te zoeken waarvan het certificaat overeenkomt.
        guard let identity = try Self.findIdentity(matching: hostCertificateDER) else {
            throw ParseError.invalidCertificateOrKey("SecIdentity")
        }
        return identity
    }

    /// Verwijdert de tijdens `makeClientIdentity()` toegevoegde keychain-items.
    func removeIdentityFromKeychain() {
        let tag = "com.example.iOSApp.pairing.\(hostID)"
        let keyQuery: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Data(tag.utf8)
        ]
        SecItemDelete(keyQuery as CFDictionary)

        let certQuery: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: tag
        ]
        SecItemDelete(certQuery as CFDictionary)
    }

    // MARK: - Keychain-helpers

    private static func addToKeychain(certificate: SecCertificate, tag: String) throws {
        // Certificaten kennen geen kSecAttrApplicationTag; we labelen ze met kSecAttrLabel.
        let query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecValueRef: certificate,
            kSecAttrLabel: tag
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw ParseError.invalidCertificateOrKey("HostCertificate (keychain \(status))")
        }
    }

    private static func addToKeychain(privateKey: SecKey, tag: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecValueRef: privateKey,
            kSecAttrApplicationTag: Data(tag.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw ParseError.invalidCertificateOrKey("HostPrivateKey (keychain \(status))")
        }
    }

    private static func findIdentity(matching certificateDER: Data) throws -> SecIdentity? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let identities = result as? [SecIdentity] else {
            return nil
        }

        for identity in identities {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate else { continue }
            if (SecCertificateCopyData(certificate) as Data) == certificateDER {
                return identity
            }
        }
        return nil
    }
}
