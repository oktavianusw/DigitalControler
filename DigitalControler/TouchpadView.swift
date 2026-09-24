//
//  TouchpadView.swift
//  DigitalControler
//

import SwiftUI
import UIKit

/// What the user turned on in Settings.
struct PadOptions {
    var pointerSpeed = 1.0
    var scrollSpeed = 1.0
    var naturalScrolling = true
    var tapToClick = true
    var twoFingerRightClick = true
    var haptics = true
    var fingerDots = true
}

/// Raw multi-touch surface. UIKit touches instead of SwiftUI gestures: we need every finger and every sample.
struct TouchpadView: UIViewRepresentable {
    let send: (Message) -> Void
    var options = PadOptions()
    /// Name of the gesture in progress ("Two-finger scroll"), nil when idle. Drives the hint badge.
    var onGesture: (String?) -> Void = { _ in }

    func makeUIView(context: Context) -> Pad { Pad() }
    func updateUIView(_ pad: Pad, context: Context) {
        pad.send = send
        pad.options = options
        pad.onGesture = onGesture
    }

    /// Pointer acceleration by finger speed in pt/s: slow = precise, fast flick = crosses the screen.
    /// An S-curve, so the gain eases in and out instead of kinking where it starts and where it tops out.
    // ponytail: hand-tuned curve; the Settings sliders scale it.
    static func gain(speed: CGFloat) -> CGFloat {
        let t = min(speed / 1500, 1)
        return 1.2 + 2.8 * t * t * (3 - 2 * t)
    }

    // ponytail: hand-tuned feel knobs.
    static let scrollGain: CGFloat = 1.6        // iPhone points -> Mac pixels
    static let tapMaxTravel: CGFloat = 10       // more movement than this is not a tap
    static let tapMaxDuration: TimeInterval = 0.3
    static let holdToDrag: TimeInterval = 0.35  // hold this long without moving to grab
    static let swipeDistance: CGFloat = 60      // three-finger travel that counts as a swipe
    static let pinchStep: CGFloat = 1.25        // finger spread ratio per zoom step
    static let twoFingerLanding: TimeInterval = 0.12 // a real two-finger tap lands together; later = a stray grip touch

    final class Pad: UIView {
        var send: (Message) -> Void = { _ in }
        var options = PadOptions()
        var onGesture: (String?) -> Void = { _ in }
        private var gesture: String? {
            didSet { if gesture != oldValue { onGesture(gesture) } }
        }
        private var scrollSign: CGFloat { options.naturalScrolling ? 1 : -1 }

        // Per-gesture state, reset when the first finger lands.
        private var maxFingers = 0
        private var travel: CGFloat = 0
        private var startTime: TimeInterval = 0
        private var lastTime: TimeInterval = 0
        private var scrolled = false    // this gesture scrolled at some point
        private var scrolling = false   // scroll in progress right now
        private var scrollVelocity = CGPoint.zero
        private var pointerSpeed: CGFloat = 0 // smoothed, so one jittery sample doesn't jerk the gain
        private var dragging = false
        private var holdTimer: Timer?
        private var pinching = false
        private var pinchBase: CGFloat = 0  // finger spread at two-finger start / last zoom step
        private var swipe = CGPoint.zero    // three-finger travel
        private var swiped = false
        private var secondFingerLate = false   // second finger landed well after the first: not a two-finger tap

        private let tapHaptic = UIImpactFeedbackGenerator(style: .light)
        private let grabHaptic = UIImpactFeedbackGenerator(style: .medium)
        private var dots: [UITouch: CALayer] = [:]

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// Only this pad's fingers: a thumb holding the Left click button must not turn a move into a scroll.
        private func fingers(_ event: UIEvent?) -> [UITouch] {
            event?.touches(for: self)?.filter { $0.phase != .ended && $0.phase != .cancelled } ?? []
        }

        private func fingersDown(_ event: UIEvent?) -> Int { fingers(event).count }

