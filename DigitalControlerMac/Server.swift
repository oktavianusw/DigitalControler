//
//  Server.swift
//  DigitalControlerMac
//

import Foundation
import ApplicationServices
import Network
import Observation
import os

let log = Logger(subsystem: "com.jua.DigitalControlerMac", category: "server")

/// Advertises this Mac over Bonjour and feeds messages from one paired iPhone into `Injector`.
@Observable
final class Server {
    // ponytail: secret in UserDefaults like the old PIN; move to the Keychain if other local apps are a concern.
    private(set) var secret = UserDefaults.standard.string(forKey: "secret") ?? PairingCode.newSecret()
    private(set) var status = "Starting…"
    private var listener: NWListener?
    private var connection: NWConnection?
    private var failedAttempts = 0
    private let screen = ScreenStreamer()
    private(set) var sharingScreen = false

    init() { start() }

    /// What the pairing QR code shows. The name is the Bonjour name the iPhone looks for.
    var pairingCode: PairingCode {
        PairingCode(name: Host.current().localizedName ?? "Mac", secret: secret, host: Self.localIPv4)
    }

    /// New secret: every paired iPhone has to scan the QR code again.
    func resetPairing() {
        secret = PairingCode.newSecret()
        start()
    }

    /// The Mac's Wi-Fi/Ethernet address, for iPhones on networks that block Bonjour.
    private static var localIPv4: String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  String(cString: ifa.pointee.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            return String(cString: host)
        }
        return nil
    }

    private func start(fixedPort: Bool = true) {
        UserDefaults.standard.set(secret, forKey: "secret")
        listener?.cancel()
        connection?.cancel()
        connection = nil
        endSession()
        failedAttempts = 0
        do {
            let params = NWParameters.paired(secret: secret)
            params.allowLocalEndpointReuse = true
            let l = fixedPort ? try NWListener(using: params, on: NWEndpoint.Port(rawValue: servicePort)!) : try NWListener(using: params)
            l.service = NWListener.Service(name: Host.current().localizedName, type: serviceType)
            l.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: self?.status = "Waiting for iPhone…"
                    case .failed where fixedPort: self?.start(fixedPort: false) // port taken: Bonjour still works on any port
                    case .failed(let e): self?.status = "Error: \(e.localizedDescription)"
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] c in
                MainActor.assumeIsolated { self?.accept(c) }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }

    private func accept(_ c: NWConnection) {
        c.stateUpdateHandler = { [weak self, weak c] state in
            MainActor.assumeIsolated {
                if let c { self?.connection(c, changedTo: state) }
            }
        }
        c.start(queue: .main)
    }

    private func connection(_ c: NWConnection, changedTo state: NWConnection.State) {
        switch state {
        case .ready:
            failedAttempts = 0
            connection?.cancel() // one iPhone at a time, newest wins
            endSession()
            connection = c
            status = "Connected"
            log.notice("iPhone connected, accessibility trusted: \(AXIsProcessTrusted())")
            receive(on: c)
        case .failed, .waiting:
            c.cancel()
            if connection === c {
                connection = nil
                status = "Waiting for iPhone…"
                endSession()
            } else {
                handshakeFailed() // never got ready: wrong secret (e.g. paired before a reset)
            }
        case .cancelled where connection === c:
            connection = nil
            status = "Waiting for iPhone…"
            endSession()
        default: break
        }
    }

    /// The iPhone went away (or was replaced): release held buttons and stop sharing the screen.
    private func endSession() {
        Injector.reset()
        screen.stop()
        sharingScreen = false
    }

    /// Stops a misbehaving client hammering the listener: after 10 failed handshakes, stop listening
    /// until the user resets pairing. (Guessing a 256-bit secret is hopeless anyway.)
    private func handshakeFailed() {
        failedAttempts += 1
        guard failedAttempts >= 10 else { return }
        listener?.cancel()
        listener = nil
        status = "Locked: too many failed connections. Reset pairing to reopen."
    }

    private func handle(_ m: Message, raw: Data, from c: NWConnection) {
        guard c === connection else { return }
        switch m.kind {
        case .ping:
            c.send(content: Downstream.pong.packet(raw), completion: .idempotent) // for the iPhone's latency readout
        case .screenStart:
            sharingScreen = true
            screen.start(maxEdge: Int(m.dx), display: m.dy < 0 ? nil : Int(m.dy)) { [weak c] bytes, done in
                guard let c else { return done(false) }
                c.send(content: bytes, completion: .contentProcessed { done($0 == nil) })
            }
        case .screenStop:
            screen.stop()
            sharingScreen = false
        case .moveTo:
            Injector.moveTo(x: CGFloat(m.dx), y: CGFloat(m.dy),
                            on: screen.displayBounds ?? CGDisplayBounds(CGMainDisplayID()))
        default:
            Injector.handle(m)
        }
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: Message.size, maximumLength: Message.size) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                if let data, let m = Message(data) { self?.handle(m, raw: data, from: c) }
                if error == nil, !isComplete { self?.receive(on: c) }
            }
        }
    }
}
