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

    static let loggingSubsystem = "com.example.iOSApp.tunnel"

    // MARK: - Adressering van de loopback-tunnel
    //
    // Dit volgt de conventie van StosVPN / LocalDevVPN, de tunnels waar
    // StikDebug en SideStore op draaien. De virtuele interface krijgt
    // `deviceAddress`; verkeer naar `peerAddress` wordt door de provider
    // teruggekaatst naar het toestel zelf (een NAT-hairpin). Daardoor bereikt
    // de app de systeemservices van het toestel via een adres dat er voor
    // iOS uitziet als een *externe* host in hetzelfde subnet — precies wat
    // de developer-services verwachten.

    /// Adres van de virtuele interface op het toestel.
    static let deviceAddress = "10.7.0.0"

    /// Adres waar de app naartoe verbindt. De provider draait dit om naar
    /// `deviceAddress`, zodat het pakket bij het toestel zelf uitkomt.
    static let peerAddress = "10.7.0.1"

    static let subnetMask = "255.255.255.0"

    /// Wordt getoond als "Server" in Instellingen.
    static let serverAddress = peerAddress

    /// RemotePairing-poort op het toestel (iOS 17+). Let op: dit is *niet*
    /// de klassieke lockdownd-poort 62078 — developer-services zitten sinds
    /// iOS 17 achter RemoteServiceDiscovery op deze poort.
    static let remotePairingPort: UInt16 = 49152

    /// Berichten die de app via `sendProviderMessage` naar de provider stuurt.
    enum Message {
        static let statistics = "statistics"
        static let reset = "reset"
    }
}