        /// Average movement of the fingers that moved in this event (the centroid delta for two-finger scroll).
        private func averageDelta(_ event: UIEvent?) -> CGPoint {
            let moved = event?.touches(for: self)?.filter { $0.phase == .moved } ?? []
            guard !moved.isEmpty else { return .zero }
            var sum = CGPoint.zero
            for t in moved {
                let now = t.location(in: self), prev = t.previousLocation(in: self)
                sum.x += now.x - prev.x
                sum.y += now.y - prev.y
            }
            return CGPoint(x: sum.x / CGFloat(moved.count), y: sum.y / CGFloat(moved.count))
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if maxFingers == 0 { // first finger of a new gesture
                startTime = event?.timestamp ?? 0
                lastTime = startTime
                travel = 0
                scrolled = false
                pinching = false
                pinchBase = 0
                swipe = .zero
                swiped = false
                secondFingerLate = false
                pointerSpeed = 0
                tapHaptic.prepare()
                holdTimer = Timer.scheduledTimer(withTimeInterval: TouchpadView.holdToDrag, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.beginDrag() }
                }
            }
            let down = fingersDown(event)
            if down == 2, maxFingers == 1, (event?.timestamp ?? startTime) - startTime > TouchpadView.twoFingerLanding {
                secondFingerLate = true
            }
            maxFingers = max(maxFingers, down)
            if maxFingers > 1 { cancelHold() }
            if fingersDown(event) == 2, let s = spread(event) { pinchBase = s }
            touches.forEach(showDot)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            moveDots(touches)
            let now = event?.timestamp ?? lastTime
            let dt = now - lastTime
            lastTime = now
            let d = averageDelta(event)
            travel += hypot(d.x, d.y)
            if travel >= TouchpadView.tapMaxTravel { cancelHold() }
            guard dt > 0 else { return }

            let time = Message.clock(now) // when the finger moved, so the Mac can replay it at that pace
            if maxFingers == 1 {
                pointerSpeed = pointerSpeed * 0.5 + hypot(d.x, d.y) / dt * 0.5
                let g = TouchpadView.gain(speed: pointerSpeed) * options.pointerSpeed
                send(Message(kind: .move, dx: Float(d.x * g), dy: Float(d.y * g), time: time))
            } else if maxFingers == 2, fingersDown(event) == 2 {
                if !scrolling, let s = spread(event), pinchBase > 0 {
                    // Pinch vs scroll: fingers moving apart/together change the spread more than they move the center.
                    let change = s - pinchBase
                    if pinching || (abs(change) > 20 && abs(change) > travel) {
                        pinching = true
                        gesture = "Pinch to zoom"
                        let ratio = s / pinchBase
                        if ratio > TouchpadView.pinchStep || ratio < 1 / TouchpadView.pinchStep {
                            perform(ratio > 1 ? .zoomIn : .zoomOut)
                            pinchBase = s
                        }
                        return
                    }
                }
                // Dead zone so a two-finger tap doesn't nudge the page.
                guard scrolling || travel > 10 else { return }
                scrolling = true
                scrolled = true
                gesture = "Two-finger scroll"
                // Smoothed velocity, used for the momentum glide on lift.
                scrollVelocity.x = scrollVelocity.x * 0.6 + d.x / dt * 0.4
                scrollVelocity.y = scrollVelocity.y * 0.6 + d.y / dt * 0.4
                let g = TouchpadView.scrollGain * options.scrollSpeed * scrollSign
                send(Message(kind: .scroll, dx: Float(d.x * g), dy: Float(d.y * g), time: time))
            } else if maxFingers == 3, !swiped {
                swipe.x += d.x
                swipe.y += d.y
                guard max(abs(swipe.x), abs(swipe.y)) > TouchpadView.swipeDistance else { return }
                swiped = true // one action per swipe
                let action: Message.Action = abs(swipe.y) > abs(swipe.x)
                    ? (swipe.y < 0 ? .missionControl : .appExpose)
                    : (swipe.x < 0 ? .spaceRight : .spaceLeft) // like a real trackpad: swipe left shows the desktop on the right
                perform(action)
                gesture = switch action {
                case .missionControl: "Mission Control"
                case .appExpose: "App windows"
                case .spaceRight: "Next desktop"
                default: "Previous desktop"
                }
            }
        }

