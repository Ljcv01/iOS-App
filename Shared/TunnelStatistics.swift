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
    var icmpEchoRepliesSent: Int = 0
    var packetsDropped: Int = 0
    var startedAt: Date?

    var uptime: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }
}
