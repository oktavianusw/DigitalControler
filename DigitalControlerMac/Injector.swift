//
//  Injector.swift
//  DigitalControlerMac
//

import AppKit
import CoreGraphics

/// Turns wire messages into real mouse events. Needs Accessibility permission, or macOS silently drops them.
enum Injector {
    private static var lastClick = (time: Date.distantPast, button: CGMouseButton.left, count: 0)
    private static var leftIsDown = false
    private static var rightIsDown = false
    private static var scrolling = false
    private static var scrollResidual = CGPoint.zero
    private static var momentum: Timer?
    private static var momentumVelocity = CGPoint.zero
    private static var momentumStarted = false

    static func handle(_ m: Message) {
        let dx = CGFloat(m.dx), dy = CGFloat(m.dy)
        switch m.kind {
        case .move: move(dx: dx, dy: dy)
        case .leftClick: click(.left)
        case .rightClick: click(.right)
        case .leftDown:
            leftIsDown = true
            post(.leftMouseDown, .left, clickCount: 1)
        case .leftUp:
            leftIsDown = false
            post(.leftMouseUp, .left, clickCount: 1)
        case .rightDown:
            rightIsDown = true
            post(.rightMouseDown, .right, clickCount: 1)
        case .rightUp:
            rightIsDown = false
            post(.rightMouseUp, .right, clickCount: 1)
        case .scroll: scroll(dx: dx, dy: dy)
        case .scrollEnd: endScroll(vx: dx, vy: dy)
        case .action:
            if let raw = UInt8(exactly: m.dx), let action = Message.Action(rawValue: raw) { perform(action) }
        case .key:
            if let code = UInt16(exactly: m.dx), let mods = UInt8(exactly: m.dy) {
                press(code, flags(Message.Modifiers(rawValue: mods)))
            }
        case .text:
            if let raw = UInt32(exactly: m.dx), let scalar = Unicode.Scalar(raw) { type(scalar) }
        case .ping, .screenStart, .screenStop, .moveTo: break // handled by Server
        }
    }

    // MARK: Actions (keyboard shortcuts)

    private static func perform(_ action: Message.Action) {
        // Control+arrows with the Fn flag: exactly how macOS stores its Mission Control / Spaces shortcuts.
        let system: CGEventFlags = [.maskControl, .maskSecondaryFn]
        switch action {
        case .missionControl: press(126, system) // ↑
        case .appExpose: press(125, system)      // ↓
        case .spaceLeft: press(123, system)      // ←
        case .spaceRight: press(124, system)     // →
        case .zoomIn: press(24, .maskCommand)    // ⌘=
        case .zoomOut: press(27, .maskCommand)   // ⌘-
        case .volumeDown: mediaKey(1)            // NX_KEYTYPE_SOUND_DOWN
        case .volumeUp: mediaKey(0)              // NX_KEYTYPE_SOUND_UP
        case .playPause: mediaKey(16)            // NX_KEYTYPE_PLAY
        }
    }