        private func perform(_ action: Message.Action) {
            send(Message(kind: .action, dx: Float(action.rawValue)))
            if options.haptics { tapHaptic.impactOccurred() }
        }

        /// Distance between the two fingers on the glass, nil unless exactly two.
        private func spread(_ event: UIEvent?) -> CGFloat? {
            let down = fingers(event)
            guard down.count == 2 else { return nil }
            let p = down.map { $0.location(in: self) }
            return hypot(p[0].x - p[1].x, p[0].y - p[1].y)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            hideDots(touches)
            if scrolling, fingersDown(event) < 2 { endScroll(at: event?.timestamp ?? lastTime) }
            guard fingersDown(event) == 0 else { return } // wait for the last finger
            cancelHold()

            if dragging {
                dragging = false
                send(Message(kind: .leftUp))
            } else if !scrolled, !pinching, maxFingers <= 2, travel < TouchpadView.tapMaxTravel,
                      (event?.timestamp ?? startTime) - startTime < TouchpadView.tapMaxDuration,
                      maxFingers == 2 && !secondFingerLate ? options.twoFingerRightClick : options.tapToClick {
                // A stray thumb brushing the glass during a tap must not turn a left click into a right click.
                send(Message(kind: maxFingers == 2 && !secondFingerLate ? .rightClick : .leftClick))
                if options.haptics { tapHaptic.impactOccurred() }
            }
            maxFingers = 0
            gesture = nil
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            hideDots(touches)
            cancelHold()
            if scrolling { endScroll(at: 0) }
            if dragging {
                dragging = false
                send(Message(kind: .leftUp))
            }
            maxFingers = 0
            gesture = nil
        }

        private func endScroll(at time: TimeInterval) {
            scrolling = false
            // Fingers that paused before lifting shouldn't fling the page.
            let v = time - lastTime < 0.05 ? scrollVelocity : .zero
            let g = TouchpadView.scrollGain * options.scrollSpeed * scrollSign
            send(Message(kind: .scrollEnd, dx: Float(v.x * g), dy: Float(v.y * g)))
            scrollVelocity = .zero
        }

        private func beginDrag() {
            holdTimer = nil
            guard maxFingers == 1, travel < TouchpadView.tapMaxTravel, !dragging else { return }
            dragging = true
            gesture = "Dragging"
            send(Message(kind: .leftDown))
            if options.haptics { grabHaptic.impactOccurred() }
            dots.values.forEach { $0.backgroundColor = UIColor.white.withAlphaComponent(0.45).cgColor }
        }

        private func cancelHold() {
            holdTimer?.invalidate()
            holdTimer = nil
        }

        // MARK: Finger dots, so you can see the pad is listening.

        private func showDot(for t: UITouch) {
            guard options.fingerDots else { return }
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
            dot.cornerRadius = 22
            dot.backgroundColor = UIColor.white.withAlphaComponent(0.14).cgColor
            dot.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
            dot.borderWidth = 1.5
            dot.shadowColor = UIColor.white.cgColor // soft glow
            dot.shadowOpacity = 0.35
            dot.shadowRadius = 12
            dot.shadowOffset = .zero
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.position = t.location(in: self)
            layer.addSublayer(dot)
            CATransaction.commit()
            dots[t] = dot
        }

        private func moveDots(_ touches: Set<UITouch>) {
            CATransaction.begin()
            CATransaction.setDisableActions(true) // follow the finger, no lag
            for t in touches { dots[t]?.position = t.location(in: self) }
            CATransaction.commit()
        }

        private func hideDots(_ touches: Set<UITouch>) {
            for t in touches {
                guard let dot = dots.removeValue(forKey: t) else { continue }
                CATransaction.begin()
                CATransaction.setCompletionBlock { dot.removeFromSuperlayer() }
                dot.opacity = 0
                dot.transform = CATransform3DMakeScale(1.4, 1.4, 1)
                CATransaction.commit()
            }
        }
    }
}

#Preview("Touchpad") {
    TouchpadView(send: { _ in }).glassPanel().padding(16).appChrome()
}
