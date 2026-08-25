# Lokale Packet Tunnel (iOS 26)

Een volledig lokale `NEPacketTunnelProvider`: er wordt een virtuele IPv4-interface
(utun) opgezet met een default route, zodat al het IPv4-verkeer van het toestel de
tunnel in gaat. Het remote adres van de tunnel is `127.0.0.1`. Er wordt **geen enkele
socket geopend en geen enkel extern netwerkverzoek gedaan** — de extensie importeert
alleen `NetworkExtension`, `Foundation` en `os`.

## Bestanden

| Bestand | Target | Rol |
| --- | --- | --- |
| `Shared/TunnelConstants.swift` | app + extensie | Bundle-identifiers en berichtnamen |
| `Shared/TunnelConfiguration.swift` | app + extensie | Instellingen die via `providerConfiguration` worden doorgegeven |
| `Shared/TunnelStatistics.swift` | app + extensie | Tellers die de extensie terugstuurt |
| `PacketTunnel/PacketTunnelProvider.swift` | extensie | De provider zelf |
| `PacketTunnel/PacketRelay.swift` | extensie | Leeslus en pakketverwerking |
| `PacketTunnel/IPv4Packet.swift` | extensie | IPv4-parsing, checksums, ICMP echo reply |
| `App/VPNManager.swift` | app | `ObservableObject` rondom `NETunnelProviderManager` |
| `App/VPNControlView.swift` | app | Voorbeeld-UI |
| `Tests/IPv4PacketTests.swift` | tests | Swift Testing-tests voor de pakketlogica |

## Opzet in Xcode

1. Voeg aan je app-project een target toe: **File ▸ New ▸ Target… ▸ Network Extension**,
   en kies **Packet Tunnel** als extensietype. Noem het target bijvoorbeeld `PacketTunnel`.
2. Zet in beide targets de capability **Network Extensions ▸ Packet Tunnel** aan
   (`com.apple.developer.networking.networkextension` met `packet-tunnel-provider`).
   Deze entitlement vereist een betaald Apple Developer-account; App Groups zijn optioneel.
3. Vervang in `Shared/TunnelConstants.swift` de identifiers door je eigen bundle-ids.
   `providerBundleIdentifier` moet exact gelijk zijn aan de `PRODUCT_BUNDLE_IDENTIFIER`
   van het extensie-target, anders weigert het systeem de provider te starten.
4. Target membership:
   - `Shared/*.swift` → **app én extensie**
   - `PacketTunnel/*.swift` → alleen de **extensie**
   - `App/*.swift` → alleen de **app**
5. Zorg dat het extensie-target `PacketTunnel/Info.plist` gebruikt, met
   `NSExtensionPointIdentifier` = `com.apple.networkextension.packet-tunnel` en
   `NSExtensionPrincipalClass` = `$(PRODUCT_MODULE_NAME).PacketTunnelProvider`.

## Gebruik

```swift
@StateObject private var vpn = VPNManager()

// Bij het verschijnen van je view: bestaand profiel inlezen.
await vpn.refresh()

// Is het profiel al door de gebruiker geïnstalleerd?
if vpn.isProfileInstalled { … }

// Installeren (toont de systeemvraag "VPN-configuraties toevoegen?").
try await vpn.installProfile()

// In- en uitschakelen.
try await vpn.start()
vpn.stop()

// Status volgen: `vpn.status` is @Published en volgt NEVPNStatusDidChange.
```

## Wat de tunnel met verkeer doet

* Alle IPv4-pakketten worden gelezen via `packetFlow.readPackets`.
* ICMP echo requests (ping) worden **lokaal in de extensie beantwoord**: bron- en
  bestemmingsadres worden omgedraaid, beide checksums worden herberekend en het
  antwoord gaat via `packetFlow.writePackets` terug de interface in. Zo kun je met
  `ping` aantonen dat het verkeer door de tunnel loopt zonder dat er iets naar buiten gaat.
* Al het overige verkeer (TCP, UDP, DNS) wordt geteld en verworpen. De tunnel is een sink:
  verbindingen naar buiten lopen bewust dood. Zet `capturesDNS` op `false` in
  `TunnelConfiguration` als je DNS ongemoeid wilt laten.
* IPv6 wordt niet geconfigureerd, dus er ontstaat uitsluitend een IPv4-interface.

## Adreskeuze

De interface krijgt `198.18.0.1/24` (RFC 2544, gereserveerd voor benchmarking, botst dus
niet met echte netwerken van de gebruiker). `127.0.0.1` kan hier niet als interface-adres
gebruikt worden — iOS weigert een loopback-adres op een utun-interface. Het loopback-adres
wordt wél gebruikt als `tunnelRemoteAddress` en als `serverAddress` in Instellingen.

## Aandachtspunten

* De extensie draait **niet** in de Simulator; test op een fysiek toestel.
* Na `saveToPreferences()` altijd `loadFromPreferences()` aanroepen vóór het starten,
  anders krijg je `NEVPNError.configurationInvalid`.
* Weigert de gebruiker de systeemvraag, dan komt dat terug als
  `NEVPNError.configurationReadWriteFailed`; `VPNManager` vertaalt dat naar
  `VPNError.permissionDenied`.
* De code is geschreven met strict concurrency in het achterhoofd: de provider vangt
  in geen enkele escaping closure `self`, en gedeelde state zit in `Sendable` types
  achter een `NSLock`.
* Log-output bekijk je met Console.app, gefilterd op subsystem
  `com.example.iOSApp.tunnel`.
