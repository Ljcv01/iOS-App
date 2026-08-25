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

---

# Module 2 — Communicatieprotocol (`LocationSimulatorService`)

Een Swift 6-compliant client die het `com.apple.dt.simulatelocation`-protocol van
Apple spreekt over een TCP-socket, opgezet met `Network.framework` (`NWConnection`)
richting `127.0.0.1` (uit `TunnelConstants`).

### Bestanden (`Services/`)

| Bestand | Rol |
| --- | --- |
| `Services/TCPConnection.swift` | Async/await-schil rond `NWConnection`: `open`, `send`, `receive(exactly:)`, `close` |
| `Services/LockdownClient.swift` | Minimale lockdownd-client: plist-berichten met 4-byte big-endian lengte-prefix, `QueryType` + `StartService` |
| `Services/LocationSimulatorService.swift` | `actor` met `connectToLockdownd(port:)`, `sendSimulateLocation(latitude:longitude:)`, `stopSimulation()`, `simulate(...)`, `disconnect()` |
| `Tests/LocationSimulatorEncodingTests.swift` | Swift Testing-dekking voor de wire-encoding |

### Belangrijk: haalbaarheid

`com.apple.dt.simulatelocation` en `lockdownd` zijn **host-side** protocollen. Ze
draaien op het toestel maar worden vanaf een *computer* aangesproken via usbmux/USB
(zoals Xcode en libimobiledevice doen). Een gesandboxte iOS-app die op het toestel
zelf draait kan `lockdownd` **niet** bereiken via `127.0.0.1` — ook niet via de
tunnel uit Module 1, want die vangt IP-pakketten, terwijl simulatelocation over het
usbmux/lockdown-kanaal loopt (geen bereikbare IP-service).

Deze code is een **correcte client voor het protocol**. Hij werkt zodra er echt een
lockdownd-endpoint op de opgegeven poort luistert (een host-context, een relay die
de tunnel doorstuurt, of een jailbreak-omgeving). Op een standaard toestel vanuit de
app-sandbox zal de verbinding worden geweigerd (`.transport(...)`-fout).

### Wire-formaat

Het echte simulatelocation-protocol stuurt de coördinaten als **lengte-geprefixte
ASCII-strings**, voorafgegaan door een 4-byte big-endian commandowoord:

```
[ command : uint32 BE ]        0 = locatie zetten, 1 = simulatie stoppen
[ len : uint32 BE ][ latitude  ASCII ]
[ len : uint32 BE ][ longitude ASCII ]
```

Dit is exact wat `idevicesetlocation` doet. De in de opdracht genoemde big-endian
IEEE-754 double-serialisatie zit als herbruikbare helper in `Double.bigEndianBytes`,
maar het simulatelocation-kanaal zelf gebruikt strings, geen doubles.

### Gebruik

```swift
let simulator = LocationSimulatorService()          // host: 127.0.0.1

try await simulator.connectToLockdownd()            // QueryType + StartService
try await simulator.sendSimulateLocation(latitude: 37.7749, longitude: -122.4194)
// … later:
try await simulator.stopSimulation()
await simulator.disconnect()

// Of in één keer:
try await simulator.simulate(latitude: 52.3676, longitude: 4.9041)
```

De `NWConnection` wordt automatisch gesloten bij elke verzend-/verbindingsfout en
bij `disconnect()`. `LocationSimulatorService` is een `actor`, dus de socket-state
wordt serieel en Swift 6-veilig beheerd.
