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
        static let tunnelRemoteAddress = "tunnelRemoteAddress"
        static let localAddress = "localAddress"
        static let subnetMask = "subnetMask"
        static let mtu = "mtu"
        static let capturesDNS = "capturesDNS"
        static let dnsServers = "dnsServers"
        static let respondsToICMPEcho = "respondsToICMPEcho"
    }

    /// Het "remote" eindpunt van de virtuele interface. Loopback, omdat er
    /// bewust geen enkel extern netwerkverzoek wordt gedaan.
    var tunnelRemoteAddress: String = "127.0.0.1"

    /// Het IPv4-adres dat de virtuele utun-interface op het toestel krijgt.
    /// 198.18.0.0/15 is door RFC 2544 gereserveerd voor benchmarking en botst
    /// daarom in de praktijk nooit met een echt netwerk van de gebruiker.
    /// (127.0.0.0/8 kan hier niet gebruikt worden: iOS weigert een loopback-adres
    /// als adres van een utun-interface.)
    var localAddress: String = "198.18.0.1"

    var subnetMask: String = "255.255.255.0"

    var mtu: Int = 1500

    /// Vangt ook DNS-verkeer af. Omdat er geen resolver in de tunnel draait,
    /// mislukken DNS-lookups zolang de tunnel actief is — dat is het bedoelde
    /// gedrag van een volledig lokale sink. Zet op `false` om DNS ongemoeid te laten.
    var capturesDNS: Bool = true

    var dnsServers: [String] = ["198.18.0.1"]

    /// Beantwoordt ICMP echo requests (ping) lokaal in de extensie, zodat je
    /// zichtbaar kunt aantonen dat het verkeer de tunnel in gaat en er weer
    /// uit komt, zonder dat er ook maar één byte het toestel verlaat.
    var respondsToICMPEcho: Bool = true

    static let `default` = TunnelConfiguration()

    init() {}

    /// Leest de configuratie uit `providerConfiguration`. Onbekende of verkeerd
    /// getypeerde waarden worden genegeerd in plaats van dat ze de tunnel slopen.
    init(providerConfiguration: [String: Any]?) {
        self.init()
        guard let configuration = providerConfiguration else { return }

        if let value = configuration[Key.tunnelRemoteAddress] as? String, !value.isEmpty {
            tunnelRemoteAddress = value
        }
        if let value = configuration[Key.localAddress] as? String, !value.isEmpty {
            localAddress = value
        }
        if let value = configuration[Key.subnetMask] as? String, !value.isEmpty {
            subnetMask = value
        }
        if let value = configuration[Key.mtu] as? NSNumber {
            mtu = min(max(value.intValue, 576), 9000)
        }
        if let value = configuration[Key.capturesDNS] as? NSNumber {
            capturesDNS = value.boolValue
        }
        if let value = configuration[Key.dnsServers] as? [String], !value.isEmpty {
            dnsServers = value
        }
        if let value = configuration[Key.respondsToICMPEcho] as? NSNumber {
            respondsToICMPEcho = value.boolValue
        }
    }

    /// Property-list-veilige representatie voor `providerConfiguration`.
    var dictionaryRepresentation: [String: Any] {
        [
            Key.tunnelRemoteAddress: tunnelRemoteAddress,
            Key.localAddress: localAddress,
            Key.subnetMask: subnetMask,
            Key.mtu: NSNumber(value: mtu),
            Key.capturesDNS: NSNumber(value: capturesDNS),
            Key.dnsServers: dnsServers,
            Key.respondsToICMPEcho: NSNumber(value: respondsToICMPEcho)
        ]
    }
}
