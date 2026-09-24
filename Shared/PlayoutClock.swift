//
//  PlayoutClock.swift
//  Shared between the iOS app and the Mac helper (used by the Mac; here so the iOS tests cover it).
//

import Foundation

/// A jitter buffer's clock. Wi-Fi delivers moves in bursts (three at once, then nothing for 30 ms); played as
/// they arrive, the pointer lurches. This maps each message's iPhone time onto the Mac's clock so it can be
/// played at the pace the finger actually moved: the fastest recent trip sets the baseline, every message
/// plays `buffer` after its baseline time, and anything later than that plays at once.
struct PlayoutClock {
    // ponytail: fixed buffer; make it adaptive (track recent jitter) if the menu's jitter readout says so.
    var buffer: TimeInterval = 0.015
    /// How long the fastest trip is remembered. Short enough to follow clock drift between the devices.
    var window: TimeInterval = 2

    private var samples: [(at: TimeInterval, delay: TimeInterval)] = []
    private var lastStamp: UInt32?
    private var senderTime: TimeInterval = 0

    /// Spread between the slowest and fastest trip in the window: how bursty the network is right now.
    private(set) var jitter: TimeInterval = 0

    /// When (local seconds) to play a message stamped `stamp` that arrived at `now`.
    mutating func due(stamp: UInt32, arrivedAt now: TimeInterval) -> TimeInterval {
        // Wrapping difference, so the UInt32 rolling over is just another step forward.
        if let last = lastStamp { senderTime += TimeInterval(Int32(bitPattern: stamp &- last)) / 1000 }
        lastStamp = stamp

        let delay = now - senderTime // one-way trip plus the (unknown, constant) offset between the clocks
        samples.removeAll { now - $0.at > window }
        samples.append((now, delay))
        let fastest = samples.map(\.delay).min() ?? delay
        jitter = (samples.map(\.delay).max() ?? delay) - fastest
        return senderTime + fastest + buffer
    }
}
