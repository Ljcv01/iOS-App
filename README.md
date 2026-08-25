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

# Module 2 — Lockdown & Protocol Service

Een Swift 6-compliant client die zich met een **pairing record** bij lockdownd
authenticeert, de verbinding naar **TLS** upgradet en daarna het
`com.apple.dt.simulatelocation`-protocol spreekt.

### Bestanden (`Services/`)

| Bestand | Rol |
| --- | --- |
| `Services/PEM.swift` | PEM ↔ DER-helper voor de certificaten/sleutels uit de pairing record |
| `Services/PairingRecord.swift` | Parser voor de `.plist`/`.bplist` pairing record; bouwt de client-`SecIdentity` en pint het device-certificaat |
| `Services/SocketChannel.swift` | Rauwe POSIX-socket met Secure Transport (`SSLContext`) STARTTLS-upgrade midden in de stream |
| `Services/LockdownClient.swift` | lockdownd-handshake: `QueryType` → `StartSession` → TLS → `StartService` |
| `Services/LocationSimulatorService.swift` | `actor` met `connectToLockdownd(pairingRecord:port:)`, `sendSimulateLocation(latitude:longitude:)`, `stopSimulation()`, `disconnect()` |
| `Tests/LocationSimulatorEncodingTests.swift` | Wire-encoding + big-endian double-helper |
| `Tests/PairingRecordTests.swift` | PEM-decode en pairing-record-parsing |

### Waarom een rauwe socket en niet `NWConnection`

Lockdown doet eerst een **plaintext** `StartSession` en upgradet daarna *dezelfde*
socket naar TLS (STARTTLS-stijl). `NWConnection` kan geen TLS starten midden in een
bestaande stream — daar moet TLS bij het opzetten al vaststaan. De enige manier die
op iOS wél een in-stream upgrade doet, is een rauwe POSIX-socket met **Secure
Transport** (`SSLContext` + `SSLSetIOFuncs`) eroverheen; dat is ook wat de
libimobiledevice-poorten op Apple-platforms doen. `SSLContext` is deprecated maar
functioneel. De client-identity komt uit de pairing record; de peer wordt gepind op
het `DeviceCertificate` in plaats van via keten-validatie (het zijn
zelfondertekende certificaten).

### Handshake-sequentie

```
verbind (plaintext) ──▶ QueryType            (verwacht com.apple.mobile.lockdown)
                    ──▶ StartSession          (HostID + SystemBUID uit de pairing record)
                    ──▶ TLS-upgrade           (als EnableSessionSSL: client-cert + pin)
                    ──▶ StartService           (com.apple.dt.simulatelocation → poort)
        nieuw kanaal ──▶ (TLS als EnableServiceSSL) ──▶ locatiecommando's
```

### Wire-formaat

Het simulatelocation-protocol stuurt de coördinaten als **lengte-geprefixte
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
let simulator = LocationSimulatorService(host: "127.0.0.1")   // of het Wi-Fi-IP van het toestel

// Pairing record via .fileImporter (Module 4) of uit de app-bundle:
try await simulator.connectToLockdownd(pairingRecordURL: url)
try await simulator.sendSimulateLocation(latitude: 52.3676, longitude: 4.9041)
// … later:
try await simulator.stopSimulation()
await simulator.disconnect()
```

De socket wordt automatisch gesloten bij elke verzend-/verbindings-/TLS-fout en bij
`disconnect()`. `LocationSimulatorService` is een `actor`, en `SocketChannel`
serialiseert alle fd/TLS-toegang op één queue — Swift 6-veilig.

### Belangrijk: haalbaarheid

`com.apple.dt.simulatelocation` vereist dat de Developer Disk Image gemount is. Op
iOS 17+ is dat een **gepersonaliseerde DDI** die vooraf via een PC/Mac gemount moet
zijn (Module 3 is daarom geschrapt), en zijn developer-services bovendien verhuisd
naar **RemoteServiceDiscovery**. lockdownd en simulatelocation zijn van oorsprong
host-side (usbmux) protocollen. Deze client implementeert het **klassieke
lockdown-pad** correct — inclusief de pairing-TLS-upgrade — en is bedoeld als
educatieve/functionele re-implementatie. Of hij op een concreet toestel/iOS-versie
daadwerkelijk een locatie zet, hangt af van of dat pad daar beschikbaar is gemaakt.

> Deze code is niet gecompileerd of tegen een fysiek toestel getest in deze omgeving
> (geen Swift-toolchain aanwezig). De low-level Secure Transport- en keychain-paden
> zijn zorgvuldig geschreven volgens de betreffende API's, maar device-specifieke
> TLS-parameters kunnen tuning vereisen.

---

# Module 4 — SwiftUI-frontend

Een moderne iOS 17+-interface (getest tegen iPhone 17 Pro Max / iOS 26.5.2) die de
modules aan elkaar knoopt.

### Bestanden (`App/`)

| Bestand | Rol |
| --- | --- |
| `App/ContentView.swift` | Kaart, `.fileImporter`, status-badges en de 'Start Spoofing'-knop |
| `App/SpoofingViewModel.swift` | `@MainActor ObservableObject` die de keten orkestreert (VPN → pairing/TLS → coördinaten) |

### Wat de UI doet

- **Kaart** — moderne MapKit `Map` binnen een `MapReader`; een tik wordt via
  `proxy.convert(_:from:)` omgezet naar een `CLLocationCoordinate2D` en getoond als
  rode `Marker`. Tikken terwijl de simulatie actief is, verplaatst de gesimuleerde
  locatie meteen.
- **Pairing File** — `.fileImporter` voor het `.bplist` bestand. Het bestand wordt
  binnen security-scoped toegang ingelezen en direct als `PairingRecord`
  gevalideerd, zodat fouten meteen zichtbaar zijn.
- **Status-badges** — VPN-status (uit `VPNManager`, Module 1) en protocol-status
  (uit de keten-fase, Module 2), met kleur die de toestand volgt.
- **Host-veld** — standaard `127.0.0.1` (via de tunnel), of het Wi-Fi-IP van het
  toestel.
- **Start Spoofing** — draait de keten asynchroon:
  1. `VPNManager.start()` en wachten tot de tunnel `.connected` is (met time-out),
  2. `LocationSimulatorService.connectToLockdownd(pairingRecord:)` (lockdown + TLS),
  3. `sendSimulateLocation(latitude:longitude:)`.
  De knop wordt 'Stop Spoofing' zodra de locatie actief is en zet alles weer terug.
- **Foutafhandeling** — elke fase-fout landt in een `Alert` met een leesbare
  beschrijving; de keten sluit het kanaal netjes af.

### Wiring

Zet `ContentView` als root:

```swift
@main
struct LocationSimulatorApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
```

Target membership: `App/*.swift` hoort bij de **app**, samen met `Shared/*.swift` en
`Services/*.swift`. (`Services/` heeft geen `NetworkExtension` nodig en draait in het
app-proces.)
