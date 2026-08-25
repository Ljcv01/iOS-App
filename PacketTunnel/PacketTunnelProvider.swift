//
//  PacketTunnelProvider.swift
//  PacketTunnel
//
//  Volledig lokale NEPacketTunnelProvider. Er wordt een virtuele IPv4-interface
//  (utun) opgezet met een default route, zodat al het IPv4-verkeer van het
//  toestel de tunnel in wordt gestuurd. Het remote adres van de tunnel is
//  127.0.0.1: er wordt geen enkele verbinding met een server opgezet en er
//  verlaat geen byte het toestel.
//

import Foundation
import NetworkExtension
import os

final class PacketTunnelProvider: NEPacketTunnelProvider {

    /// Thread-safe houder voor de relay. Zo hoeft er in geen enkele escaping
    /// closure `self` gevangen te worden.
    private final class RelayBox: @unchecked Sendable {
        private let lock = NSLock()
        private var relay: PacketRelay?

        var current: PacketRelay? {
            lock.withLock { relay }
        }

        func store(_ newValue: PacketRelay?) {
            lock.withLock { relay = newValue }
        }

        func take() -> PacketRelay? {
            lock.withLock { () -> PacketRelay? in
                let existing = relay
                relay = nil
                return existing
            }
        }
    }

    private let relayBox = RelayBox()
    private let logger = Logger(subsystem: TunnelConstants.loggingSubsystem, category: "PacketTunnelProvider")

    // MARK: - Starten

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let configuration = TunnelConfiguration(providerConfiguration: providerConfiguration)
        let settings = Self.makeNetworkSettings(for: configuration)

        logger.log("""
            Tunnel starten: lokaal adres \(configuration.localAddress, privacy: .public), \
            remote \(configuration.tunnelRemoteAddress, privacy: .public), \
            MTU \(configuration.mtu, privacy: .public)
            """)

        // De relay wordt vóór het instellen van de netwerkinstellingen gemaakt,
        // zodat de completion handler alleen `Sendable` waarden hoeft te vangen.
        let relay = PacketRelay(packetFlow: packetFlow, configuration: configuration)
        relayBox.store(relay)

        setTunnelNetworkSettings(settings) { error in
            if let error {
                relay.stop()
                completionHandler(error)
                return
            }
            relay.start()
            completionHandler(nil)
        }
    }

    // MARK: - Stoppen

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        logger.log("Tunnel stoppen, reden: \(reason.rawValue, privacy: .public)")
        relayBox.take()?.stop()

        // Netwerkinstellingen opruimen zodat de utun-interface direct verdwijnt.
        setTunnelNetworkSettings(nil) { _ in
            completionHandler()
        }
    }

    // MARK: - Berichten vanuit de app

    override func handleAppMessage(_ messageData: Data,
                                   completionHandler: ((Data?) -> Void)?) {
        guard let completionHandler else { return }
        guard let command = String(data: messageData, encoding: .utf8) else {
            completionHandler(nil)
            return
        }

        switch command {
        case TunnelConstants.Message.statistics:
            let statistics = relayBox.current?.statistics ?? TunnelStatistics()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            completionHandler(try? encoder.encode(statistics))

        case TunnelConstants.Message.reset:
            relayBox.current?.resetStatistics()
            completionHandler(Data())

        default:
            logger.error("Onbekend bericht van de app: \(command, privacy: .public)")
            completionHandler(nil)
        }
    }

    // MARK: - Slapen en ontwaken

    override func sleep(completionHandler: @escaping () -> Void) {
        // Er is geen sessie om af te bouwen: de tunnel is volledig lokaal.
        completionHandler()
    }

    override func wake() {
        // Niets te herstellen; de leeslus loopt gewoon door.
    }

    // MARK: - Netwerkinstellingen

    /// Bouwt de instellingen voor de virtuele interface.
    ///
    /// `includedRoutes` bevat de default route, waardoor iOS al het IPv4-verkeer
    /// naar deze interface stuurt. IPv6 wordt bewust niet geconfigureerd, zodat
    /// er alleen een IPv4-interface ontstaat.
    static func makeNetworkSettings(for configuration: TunnelConfiguration) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: configuration.tunnelRemoteAddress)
        settings.mtu = NSNumber(value: configuration.mtu)

        let ipv4Settings = NEIPv4Settings(addresses: [configuration.localAddress],
                                          subnetMasks: [configuration.subnetMask])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        ipv4Settings.excludedRoutes = []
        settings.ipv4Settings = ipv4Settings

        if configuration.capturesDNS {
            let dnsSettings = NEDNSSettings(servers: configuration.dnsServers)
            // Lege string matcht elk domein: ook DNS loopt via de tunnel.
            dnsSettings.matchDomains = [""]
            settings.dnsSettings = dnsSettings
        }

        return settings
    }
}
