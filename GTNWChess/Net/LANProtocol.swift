//
//  LANProtocol.swift
//  GTNW Chess
//
//  Two-Mac play over the local network: Bonjour (`_gtnwchess._tcp`) + Network.framework TCP with TLS 1.2 PSK. The
//  pre-shared key is derived from a 6-digit pairing code shown on the host, so only a Mac that knows the code can
//  complete the handshake; everything after it is encrypted. Messages are length-prefixed JSON (≤ 64 KB).
//

import CryptoKit
import Foundation
import Network

enum LANMessage: Codable, Equatable, Sendable {
    case hello(proto: Int, name: String, account: String?, gameID: UUID?, haveplies: Int?)
    case welcome(LANState)
    case move(ply: Int, uci: String, clockMs: Int?)
    case reject(reason: String, ply: Int)
    case drawOffer(ply: Int)
    case drawReply(accept: Bool)
    case resign(ply: Int)
    case flag(side: Side)
    case ping
    case pong
    case bye
}

/// The full game state the host sends on join / rejoin / resync. The guest replays and validates it.
struct LANState: Codable, Equatable, Sendable {
    var gameID: UUID
    var hostName: String
    var hostAccount: String?
    var guestName: String
    var hostSide: Side
    var startFEN: String
    var moves: [String]
    var clock: ClockConfig?
    var clockMs: [Int]?
    var result: GameResult?
}

enum LANCodec {
    static let maxFrame = 65_536
    static let protocolVersion = 1

    static func encode(_ m: LANMessage) throws -> Data {
        let body = try JSONEncoder().encode(m)
        guard body.count <= maxFrame else { throw LANError.tooLarge }
        var len = UInt32(body.count).bigEndian
        return Data(bytes: &len, count: 4) + body
    }

    /// Pulls complete frames off `buffer`. Throws on an oversize or undecodable frame.
    static func decode(_ buffer: inout Data) throws -> [LANMessage] {
        var out: [LANMessage] = []
        while buffer.count >= 4 {
            let len = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard len > 0, len <= maxFrame else { throw LANError.tooLarge }
            guard buffer.count >= 4 + len else { break }
            let body = buffer.subdata(in: buffer.startIndex + 4..<buffer.startIndex + 4 + len)
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + 4 + len)
            out.append(try JSONDecoder().decode(LANMessage.self, from: body))
        }
        return out
    }
}

enum LANError: Error, Equatable, LocalizedError {
    case tooLarge, badCode, closed, timeout, protocolMismatch, rejected(String)
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "Message too large"
        case .badCode: return "Pairing code must be 6 digits"
        case .closed: return "Connection closed"
        case .timeout: return "Connection timed out"
        case .protocolMismatch: return "The other Mac runs an incompatible GTNW Chess"
        case .rejected(let r): return "Rejected: \(r)"
        }
    }
}

enum LANSecurity {
    static let serviceType = "_gtnwchess._tcp"

    static func newPairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    static func isValidCode(_ s: String) -> Bool { s.count == 6 && s.allSatisfy(\.isASCII) && s.allSatisfy(\.isNumber) }

    /// PSK = HKDF-SHA256(code, salt "gtnwchess-lan-v1"), 32 bytes.
    static func psk(code: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)), salt: Data("gtnwchess-lan-v1".utf8),
                               info: Data("psk".utf8), outputByteCount: 32)
    }

    static func parameters(code: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = psk(code: code).withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("gtnwchess".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.connectionTimeout = 8
        let p = NWParameters(tls: tls, tcp: tcp)
        p.includePeerToPeer = true
        return p
    }
}
