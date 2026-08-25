//
//  VPNManager.swift
//  iOS-App
//
//  Beheert het VPN-profiel van de lokale packet tunnel: installeren, status
//  uitlezen, in- en uitschakelen en controleren of de gebruiker het profiel al
//  heeft goedgekeurd.
//

import Combine
import Foundation
import NetworkExtension
import os

/// Fouten die `VPNManager` naar buiten brengt.
///
/// Staat op bestandsniveau en niet genest in `VPNManager`: types die in een
/// `@MainActor`-klasse genest zitten kunnen die isolatie erven, en deze fouten
/// worden ook vanuit nonisolated callbacks aangemaakt.
enum VPNManagerError: LocalizedError, Equatable {
    case profileNotInstalled
    case permissionDenied
    case configurationStale
    case notConnected
    case unsupportedSession
    case emptyResponse
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .profileNotInstalled:
            return "Het VPN-profiel is nog niet geïnstalleerd."
        case .permissionDenied:
            return "De gebruiker heeft het toevoegen van de VPN-configuratie geweigerd."
        case .configurationStale:
            return "De VPN-configuratie is verouderd. Laad hem opnieuw en probeer het nog eens."
        case .notConnected:
            return "De tunnel is niet verbonden."
        case .unsupportedSession:
            return "De actieve sessie is geen NETunnelProviderSession."
        case .emptyResponse:
            return "De extensie stuurde geen bruikbaar antwoord terug."
        case .underlying(let message):
            return message
        }
    }
}

