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
    private(set) var pin = UserDefaults.standard.string(forKey: "pin") ?? Server.randomPin()
    private(set) var status = "Starting…"
    private var listener: NWListener?
    private var connection: NWConnection?
    private var failedAttempts = 0
    private let screen = ScreenStreamer()
    private(set) var sharingScreen = false

    init() { start() }

    func newPin() {
        pin = Self.randomPin()
        start()
    }

    private static func randomPin() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000)) // SystemRandomNumberGenerator is crypto-secure
    }

    private func start(fixedPort: Bool = true) {
        UserDefaults.standard.set(pin, forKey: "pin")
        listener?.cancel()
        connection?.cancel()
        connection = nil
        endSession()
        failedAttempts = 0
        do {
            let params = NWParameters.paired(pin: pin)
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
                handshakeFailed() // never got ready: wrong PIN
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

    /// Stops online PIN guessing: after 10 wrong PINs, stop listening until the user makes a new PIN.
    private func handshakeFailed() {
        failedAttempts += 1
        guard failedAttempts >= 10 else { return }
        listener?.cancel()
        listener = nil
        status = "Locked: too many wrong PINs. Click New PIN."
    }

    private func handle(_ m: Message, raw: Data, from c: NWConnection) {
        guard c === connection else { return }
        switch m.kind {
        case .ping:
            c.send(content: Downstream.pong.packet(raw), completion: .idempotent) // for the iPhone's latency readout
        case .screenStart:
            sharingScreen = true
            screen.start(maxEdge: Int(m.dx), display: m.dy < 0 ? nil : Int(m.dy)) { [weak c] kind, payload in
                await withCheckedContinuation { done in
                    guard let c else { return done.resume(returning: false) }
                    c.send(content: kind.packet(payload), completion: .contentProcessed { done.resume(returning: $0 == nil) })
                }
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
