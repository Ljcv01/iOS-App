# On-device Location Simulator (iOS 17.4+ / iOS 26)

Een iOS-app die de **systeembrede** GPS-locatie van het toestel zelf simuleert,
zonder dat er een computer aan hangt tijdens gebruik. De architectuur volgt het
bewezen model van [StikDebug](https://github.com/StikDebug/StikDebug) en
[SideStore](https://github.com/SideStore/StosVPN): een lokale loopback-VPN plus
een pairing file, waarmee de app de developer-services van het toestel bereikt.

> **Eén keer via een pc, daarna maandenlang los.** De pc-stap (pairing file +
> Developer Disk Image mounten) is per toestel eenmalig en blijft geldig tot een
> herstart. Daarna werkt de app zelfstandig.

---

## Hoe het werkt

```
   app ──▶ 10.7.0.1:49152                    (RemotePairing)
            │
            ▼
   PacketTunnelProvider  ── NAT-hairpin ──▶  10.7.0.0  (het toestel zelf)
            │
            ▼
   tunnel_create_rppairing   (pairing file → versleutelde tunnel)
            │
            ▼
   remote_server_connect_rsd (DVT over RemoteServiceDiscovery)
            │
            ▼
   location_simulation_set(lat, lon)
```

De VPN leidt géén internetverkeer om. Hij maakt alleen het toestel bereikbaar op
een netwerk-adres: verkeer naar `10.7.0.1` wordt door de provider teruggekaatst
naar de eigen interface (`10.7.0.0`), zodat het voor iOS lijkt alsof een *andere
host* in hetzelfde subnet verbinding maakt. De developer-services accepteren dat
wel, een loopback-verbinding niet.

**Waarom poort 49152 en niet 62078?** Sinds iOS 17 zitten de developer-services
achter RemoteServiceDiscovery op de RemotePairing-poort. De klassieke
lockdownd-poort 62078 levert `com.apple.dt.simulatelocation` niet meer op.

---

## Bestanden

| Bestand | Target | Rol |
| --- | --- | --- |
| `Shared/TunnelConstants.swift` | app + extensie | Identifiers, adressen, poort |
| `Shared/TunnelConfiguration.swift` | app + extensie | Instellingen via `providerConfiguration` |
| `Shared/TunnelStatistics.swift` | app + extensie | Diagnostiek-tellers |
| `PacketTunnel/PacketTunnelProvider.swift` | extensie | Netwerkinstellingen van de tunnel |
| `PacketTunnel/PacketRelay.swift` | extensie | De NAT-hairpin |
| `Services/IdeviceLocationClient.swift` | app | Swift-schil rond de idevice-FFI |
| `Services/PairingRecord.swift` + `PEM.swift` | app | Validatie van het pairing-bestand |
| `App/VPNManager.swift` | app | `NETunnelProviderManager`-beheer |
| `App/SpoofingViewModel.swift` | app | De keten: VPN → tunnel → locatie |
| `App/ContentView.swift` | app | Kaart, importer, badges, knop |
| `App/VPNControlView.swift` | app | Diagnostiek-view |

---

## Setup

### 1. idevice inbouwen

De app leunt op [`jkcoxson/idevice`](https://github.com/jkcoxson/idevice) (MIT).
Die levert de RemotePairing-tunnel, RSD/RemoteXPC en de locatie-API — duizenden
regels protocol- en cryptocode die je niet met de hand wilt naschrijven.

1. Download `idevice-xcframework-<versie>.zip` van de
   [releases](https://github.com/jkcoxson/idevice/releases) (v0.1.66 of nieuwer).
2. Pak uit en sleep het xcframework in je Xcode-project
   (**Target → General → Frameworks, Libraries, and Embedded Content**).
3. Controleer dat `import idevice` werkt. Lukt dat niet, gebruik dan de aanpak
   van StikDebug: leg `idevice.h`, `libidevice_ffi.a` en een `module.modulemap`
   in een map en zet die map in **Build Settings → Swift Compiler → Import Paths**
   (`SWIFT_INCLUDE_PATHS`) én in **Library Search Paths**. De modulemap is:

   ```
   module idevice [system] {
     header "idevice.h"
     export *
   }
   ```

Zonder de bibliotheek compileert het project gewoon door
(`#if canImport(idevice)`), maar meldt de app netjes dat idevice ontbreekt.

### 2. Network Extension target

1. **File ▸ New ▸ Target… ▸ Network Extension**, type **Packet Tunnel**, naam `PacketTunnel`.
2. Capability **Network Extensions ▸ Packet Tunnel** aan in *beide* targets.
3. Vervang de identifiers in `Shared/TunnelConstants.swift` door je eigen bundle-ids.
   `providerBundleIdentifier` moet exact de `PRODUCT_BUNDLE_IDENTIFIER` van het
   extensie-target zijn.
4. Target membership:
   - `Shared/*.swift` → **app én extensie**
   - `PacketTunnel/*.swift` → alleen de **extensie**
   - `App/*.swift` en `Services/*.swift` → alleen de **app**
5. Extensie-target gebruikt `PacketTunnel/Info.plist`.

### 3. De eenmalige pc-stap

Op een Mac of pc, met het toestel aangesloten en ontgrendeld:

```bash
# Pairing file maken
pymobiledevice3 lockdown pair
# of: idevice_pair  (https://github.com/jkcoxson/idevice_pair)

# Developer Mode aanzetten (eenmalig per toestel)
pymobiledevice3 amfi enable-developer-mode

# Developer Disk Image mounten — op iOS 17+ gepersonaliseerd via Apple's servers
pymobiledevice3 mounter auto-mount
```

Zet de pairing file daarna op je toestel (AirDrop, Bestanden, iCloud Drive).

> De DDI-mount blijft geldig **tot de volgende herstart** van het toestel.
> Herhaal `mounter auto-mount` na een reboot.

### 4. Gebruiken

1. Start de app, importeer de pairing file met de knop rechtsboven.
2. Tik een doel op de kaart.
3. **Start Spoofing** — de app zet de VPN aan, bouwt de tunnel op en zet de locatie.
4. Tik daarna gerust een nieuw punt: de sessie blijft open, dus dat gaat instant.

---

## Troubleshooting

| Symptoom | Oorzaak / oplossing |
| --- | --- |
| "Kon geen verbinding maken met de developer-services" | De DDI is niet gemount. Doe stap 3 opnieuw (meestal na een reboot). |
| "Address already in use" | Een andere JIT-/debug-/VPN-app gebruikt de poort. Sluit die, herstart de VPN. |
| "Connection reset" | VPN niet verbonden, of doeladres klopt niet. Controleer `10.7.0.1`. |
| "Timed out" | Toestel vergrendeld, of Wi-Fi/VPN uit. |
| Pairing-fouten | Maak een verse pairing file met het toestel ontgrendeld en vertrouwd. |
| `Omgeleid (hairpin)` blijft 0 | Verkeer bereikt de tunnel niet — controleer routering en doeladres. |

Logs bekijk je in Console.app, gefilterd op subsystem `com.example.iOSApp.tunnel`.

---

## Belangrijke aandachtspunten

- **De extensie draait niet in de Simulator.** Test op een fysiek toestel.
- **Sideload/TestFlight nodig.** De Network Extension-entitlement vereist een
  Apple Developer-account; distributie via de App Store is voor dit type app
  niet realistisch.
- **Niet `excludeLocalNetworks` aanzetten.** Het tunnel-subnet is zelf een
  privé-netwerk; die vlag zou precies het verkeer blokkeren dat door de tunnel moet.
- **Geen checksums herberekenen in de hairpin.** De bewezen implementaties doen
  dat ook niet: op een utun-interface worden checksums van geïnjecteerde pakketten
  niet gevalideerd. "Verbeteren" breekt het juist.
- **Na `saveToPreferences()` altijd `loadFromPreferences()`** vóór het starten,
  anders `NEVPNError.configurationInvalid`.
- **iOS 17.4+ vereist.** Daaronder gelden andere connectieprotocollen. idevice
  biedt daarvoor `lockdown_location_simulation_*` (het klassieke pad), maar dat
  is in deze app niet ingebouwd.

## Status

De code is geschreven tegen de geverifieerde FFI-signaturen uit `idevice.h`
(v0.1.66) en volgt de werkende referentie-implementatie van StikDebug. Hij is in
deze omgeving **niet gecompileerd en niet op een toestel getest** — er was geen
Swift-toolchain of iPhone beschikbaar. Reken op bijstellen bij de eerste build.

## Credits

- [jkcoxson/idevice](https://github.com/jkcoxson/idevice) — MIT
- [StikDebug](https://github.com/StikDebug/StikDebug) — referentie-implementatie
- [SideStore/StosVPN](https://github.com/SideStore/StosVPN) — het hairpin-model
- [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) — de pc-stap
