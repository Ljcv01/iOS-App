//
//  TunnelConstants.swift
//  Gedeeld tussen de app en de Packet Tunnel Provider extensie.
//
//  Pas de identifiers hieronder aan naar je eigen bundle identifiers.
//

import Foundation

enum TunnelConstants {

    /// Bundle identifier van de Network Extension target (de extensie zelf).
    /// Moet exact overeenkomen met de `PRODUCT_BUNDLE_IDENTIFIER` van het
    /// PacketTunnel-target, anders kan het systeem de provider niet starten.
    static let providerBundleIdentifier = "com.example.iOSApp.PacketTunnel"

    /// App Group die door beide targets wordt gedeeld (optioneel, handig voor logs).
    static let appGroupIdentifier = "group.com.example.iOSApp"

    /// Naam zoals die in Instellingen > VPN bij de gebruiker verschijnt.
    static let localizedDescription = "Loopback Tunnel"

    /// Wordt getoond als "Server" in Instellingen. De tunnel is puur lokaal,
    /// dus dit is het loopback-adres.
    static let serverAddress = "127.0.0.1"

    static let loggingSubsystem = "com.example.iOSApp.tunnel"

    /// Berichten die de app via `sendProviderMessage` naar de provider stuurt.
    enum Message {
        static let statistics = "statistics"
        static let reset = "reset"
    }
}
