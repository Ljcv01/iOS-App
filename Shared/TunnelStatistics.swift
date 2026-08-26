//
//  TunnelStatistics.swift
//  Gedeeld tussen de app en de Packet Tunnel Provider extensie.
//

import Foundation

/// Telling van wat er door de virtuele interface is gegaan. De extensie stuurt
/// dit als JSON terug via `handleAppMessage`.
struct TunnelStatistics: Codable, Equatable, Sendable {
    var packetsRead: Int = 0
    var bytesRead: Int = 0
    var packetsWritten: Int = 0
    var bytesWritten: Int = 0
    /// Pakketten waarvan een bron- of bestemmingsadres is omgedraaid door de
    /// hairpin. Blijft dit op 0 staan terwijl je verbindt, dan bereikt je
    /// verkeer de tunnel niet en klopt de routering of het doeladres niet.
    var packetsTranslated: Int = 0
    var startedAt: Date?

    var uptime: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }
}
