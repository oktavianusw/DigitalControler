//
//  Client.swift
//  DigitalControler
//

import Foundation
import Network
import Observation
import UIKit

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
    /// The Mac's displays (names, left to right) and the latest picture of each, while the Screen tab is open.
    private(set) var displays: [String] = []
    private(set) var screenFrames: [Int: UIImage] = [:]
    private(set) var screenError: String?
    /// The display shown large, nil while picking from thumbnails.
    private(set) var selectedDisplay: Int?
    /// The selected display's live H.264 video, and its pixel size once the first keyframe arrives.
    let video = VideoFeed()
    private(set) var videoSize: CGSize?
    private var sharingScreen = false // kept so a reconnect resumes the stream
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

    func connect(to endpoint: NWEndpoint, secret: String, pairingName: String? = nil) {
        autoReconnect = true
        open(endpoint, secret: secret, auto: false, pairingName: pairingName)
    }

    /// From a scanned QR code: connect by the Mac's Bonjour name, or by IP where Bonjour is blocked.
    /// The secret is only remembered once it actually works, so a stale code can't replace a good one.
    func pair(with code: PairingCode) {
        if let mac = macs.first(where: { $0.endpoint.name == code.name })?.endpoint {
            connect(to: mac, secret: code.secret, pairingName: code.name)
        } else if let host = code.host {
            connect(to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: servicePort)!),
                    secret: code.secret, pairingName: code.name)
        } else {
            error = "Can't find \(code.name) on this Wi-Fi. Make sure both are on the same network."
        }
    }

    private static let thumbnailEdge = 640

    func startScreen() {
        sharingScreen = true
        screenError = nil
        let display = selectedDisplay
        send(Message(kind: .screenStart,
                     dx: Float(display == nil ? Self.thumbnailEdge : ScreenQuality.current.maxEdge),
                     dy: Float(display ?? -1)))
    }

    /// Stops the Mac sending while the app is in the background, without forgetting what was on screen.
    func pauseScreen() {
        guard sharingScreen else { return }
        send(Message(kind: .screenStop))
    }

    /// Picks up where it left off (after `pauseScreen`, or with a new quality setting).
    func resumeScreen() {
        guard sharingScreen else { return }
        video.reset() // the Mac starts a new stream, beginning with a keyframe
        startScreen()
    }

    /// Show one display large, or nil to go back to thumbnails of all of them.
    func selectDisplay(_ index: Int?) {
        selectedDisplay = index
        video.reset()
        videoSize = nil
        screenFrames = screenFrames.filter { $0.key == index } // keep the thumbnail until the sharp frame lands
        startScreen()
    }

    func stopScreen() {
        sharingScreen = false
        selectedDisplay = nil
        video.reset()
        videoSize = nil
        screenFrames = [:]
        send(Message(kind: .screenStop))
    }

    static var lastMac: String? { UserDefaults.standard.string(forKey: Prefs.lastMac) }

    func disconnect() {
        autoReconnect = false
        reconnecting = false
        close()
    }

    func send(_ m: Message) {
        connection?.send(content: m.data, completion: .idempotent)
    }

    /// The pairing secret from this Mac's QR code, if it was ever scanned.
    static func savedSecret(for endpoint: NWEndpoint) -> String? {
        PairingSecrets.get(for: endpoint.name)
    }

    // MARK: Private

    private func autoConnect() {
        guard autoReconnect, connection == nil,
              let name = Self.lastMac,
              let mac = macs.first(where: { $0.endpoint.name == name })?.endpoint,
              let secret = PairingSecrets.get(for: name) else { return }
        // Dropped again right after reconnecting: likely another device took over the Mac. Don't fight it.
        guard Date().timeIntervalSince(lastAutoConnect) > 10 else {
            autoReconnect = false
            error = "Lost connection to \(name). Another device may be using it."
            return
        }
        lastAutoConnect = Date()
        open(mac, secret: secret, auto: true)
    }

    /// `pairingName`: the Mac's Bonjour name from a QR code, so a connection made by IP is remembered under it too.
    private func open(_ endpoint: NWEndpoint, secret: String, auto: Bool, pairingName: String? = nil) {
        close()
        let c = NWConnection(to: endpoint, using: .paired(secret: secret))
        c.stateUpdateHandler = { [weak self, weak c] state in
            MainActor.assumeIsolated {
                if let c { self?.connection(c, to: endpoint, secret: secret, auto: auto, pairingName: pairingName, changedTo: state) }
            }
        }
        connection = c
        c.start(queue: .main)
        // A wrong secret makes Network.framework retry other addresses forever instead of failing, so give up ourselves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, c === connection, !connected else { return }
            close()
            failed(auto: auto, name: endpoint.name)
        }
    }

    private func connection(_ c: NWConnection, to endpoint: NWEndpoint, secret: String, auto: Bool, pairingName: String?,
                            changedTo state: NWConnection.State) {
        guard c === connection else { return } // stale connection we already replaced
        switch state {
        case .ready:
            connected = true
            reconnecting = false
            macName = endpoint.name
            PairingSecrets.set(secret, for: endpoint.name)
            if let pairingName { PairingSecrets.set(secret, for: pairingName) }
            UserDefaults.standard.set(endpoint.name, forKey: Prefs.lastMac)
            receive(on: c)
            if sharingScreen { startScreen() } // reconnected mid-share
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
            error = "Couldn't reconnect to \(name). If pairing was reset on the Mac, scan its QR code again (menu bar → Pair iPhone…)."
        } else {
            error = "Couldn't connect. If pairing was reset on the Mac, scan its QR code again (menu bar → Pair iPhone…)."
        }
    }

    private func ping() {
        pingSeq = (pingSeq + 1) % 1_000_000
        pingSentAt = Date()
        send(Message(kind: .ping, dx: Float(pingSeq)))
    }

    /// Mac → iPhone: a 5-byte header, then that many bytes of payload.
    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: Downstream.headerSize, maximumLength: Downstream.headerSize) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, error == nil, !isComplete, let data, let header = Downstream.header(data) else { return }
                guard header.length > 0 else {
                    if let kind = header.kind { self.received(kind, Data(), on: c) }
                    return self.receive(on: c)
                }
                c.receive(minimumIncompleteLength: header.length, maximumLength: header.length) { payload, _, isComplete, error in
                    MainActor.assumeIsolated {
                        guard error == nil, let payload else { return }
                        if let kind = header.kind { self.received(kind, payload, on: c) } // unknown kinds: skipped
                        if !isComplete { self.receive(on: c) }
                    }
                }
            }
        }
    }

    private func received(_ kind: Downstream, _ payload: Data, on c: NWConnection) {
        guard c === connection else { return }
        switch kind {
        case .pong:
            guard let m = Message(payload), m.kind == .ping, Int(m.dx) == pingSeq else { return }
            latencyMs = max(1, Int(Date().timeIntervalSince(pingSentAt) * 1000))
        case .frame:
            guard sharingScreen, let index = payload.first.map(Int.init),
                  selectedDisplay == nil || selectedDisplay == index, // drop thumbnails still in flight
                  let image = UIImage(data: payload.dropFirst()) else { return }
            screenFrames[index] = image
            screenError = nil
        case .displays:
            displays = String(decoding: payload, as: UTF8.self).split(separator: "\n").map(String.init)
            if displays.count == 1, selectedDisplay == nil { selectDisplay(0) } // nothing to pick from
        case .videoFormat:
            guard sharingScreen, let index = payload.first.map(Int.init), index == selectedDisplay,
                  let sets = ParameterSets.decode(payload.dropFirst()), let size = video.setFormat(sets) else { return }
            if videoSize != size { videoSize = size }
            screenError = nil
        case .videoFrame:
            guard sharingScreen, let index = payload.first.map(Int.init), index == selectedDisplay else { return }
            video.enqueue(payload.dropFirst())
        case .screenError:
            screenError = String(decoding: payload, as: UTF8.self)
        }
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
