//
//  Pacer.swift
//  DigitalControlerMac
//

import Foundation
import QuartzCore
import os

/// One line per move/scroll: iPhone time, arrival, due. Debug level, so it costs nothing unless streamed:
/// `log stream --level debug --predicate 'subsystem == "com.jua.DigitalControlerMac" AND category == "pacer"'`
private let trace = Logger(subsystem: "com.jua.DigitalControlerMac", category: "pacer")

/// Holds moves and scrolls until their `PlayoutClock` time, so the pointer follows the finger's rhythm
/// instead of Wi-Fi's. Everything else (clicks, keys) flushes what's held first, so a click always lands
/// where the pointer was meant to be.
final class Pacer {
    private var clock = PlayoutClock()
    private var held: [(due: TimeInterval, message: Message)] = []
    private var timer: Timer?
    private let play: (Message) -> Void

    /// Recent network jitter in ms, for the menu.
    var jitterMs: Int { Int((clock.jitter * 1000).rounded()) }

    init(play: @escaping (Message) -> Void) { self.play = play }

    func hold(_ m: Message) {
        let now = CACurrentMediaTime()
        let due = clock.due(stamp: m.time, arrivedAt: now)
        trace.debug("pace \(m.time) \(now, format: .fixed(precision: 6)) \(due, format: .fixed(precision: 6))")
        guard due > now || !held.isEmpty else { return play(m) } // late: play at once (keeping order)
        held.append((due, m))
        guard timer == nil else { return }
        // 240 Hz: finer than any display refresh, so a move is never more than ~4 ms off its time.
        let t = Timer(timeInterval: 1.0 / 240, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common) // keep going while the menu bar menu is open
        timer = t
    }

    /// Plays everything held, now.
    func flush() {
        held.forEach { play($0.message) }
        stop()
    }

    /// New iPhone (or none): forget the old one's timing and anything it left behind.
    func reset() {
        stop()
        clock = PlayoutClock()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let ready = held.prefix { $0.due <= now }
        ready.forEach { play($0.message) }
        held.removeFirst(ready.count)
        if held.isEmpty { stop() }
    }

    private func stop() {
        held = []
        timer?.invalidate()
        timer = nil
    }
}
