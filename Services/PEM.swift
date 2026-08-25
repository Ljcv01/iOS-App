//
//  PEM.swift
//  Services
//
//  Minimale PEM/DER-helper. Pairing records slaan certificaten en sleutels
//  meestal op als PEM-tekst binnen een <data>-blok; deze helper haalt de ruwe
//  DER-bytes eruit.
//

import Foundation

enum PEM {

    /// Decodeert een PEM-string naar DER. Alle `-----BEGIN/END-----`-regels
    /// worden overgeslagen en de rest wordt als base64 geïnterpreteerd.
    static func decode(_ pem: String) -> Data? {
        let body = pem
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return Data(base64Encoded: body)
    }

    /// Normaliseert een veld uit de pairing record naar DER.
    ///
    /// - Bevat het PEM-markers, dan decoderen we de base64-body.
    /// - Anders nemen we aan dat de bytes al DER zijn.
    static func normalizeToDER(_ raw: Data) -> Data? {
        if let text = String(data: raw, encoding: .utf8), text.contains("-----BEGIN") {
            return decode(text)
        }
        return raw.isEmpty ? nil : raw
    }
}
