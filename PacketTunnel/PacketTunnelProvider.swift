//
//  PacketTunnelProvider.swift
//  PacketTunnel
//
//  Loopback-tunnel volgens het StosVPN / LocalDevVPN-model. De virtuele
//  IPv4-interface krijgt 10.7.0.0/24 en ALLEEN dat subnet wordt de tunnel in
//  gerouteerd — de default route wordt expliciet uitgesloten, zodat je normale
//  internetverkeer ongemoeid blijft.
//
//  Verkeer naar 10.7.0.1 wordt door `PacketRelay` teruggekaatst naar het
//  toestel zelf, waardoor de app de developer-services van het toestel kan
//  bereiken (RemotePairing op poort 49152).
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
        var configuration = TunnelConfiguration(
            providerConfiguration: (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        )

        // Opties uit `startVPNTunnel(options:)` winnen van de opgeslagen configuratie.
        if let value = options?[TunnelConfiguration.Key.deviceAddress] as? NSString {
            configuration.deviceAddress = value as String
        }
        if let value = options?[TunnelConfiguration.Key.peerAddress] as? NSString {
            configuration.peerAddress = value as String
        }

        let settings = Self.makeNetworkSettings(for: configuration)

        logger.log("""
            Tunnel starten: interface \(configuration.deviceAddress, privacy: .public), \
            peer \(configuration.peerAddress, privacy: .public), \
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
        completionHandler()
    }

    override func wake() {
        // De leeslus loopt gewoon door; niets te herstellen.
    }

    // MARK: - Netwerkinstellingen

    /// Alleen het tunnel-subnet wordt opgevangen. `excludedRoutes = [.default()]`
    /// is essentieel: zonder die regel zou al het verkeer van het toestel de
    /// tunnel in gaan en zou je internetverbinding eruit liggen.
    static func makeNetworkSettings(for configuration: TunnelConfiguration) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: configuration.deviceAddress)
        settings.mtu = NSNumber(value: configuration.mtu)

        let ipv4Settings = NEIPv4Settings(addresses: [configuration.deviceAddress],
                                          subnetMasks: [configuration.subnetMask])
        ipv4Settings.includedRoutes = [
            NEIPv4Route(destinationAddress: configuration.deviceAddress,
                        subnetMask: configuration.subnetMask)
        ]
        ipv4Settings.excludedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4Settings

        // Bewust geen DNS-instellingen: de tunnel mag de naamsresolutie van het
        // toestel niet overnemen.
        return settings
    }
}
