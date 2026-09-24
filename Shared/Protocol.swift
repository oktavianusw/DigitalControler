//
//  Protocol.swift
//  Shared between the iOS app and the Mac helper.
//

import Foundation
import Network
import CryptoKit

let serviceType = "_digitalctl._tcp"
/// Bump when `Message` changes shape. It's mixed into the TLS key, so an app and a Mac helper from
/// different versions fail the handshake instead of misreading each other's bytes as clicks and keys.
let protocolVersion = 2
/// Fixed so the pairing QR code's IP fallback works without Bonjour. The Mac falls back to any free port if it's taken.
let servicePort: UInt16 = 51515

/// Fixed-size wire message: 1 byte kind + two little-endian Float32 + little-endian UInt32 time.
/// Fixed size means no framing: the receiver just reads `Message.size` bytes at a time.
struct Message: Equatable {
    enum Kind: UInt8, CaseIterable {
        case move, leftClick, rightClick
        case scroll      // dx/dy: finger delta in pixels
        case scrollEnd   // dx/dy: finger velocity in px/s, for momentum
        case leftDown, leftUp
        case action      // dx: Action raw value
        case key         // dx: Mac virtual key code, dy: Modifiers raw value
        case text        // dx: one Unicode scalar, typed as-is (layout independent)
        case ping        // dx: sequence number; the Mac echoes it back for the latency readout
        case rightDown, rightUp
        case screenStart // dx: longest edge in pixels, dy: display index, or -1 for thumbnails of every display
        case screenStop
        case moveTo      // dx/dy: 0...1 across the shared screen, so it's independent of resolution
    }

    /// Mac actions that aren't plain key presses (system shortcuts, media keys).
    enum Action: UInt8, CaseIterable {
        case missionControl, appExpose, spaceLeft, spaceRight, zoomIn, zoomOut
        case volumeDown, volumeUp, playPause
    }

    struct Modifiers: OptionSet {
        let rawValue: UInt8
        static let shift = Modifiers(rawValue: 1 << 0)
        static let control = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
        static let function = Modifiers(rawValue: 1 << 4)
    }
    static let size = 13

    var kind: Kind
    var dx: Float = 0
    var dy: Float = 0
    /// When it happened on the iPhone, in ms (see `clock`). Lets the Mac replay moves at the finger's pace.
    var time: UInt32 = 0

    var data: Data {
        var d = Data([kind.rawValue])
        for v in [dx, dy] {
            withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) }
        }
        withUnsafeBytes(of: time.littleEndian) { d.append(contentsOf: $0) }
        return d
    }

    /// Seconds of system uptime (UIEvent timestamps, ProcessInfo.systemUptime) as wire time.
    /// Wraps after 49 days; only differences between messages are ever used.
    static func clock(_ seconds: TimeInterval) -> UInt32 {
        UInt32(truncatingIfNeeded: Int64(seconds * 1000))
    }
}

extension Message {
    /// Returns nil for anything malformed — this is data from the network.
    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count == Self.size, let kind = Kind(rawValue: b[0]) else { return nil }
        func uint(_ i: Int) -> UInt32 {
            UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
        }
        let dx = Float(bitPattern: uint(1)), dy = Float(bitPattern: uint(5))
        // 0x10FFFF (largest Unicode scalar) must fit for .text; anything past that is garbage.
        guard dx.isFinite, dy.isFinite, abs(dx) <= 0x10FFFF, abs(dy) <= 0x10FFFF else { return nil }
        self.init(kind: kind, dx: dx, dy: dy, time: uint(9))
    }
}

/// Mac → iPhone messages vary in size (a screen frame is ~100 KB), so each carries a
/// 5-byte header: 1 byte kind + little-endian UInt32 payload length.
enum Downstream: UInt8 {
    case pong         // payload: the iPhone's ping message, echoed back
    case frame        // payload: 1 byte display index, then one JPEG of that display
    case screenError  // payload: UTF-8 reason the screen can't be shared
    case displays     // payload: UTF-8 display names, one per line, left to right as arranged on the Mac
    case videoFormat  // payload: 1 byte display index, 1 byte count, then per H.264 parameter set (SPS, PPS):
                      //          UInt16 little-endian length + bytes. Sent before every keyframe.
    case videoFrame   // payload: 1 byte display index, then one H.264 frame in AVCC form (4-byte length-prefixed NAL units)

