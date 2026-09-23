//
//  Protocol.swift
//  Shared between the iOS app and the Mac helper.
//

import Foundation
import Network
import CryptoKit

let serviceType = "_digitalctl._tcp"
/// Fixed so "Enter IP manually" works without Bonjour. The Mac falls back to any free port if it's taken.
let servicePort: UInt16 = 51515

/// Fixed-size wire message: 1 byte kind + two little-endian Float32.
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
    static let size = 9

    var kind: Kind
    var dx: Float = 0
    var dy: Float = 0

    var data: Data {
        var d = Data([kind.rawValue])
        for v in [dx, dy] {
            withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }
}

extension Message {
    /// Returns nil for anything malformed — this is data from the network.
    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count == Self.size, let kind = Kind(rawValue: b[0]) else { return nil }
        func float(_ i: Int) -> Float {
            Float(bitPattern: UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24)
        }
        let dx = float(1), dy = float(5)
        // 0x10FFFF (largest Unicode scalar) must fit for .text; anything past that is garbage.
        guard dx.isFinite, dy.isFinite, abs(dx) <= 0x10FFFF, abs(dy) <= 0x10FFFF else { return nil }
        self.init(kind: kind, dx: dx, dy: dy)
    }
}

extension NWParameters {
    /// TCP + TLS with a pre-shared key derived from the pairing PIN, so a wrong PIN fails the handshake.
    /// Same approach as Apple's "Building a custom peer-to-peer protocol" sample.
    // ponytail: 6-digit PIN is brute-forceable offline from a sniffed handshake; upgrade to a long random key shared via QR code if that matters.
    static func paired(pin: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = HMAC<SHA256>.authenticationCode(for: Data(serviceType.utf8), using: SymmetricKey(data: Data(pin.utf8)))
        let keyData = Data(key).withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("DigitalControler".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, keyData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)

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
