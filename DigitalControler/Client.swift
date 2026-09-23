//
//  Client.swift
//  DigitalControler
//

import Foundation
import Network
import Observation

/// Finds Macs running the helper and holds the connection to the chosen one.
@Observable
final class Client {
    private(set) var macs: [NWBrowser.Result] = []
    private(set) var connected = false
    private(set) var macName = ""
    /// Lost the Mac mid-use and trying to get it back: the remote screen stays up meanwhile.
    private(set) var reconnecting = false
    /// Round trip to the Mac and back, refreshed every couple of seconds while connected.
    private(set) var latencyMs: Int?
    var connecting: Bool { connection != nil && !connected }
    var error: String?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    /// Off once the user taps Disconnect or an automatic attempt fails, so we never fight the user.
    private var autoReconnect = true
    private var lastAutoConnect = Date.distantPast
    private var pingTimer: Timer?
    private var pingSeq = 0
    private var pingSentAt = Date.distantPast

    func startBrowsing() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                self?.macs = results.sorted { $0.endpoint.name < $1.endpoint.name }
                self?.autoConnect() // the last Mac just showed up: connect without asking
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .failed(let e) = state { self?.error = "Can't search the network: \(e.localizedDescription)" }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func connect(to endpoint: NWEndpoint, pin: String) {
        autoReconnect = true
        open(endpoint, pin: pin, auto: false)
    }

    /// For networks where Bonjour is blocked: the Mac listens on a fixed port.
    func connect(host: String, pin: String) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        connect(to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: servicePort)!), pin: pin)
    }

    static var lastMac: String? { UserDefaults.standard.string(forKey: "lastMac") }

    func disconnect() {
        autoReconnect = false
        reconnecting = false
        close()
    }

    func send(_ m: Message) {
        connection?.send(content: m.data, completion: .idempotent)
    }

    static func savedPin(for endpoint: NWEndpoint) -> String {
        UserDefaults.standard.string(forKey: "pin." + endpoint.name) ?? ""
    }

    // MARK: Private

    private func autoConnect() {
        guard autoReconnect, connection == nil,
              let name = UserDefaults.standard.string(forKey: "lastMac"),
              let mac = macs.first(where: { $0.endpoint.name == name })?.endpoint,
              let pin = UserDefaults.standard.string(forKey: "pin." + name) else { return }
        // Dropped again right after reconnecting: likely another device took over the Mac. Don't fight it.
        guard Date().timeIntervalSince(lastAutoConnect) > 10 else {
            autoReconnect = false
            error = "Lost connection to \(name). Another device may be using it."
            return
        }
        lastAutoConnect = Date()
        open(mac, pin: pin, auto: true)
    }

    private func open(_ endpoint: NWEndpoint, pin: String, auto: Bool) {
        close()
        let c = NWConnection(to: endpoint, using: .paired(pin: pin))
        c.stateUpdateHandler = { [weak self, weak c] state in
            MainActor.assumeIsolated {
                if let c { self?.connection(c, to: endpoint, pin: pin, auto: auto, changedTo: state) }
            }
        }
        connection = c
        c.start(queue: .main)
        // A wrong PIN makes Network.framework retry other addresses forever instead of failing, so give up ourselves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, c === connection, !connected else { return }
            close()
            failed(auto: auto, name: endpoint.name)
        }
    }

    private func connection(_ c: NWConnection, to endpoint: NWEndpoint, pin: String, auto: Bool, changedTo state: NWConnection.State) {
        guard c === connection else { return } // stale connection we already replaced
        switch state {
        case .ready:
            connected = true
            reconnecting = false
            macName = endpoint.name
            UserDefaults.standard.set(pin, forKey: "pin." + endpoint.name)
            UserDefaults.standard.set(endpoint.name, forKey: "lastMac")
            receive(on: c)
            ping()
            pingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.ping() }
            }
        case .waiting, .failed:
            let wasConnected = connected
            close()
            if wasConnected {
                // Dropped mid-use (Wi-Fi blip, Mac helper restarted): get back on our own.
                reconnecting = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self else { return }
                    autoConnect()
                    if connection == nil { reconnecting = false } // the Mac is gone from the network
                }
            } else {
                failed(auto: auto, name: endpoint.name)
            }
        default: break
        }
    }

    private func failed(auto: Bool, name: String) {
        reconnecting = false
        if auto {
            autoReconnect = false
            error = "Couldn't reconnect to \(name). Tap it to try again."
        } else {
            error = "Couldn't connect. Check the PIN in your Mac's menu bar."
        }
    }

    private func ping() {
        pingSeq = (pingSeq + 1) % 1_000_000
        pingSentAt = Date()
        send(Message(kind: .ping, dx: Float(pingSeq)))
    }

    /// The Mac only ever sends back ping echoes.
    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: Message.size, maximumLength: Message.size) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                self?.received(data, on: c)
                if error == nil, !isComplete { self?.receive(on: c) }
            }
        }
    }

    private func received(_ data: Data?, on c: NWConnection) {
        guard c === connection, let data, let m = Message(data), m.kind == .ping, Int(m.dx) == pingSeq else { return }
        latencyMs = max(1, Int(Date().timeIntervalSince(pingSentAt) * 1000))
    }

    private func close() {
        pingTimer?.invalidate()
        pingTimer = nil
        latencyMs = nil
        connection?.cancel()
        connection = nil
        connected = false
    }
}

extension NWEndpoint {
    var name: String {
        if case .service(let name, _, _, _) = self { return name }
        return debugDescription
    }
}