    private static func flags(_ m: Message.Modifiers) -> CGEventFlags {
        var f: CGEventFlags = []
        if m.contains(.shift) { f.insert(.maskShift) }
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.option) { f.insert(.maskAlternate) }
        if m.contains(.command) { f.insert(.maskCommand) }
        if m.contains(.function) { f.insert(.maskSecondaryFn) }
        return f
    }

    /// Types any character regardless of the Mac's keyboard layout (emoji included).
    private static func type(_ scalar: Unicode.Scalar) {
        if scalar == "\n" { return press(36, []) } // Return
        let utf16 = Array(String(scalar).utf16)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            e?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Media keys aren't key codes: they're "system defined" events, same as the F-row on a Mac keyboard.
    private static func mediaKey(_ key: Int) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            NSEvent.otherEvent(with: .systemDefined, location: .zero,
                               modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                               timestamp: 0, windowNumber: 0, context: nil,
                               subtype: 8, data1: (key << 16) | (state << 8), data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private static func press(_ key: CGKeyCode, _ flags: CGEventFlags) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
        // macOS keeps the last posted modifiers as "held". Without this, ⌃ from a shortcut stays down and
        // every later click, even from a real mouse, becomes ⌃-click, which is a right click.
        if !flags.isEmpty {
            let release = CGEvent(source: nil)
            release?.type = .flagsChanged
            release?.flags = []
            release?.post(tap: .cghidEventTap)
        }
    }

    /// The iPhone went away mid-gesture: never leave the mouse button stuck down or a scroll half-open.
    static func reset() {
        if leftIsDown { handle(Message(kind: .leftUp)) }
        if rightIsDown { handle(Message(kind: .rightUp)) }
        endScroll(vx: 0, vy: 0)
        stopMomentum()
    }

    // MARK: Pointer

    private static var lastPosted = (point: CGPoint.zero, at: Date.distantPast)

    /// Where the cursor is. Posted events take a moment to land, so reading the real position right after a
    /// burst of moves returns a stale point and swallows movement (the "stutter"). While we're actively
    /// moving it, trust where we last put it; otherwise read the real one (the Mac's own mouse may have moved).
    private static var cursor: CGPoint {
        Date().timeIntervalSince(lastPosted.at) < 0.1 ? lastPosted.point : (CGEvent(source: nil)?.location ?? .zero)
    }

    private static func move(dx: CGFloat, dy: CGFloat) {
        let from = cursor
        let to = clamp(CGPoint(x: from.x + dx, y: from.y + dy), from: from, screens: screens)
        CGEvent(mouseEventSource: nil, mouseType: leftIsDown ? .leftMouseDragged : .mouseMoved,
                mouseCursorPosition: to, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        lastPosted = (to, Date())
    }

    /// Puts the pointer at a spot on the shared screen: `x`/`y` run 0...1 across `display`.
    static func moveTo(x: CGFloat, y: CGFloat, on display: CGRect) {
        let p = CGPoint(x: display.minX + min(max(x, 0), 1) * (display.width - 1),
                        y: display.minY + min(max(y, 0), 1) * (display.height - 1))
        CGEvent(mouseEventSource: nil, mouseType: leftIsDown ? .leftMouseDragged : .mouseMoved,
                mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        lastPosted = (p, Date())
    }

    private static func click(_ button: CGMouseButton) {
        // Click count makes a quick second tap a real double-click (open files in Finder, select words).
        let now = Date()
        let isRepeat = now.timeIntervalSince(lastClick.time) < NSEvent.doubleClickInterval && lastClick.button == button
        lastClick = (now, button, isRepeat ? lastClick.count + 1 : 1)

        let (down, up): (CGEventType, CGEventType) = button == .left ? (.leftMouseDown, .leftMouseUp) : (.rightMouseDown, .rightMouseUp)
        post(down, button, clickCount: lastClick.count)
        post(up, button, clickCount: lastClick.count)
    }

    private static func post(_ type: CGEventType, _ button: CGMouseButton, clickCount: Int) {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cursor, mouseButton: button)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        e?.post(tap: .cghidEventTap)
    }

    /// Global display rects (top-left origin, same space as CGEvent locations).
    private static var screens: [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).map(CGDisplayBounds)
    }

    /// Keeps the cursor on some screen: free movement across displays, clamped at outer edges.
    static func clamp(_ p: CGPoint, from: CGPoint, screens: [CGRect]) -> CGPoint {
        if screens.contains(where: { $0.contains(p) }) { return p }
        guard let s = screens.first(where: { $0.contains(from) }) ?? screens.first else { return p }
        return CGPoint(x: min(max(p.x, s.minX), s.maxX - 1), y: min(max(p.y, s.minY), s.maxY - 1))
    }

    // MARK: Scroll
    // Trackpad-style events: continuous pixel deltas plus scroll/momentum phases,
    // which is what gives apps rubber-banding and smooth deceleration.

    private enum ScrollPhase { static let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4 }
    private enum MomentumPhase { static let begin: Int64 = 1, `continue`: Int64 = 2, end: Int64 = 3 }

    private static func scroll(dx: CGFloat, dy: CGFloat) {
        stopMomentum() // fingers back on the glass stop the fling, like a real trackpad
        postScroll(dx: dx, dy: dy, phase: scrolling ? ScrollPhase.changed : ScrollPhase.began)
        scrolling = true
    }

    private static func endScroll(vx: CGFloat, vy: CGFloat) {
        guard scrolling else { return }
        scrolling = false
        postScroll(dx: 0, dy: 0, phase: ScrollPhase.ended)
        guard hypot(vx, vy) > 60 else { return }

        // Momentum runs here, not on the iPhone, so Wi-Fi jitter can't make the glide stutter.
        momentumVelocity = CGPoint(x: vx, y: vy)
        momentumStarted = false
        let hz = 120.0
        momentum = Timer.scheduledTimer(withTimeInterval: 1 / hz, repeats: true) { _ in
            MainActor.assumeIsolated {
                // ponytail: hand-tuned friction; lower = stops sooner.
                momentumVelocity.x *= 0.985
                momentumVelocity.y *= 0.985
                guard hypot(momentumVelocity.x, momentumVelocity.y) > 15 else { return stopMomentum() }
                postScroll(dx: momentumVelocity.x / hz, dy: momentumVelocity.y / hz,
                           momentum: momentumStarted ? MomentumPhase.continue : MomentumPhase.begin)
                momentumStarted = true
            }
        }
    }

    private static func stopMomentum() {
        guard let timer = momentum else { return }
        timer.invalidate()
        momentum = nil
        if momentumStarted { postScroll(dx: 0, dy: 0, momentum: MomentumPhase.end) }
    }

    private static func postScroll(dx: CGFloat, dy: CGFloat, phase: Int64 = 0, momentum: Int64 = 0) {
        // The iPhone already applied its Natural scrolling setting. Positive wheel = content moves down/right.
        // Events carry whole pixels; keep the fractions so slow scrolls still move.
        scrollResidual.x += dx
        scrollResidual.y += dy
        let px = scrollResidual.x.rounded(.towardZero), py = scrollResidual.y.rounded(.towardZero)
        scrollResidual.x -= px
        scrollResidual.y -= py

        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: Int32(py), wheel2: Int32(px), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        e.post(tap: .cghidEventTap)
    }
}