    static let headerSize = 5
    static let maxPayload = 8 << 20 // a frame is ~100 KB; anything near this is garbage

    func packet(_ payload: Data) -> Data {
        var d = Data([rawValue])
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { d.append(contentsOf: $0) }
        return d + payload
    }

    /// Kind and payload length from a header, nil if malformed. The kind is nil for messages from a newer
    /// Mac helper this app doesn't know yet: skip their payload rather than lose track of the stream.
    static func header(_ data: Data) -> (kind: Downstream?, length: Int)? {
        let b = [UInt8](data)
        guard b.count == headerSize else { return nil }
        let length = Int(UInt32(b[1]) | UInt32(b[2]) << 8 | UInt32(b[3]) << 16 | UInt32(b[4]) << 24)
        return length <= maxPayload ? (Downstream(rawValue: b[0]), length) : nil
    }
}

extension NWParameters {
    /// TCP + TLS with a pre-shared key derived from the pairing secret, so a wrong secret fails the handshake.
    /// Same approach as Apple's "Building a custom peer-to-peer protocol" sample. The secret is 256 random bits
    /// handed over by QR code, so it can't be guessed or brute-forced from a recorded handshake.
    static func paired(secret: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = HMAC<SHA256>.authenticationCode(for: Data("\(serviceType)/\(protocolVersion)".utf8),
                                                  using: SymmetricKey(data: Data(secret.utf8)))
        let keyData = Data(key).withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("DigitalControler".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, keyData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        // Every connection must prove the current secret. With resumption on, a phone that paired once could
        // skip the key check with a saved session ticket, even with a wrong key or after "Reset pairing".
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        // Tells iOS and the Wi-Fi router this is latency-critical, like a voice call, so small packets
        // aren't held back and batched by Wi-Fi power saving (a big source of pointer stutter).
        params.serviceClass = .interactiveVoice
        return params
    }
}

/// H.264 parameter sets (SPS, PPS) ↔ `Downstream.videoFormat` payload body (after the display index).
enum ParameterSets {
    static func encode(_ sets: [Data]) -> Data {
        var d = Data([UInt8(sets.count)])
        for s in sets {
            withUnsafeBytes(of: UInt16(s.count).littleEndian) { d.append(contentsOf: $0) }
            d.append(s)
        }
        return d
    }

    static func decode(_ data: Data) -> [Data]? {
        let b = [UInt8](data)
        guard let count = b.first else { return nil }
        var sets: [Data] = [], i = 1
        for _ in 0..<count {
            guard i + 2 <= b.count else { return nil }
            let n = Int(b[i]) | Int(b[i + 1]) << 8
            i += 2
            guard i + n <= b.count else { return nil }
            sets.append(Data(b[i..<i + n]))
            i += n
        }
        return sets
    }
}

/// What the Mac's pairing QR code holds, as a link the iPhone's Camera app can open too:
/// `digitalcontroler://pair?name=<Bonjour name>&secret=<key>&host=<IPv4, for networks without Bonjour>`
struct PairingCode: Equatable {
    static let scheme = "digitalcontroler"

    let name: String
    let secret: String
    var host: String?

    var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "pair"
        c.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "secret", value: secret)]
            + (host.map { [URLQueryItem(name: "host", value: $0)] } ?? [])
        return c.url!
    }

    /// Nil for anything that isn't a pairing link with a real secret (it came from a camera, so treat it as untrusted).
    init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == Self.scheme, c.host == "pair" else { return nil }
        let items = c.queryItems ?? []
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        guard let name = value("name"), !name.isEmpty, name.count <= 255,
              let secret = value("secret"), secret.count >= 32, secret.count <= 128 else { return nil }
        self.init(name: name, secret: secret, host: value("host"))
    }

    init(name: String, secret: String, host: String?) {
        self.name = name
        self.secret = secret
        self.host = host
    }

    /// 256 random bits, URL-safe.
    static func newSecret() -> String {
        var rng = SystemRandomNumberGenerator() // cryptographically secure
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