/// Bewaart notificatie-tokens buiten elke actor-isolatie, zodat `deinit` ze mag opruimen.
private final class ObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    func store(_ newTokens: [NSObjectProtocol]) {
        lock.withLock { tokens.append(contentsOf: newTokens) }
    }

    func removeAll() {
        let pending = lock.withLock { () -> [NSObjectProtocol] in
            let existing = tokens
            tokens.removeAll()
            return existing
        }
        for token in pending {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

@MainActor
final class VPNManager: ObservableObject {

    /// Kortere naam voor gebruik binnen deze klasse.
    typealias VPNError = VPNManagerError

    // MARK: - Gepubliceerde state

    /// Actuele status van de tunnel (`.invalid` als er geen profiel is).
    @Published private(set) var status: NEVPNStatus = .invalid

    /// `true` zodra het profiel in Instellingen staat, oftewel zodra de
    /// gebruiker de configuratie heeft goedgekeurd.
    @Published private(set) var isProfileInstalled = false

    /// `true` als het profiel bestaat én ingeschakeld is.
    @Published private(set) var isProfileEnabled = false

    @Published private(set) var isOnDemandEnabled = false

    /// `true` zolang er een bewerking loopt (installeren, starten, stoppen).
    @Published private(set) var isBusy = false

    @Published private(set) var lastError: VPNManagerError?

    var isConnected: Bool { status == .connected }

    var isTransitioning: Bool {
        status == .connecting || status == .disconnecting || status == .reasserting
    }

    var statusDescription: String {
        switch status {
        case .invalid: return isProfileInstalled ? "Ongeldig" : "Niet geïnstalleerd"
        case .disconnected: return "Verbroken"
        case .connecting: return "Verbinden…"
        case .connected: return "Verbonden"
        case .reasserting: return "Herstellen…"
        case .disconnecting: return "Verbreken…"
        @unknown default: return "Onbekend"
        }
    }

    // MARK: - Privé

    private var manager: NETunnelProviderManager?
    private let observations = ObservationBox()
    private let logger = Logger(subsystem: TunnelConstants.loggingSubsystem, category: "VPNManager")

    init() {
        observeSystemNotifications()
    }

    deinit {
        observations.removeAll()
    }

    // MARK: - Profiel laden en controleren

    /// Leest de bestaande profielen uit de voorkeuren en werkt de gepubliceerde
    /// state bij. Roep dit aan bij het verschijnen van je view.
    ///
    /// - Returns: `true` als het profiel al door de gebruiker is geïnstalleerd.
    @discardableResult
    func refresh() async -> Bool {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            apply(managers.first(where: Self.isOurProfile) ?? managers.first)
            lastError = nil
        } catch {
            handle(error)
            apply(nil)
        }
        return isProfileInstalled
    }

    /// Controleert zonder de gepubliceerde state te wijzigen of het profiel bestaat.
    func checkProfileInstalled() async -> Bool {
        let managers = try? await NETunnelProviderManager.loadAllFromPreferences()
        return managers?.contains(where: Self.isOurProfile) ?? false
    }

    // MARK: - Installeren en verwijderen

    /// Maakt of werkt het VPN-profiel bij. De eerste keer toont iOS hierbij de
    /// systeemvraag "VPN-configuraties toevoegen?" aan de gebruiker.
    func installProfile(configuration: TunnelConfiguration = .default) async throws {
        isBusy = true
        defer { isBusy = false }

        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let manager = managers.first(where: Self.isOurProfile) ?? NETunnelProviderManager()
            configure(manager, with: configuration)

            try await manager.saveToPreferences()
            // Na opslaan verplicht opnieuw laden: het systeem vult pas daarna de
            // definitieve identifier in. Starten met het oude object levert
            // NEVPNError.configurationInvalid op.
            try await manager.loadFromPreferences()

            apply(manager)
            lastError = nil
            logger.log("VPN-profiel opgeslagen en geladen.")
        } catch {
            throw handle(error)
        }
    }

    /// Verwijdert het profiel uit Instellingen.
    func removeProfile() async throws {
        isBusy = true
        defer { isBusy = false }

        guard let manager else { throw handle(VPNError.profileNotInstalled) }
        do {
            try await manager.removeFromPreferences()
            apply(nil)
            lastError = nil
        } catch {
            throw handle(error)
        }
    }

    // MARK: - In- en uitschakelen

    /// Start de tunnel. Installeert het profiel automatisch als dat nog niet bestaat.
    func start(options: [String: NSObject]? = nil) async throws {
        if manager == nil {
            await refresh()
        }
        if manager == nil {
            try await installProfile()
        }
        guard let manager else { throw handle(VPNError.profileNotInstalled) }

        isBusy = true
        defer { isBusy = false }

        do {
            if !manager.isEnabled {
                manager.isEnabled = true
                try await manager.saveToPreferences()
            }
            // Altijd verversen vlak voor het starten: een sessie die op een
            // verouderd configuratie-object draait weigert te starten.
            try await manager.loadFromPreferences()

            try manager.connection.startVPNTunnel(options: options)
            lastError = nil
            logger.log("Tunnel gestart.")
        } catch {
            throw handle(error)
        }
        refreshStatus()
    }

    /// Stopt de tunnel. Het profiel blijft staan.
    func stop() {
        guard let manager else { return }
        manager.connection.stopVPNTunnel()
        logger.log("Tunnel gestopt.")
        refreshStatus()
    }

    func toggle() async throws {
        if isConnected || isTransitioning {
            stop()
        } else {
            try await start()
        }
    }

    /// Zet het profiel zelf aan of uit zonder het te verwijderen.
    func setProfileEnabled(_ enabled: Bool) async throws {
        guard let manager else { throw handle(VPNError.profileNotInstalled) }
        isBusy = true
        defer { isBusy = false }

        do {
            manager.isEnabled = enabled
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            apply(manager)
            lastError = nil
        } catch {
            throw handle(error)
        }
    }

    /// Schakelt "connect on demand" in of uit.
    func setOnDemandEnabled(_ enabled: Bool) async throws {
        guard let manager else { throw handle(VPNError.profileNotInstalled) }
        isBusy = true
        defer { isBusy = false }

        do {
            if enabled {
                let rule = NEOnDemandRuleConnect()
                rule.interfaceTypeMatch = .any
                manager.onDemandRules = [rule]
            } else {
                manager.onDemandRules = []
            }
            manager.isOnDemandEnabled = enabled
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            apply(manager)
            lastError = nil
        } catch {
            throw handle(error)
        }
    }

    // MARK: - Statistieken uit de extensie

    /// Vraagt de tellers op bij de draaiende provider via `sendProviderMessage`.
    func fetchStatistics() async throws -> TunnelStatistics {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            throw handle(VPNError.unsupportedSession)
        }
        guard status == .connected else {
            throw handle(VPNError.notConnected)
        }

        let payload = Data(TunnelConstants.Message.statistics.utf8)
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(payload) { response in
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    guard let response,
                          let statistics = try? decoder.decode(TunnelStatistics.self, from: response) else {
                        continuation.resume(throwing: VPNError.emptyResponse)
                        return
                    }
                    continuation.resume(returning: statistics)
                }
            } catch {
                continuation.resume(throwing: VPNError.underlying(error.localizedDescription))
            }
        }
    }

    // MARK: - Interne helpers

    /// `nonisolated`, zodat de functie als gewone `(Element) -> Bool` aan
    /// `first(where:)` en `contains(where:)` doorgegeven kan worden zonder de
    /// MainActor-isolatie mee te slepen.
    nonisolated private static func isOurProfile(_ manager: NETunnelProviderManager) -> Bool {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { return false }
        return proto.providerBundleIdentifier == TunnelConstants.providerBundleIdentifier
    }

    private func configure(_ manager: NETunnelProviderManager, with configuration: TunnelConfiguration) {
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = TunnelConstants.providerBundleIdentifier
        proto.serverAddress = TunnelConstants.serverAddress
        proto.providerConfiguration = configuration.dictionaryRepresentation
        proto.disconnectOnSleep = false
        // Verkeer binnen het lokale netwerk (AirPrint, AirPlay) buiten de tunnel houden.
        proto.excludeLocalNetworks = true

        manager.protocolConfiguration = proto
        manager.localizedDescription = TunnelConstants.localizedDescription
        manager.isEnabled = true
    }

    private func apply(_ manager: NETunnelProviderManager?) {
        self.manager = manager
        isProfileInstalled = manager != nil
        isProfileEnabled = manager?.isEnabled ?? false
        isOnDemandEnabled = manager?.isOnDemandEnabled ?? false
        status = manager?.connection.status ?? .invalid
    }

    private func refreshStatus() {
        status = manager?.connection.status ?? .invalid
    }

    private func observeSystemNotifications() {
        let center = NotificationCenter.default

        let statusToken = center.addObserver(forName: .NEVPNStatusDidChange,
                                             object: nil,
                                             queue: nil) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }

        let configurationToken = center.addObserver(forName: .NEVPNConfigurationChange,
                                                    object: nil,
                                                    queue: nil) { [weak self] _ in
            Task { @MainActor in _ = await self?.refresh() }
        }

        observations.store([statusToken, configurationToken])
    }

    @discardableResult
    private func handle(_ error: Error) -> VPNManagerError {
        let mapped: VPNManagerError
        switch error {
        case let vpnError as VPNManagerError:
            mapped = vpnError
        case let nsError as NSError where nsError.domain == NEVPNErrorDomain:
            switch nsError.code {
            case NEVPNError.Code.configurationReadWriteFailed.rawValue:
                // Dit is de foutcode die iOS teruggeeft als de gebruiker de
                // systeemvraag om de VPN-configuratie toe te voegen weigert.
                mapped = .permissionDenied
            case NEVPNError.Code.configurationStale.rawValue:
                mapped = .configurationStale
            default:
                mapped = .underlying(nsError.localizedDescription)
            }
        default:
            mapped = .underlying(error.localizedDescription)
        }

        lastError = mapped
        logger.error("VPN-fout: \(mapped.localizedDescription, privacy: .public)")
        return mapped
    }
}
