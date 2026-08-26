//
//  TunnelConfiguration.swift
//  Gedeeld tussen de app en de Packet Tunnel Provider extensie.
//
//  De app schrijft deze waarden in `NETunnelProviderProtocol.providerConfiguration`,
//  de extensie leest ze daar weer uit. Alles is optioneel: ontbrekende sleutels
//  vallen terug op de defaults hieronder.
//

import Foundation

struct TunnelConfiguration: Equatable, Sendable {

    enum Key {
        static let deviceAddress = "deviceAddress"
        static let peerAddress = "peerAddress"
        static let subnetMask = "subnetMask"
        static let mtu = "mtu"
    }

    /// Adres van de virtuele interface op het toestel.
    var deviceAddress: String = TunnelConstants.deviceAddress

    /// Adres waar de app naartoe verbindt; wordt teruggekaatst naar `deviceAddress`.
    var peerAddress: String = TunnelConstants.peerAddress

    var subnetMask: String = TunnelConstants.subnetMask

    /// 1500 is bewust behouden: de tunnel draagt alleen lokaal verkeer en er
    /// wordt niets gefragmenteerd richting een echt netwerk.
    var mtu: Int = 1500

    static let `default` = TunnelConfiguration()

    init() {}

    /// Leest de configuratie uit `providerConfiguration`. Onbekende of verkeerd
    /// getypeerde waarden worden genegeerd in plaats van dat ze de tunnel slopen.
    init(providerConfiguration: [String: Any]?) {
        self.init()
        guard let configuration = providerConfiguration else { return }

        if let value = configuration[Key.deviceAddress] as? String, !value.isEmpty {
            deviceAddress = value
        }
        if let value = configuration[Key.peerAddress] as? String, !value.isEmpty {
            peerAddress = value
        }
        if let value = configuration[Key.subnetMask] as? String, !value.isEmpty {
            subnetMask = value
        }
        if let value = configuration[Key.mtu] as? NSNumber {
            mtu = min(max(value.intValue, 576), 9000)
        }
    }

    /// Property-list-veilige representatie voor `providerConfiguration`.
    var dictionaryRepresentation: [String: Any] {
        [
            Key.deviceAddress: deviceAddress,
            Key.peerAddress: peerAddress,
            Key.subnetMask: subnetMask,
            Key.mtu: NSNumber(value: mtu)
        ]
    }
}
