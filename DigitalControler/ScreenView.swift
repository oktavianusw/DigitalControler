//
//  ScreenView.swift
//  DigitalControler
//

import SwiftUI
import UIKit

/// One Mac display you can work on directly:
/// tap = click there, two-finger tap = right click, hold then move = drag, two fingers = scroll,
/// pinch = zoom the picture on the iPhone, one finger while zoomed = move around the picture.
struct ScreenSurfaceView: UIViewRepresentable {
    let image: UIImage
    let send: (Message) -> Void
    var scrollSpeed = 1.0
    var naturalScrolling = true
    var haptics = true

    func makeUIView(context: Context) -> Surface { Surface() }

    func updateUIView(_ surface: Surface, context: Context) {
        surface.send = send
        surface.scrollGain = TouchpadView.scrollGain * scrollSpeed * (naturalScrolling ? 1 : -1)
        surface.haptics = haptics
        surface.setImage(image)
    }

    final class Surface: UIView, UIGestureRecognizerDelegate {
        var send: (Message) -> Void = { _ in }
        var scrollGain: CGFloat = 1
        var haptics = true

        private let imageView = UIImageView()
        private var zoom: CGFloat = 1
        private var pan = CGPoint.zero      // offset of the zoomed picture from centered
        private var pinching = false        // pinch and two-finger scroll both use two fingers:
        private var scrolling = false       // whichever starts moving first owns the gesture
        private var dragging = false
        private var lastScroll = CGPoint.zero
        private let tapHaptic = UIImpactFeedbackGenerator(style: .light)
        private let grabHaptic = UIImpactFeedbackGenerator(style: .medium)
        static let maxZoom: CGFloat = 5

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            isMultipleTouchEnabled = true
            addSubview(imageView)

            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped))
            twoFingerTap.numberOfTouchesRequired = 2
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(held))
            hold.minimumPressDuration = TouchpadView.holdToDrag
            hold.allowableMovement = TouchpadView.tapMaxTravel
            let move = UIPanGestureRecognizer(target: self, action: #selector(moved))
            move.maximumNumberOfTouches = 1
            move.require(toFail: hold) // a still finger becomes a drag, a moving one pans the picture
            let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled))
            scroll.minimumNumberOfTouches = 2
            scroll.maximumNumberOfTouches = 2
            scroll.delegate = self
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
            pinch.delegate = self
            // Two fingers that pinch or scroll aren't a right click.
            twoFingerTap.require(toFail: pinch)
            twoFingerTap.require(toFail: scroll)
            [tap, twoFingerTap, hold, move, scroll, pinch].forEach(addGestureRecognizer)

            isAccessibilityElement = true
            accessibilityTraits = .image
            accessibilityHint = "Tap to click that spot. Two fingers to scroll. Pinch to zoom."
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true // pinch and two-finger scroll run together and settle it between themselves
        }

        func setImage(_ image: UIImage) {
            let resized = imageView.image?.size != image.size
            imageView.image = image
            if resized { setNeedsLayout() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            clampPan()
            imageView.frame = displayRect
        }

        // MARK: Geometry

        /// The picture fitted into the view at 1×.
        private var fitted: CGRect {
            guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return bounds }
            let s = min(bounds.width / size.width, bounds.height / size.height)
            let w = size.width * s, h = size.height * s
            return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        }

        /// Where the picture is drawn now, after zoom and pan.
        private var displayRect: CGRect {
            let f = fitted
            let w = f.width * zoom, h = f.height * zoom
            return CGRect(x: f.midX - w / 2 + pan.x, y: f.midY - h / 2 + pan.y, width: w, height: h)
        }

        /// A view point as 0...1 across the Mac's display (unclamped).
        private func unit(_ p: CGPoint) -> CGPoint {
            let d = displayRect
            return CGPoint(x: (p.x - d.minX) / max(d.width, 1), y: (p.y - d.minY) / max(d.height, 1))
        }

        /// Zoomed in, the picture must cover the view; at 1× it stays centered.
        private func clampPan() {
            let f = fitted
            let w = f.width * zoom, h = f.height * zoom
            pan.x = w <= bounds.width ? 0 : min(max(pan.x, bounds.width - w / 2 - f.midX), w / 2 - f.midX)
            pan.y = h <= bounds.height ? 0 : min(max(pan.y, bounds.height - h / 2 - f.midY), h / 2 - f.midY)
        }

        private func moveTo(_ u: CGPoint) {
            send(Message(kind: .moveTo, dx: Float(min(max(u.x, 0), 1)), dy: Float(min(max(u.y, 0), 1))))
        }

        private func onPicture(_ p: CGPoint) -> Bool { displayRect.contains(p) }

        // MARK: Gestures

        @objc private func tapped(_ g: UITapGestureRecognizer) {
            let p = g.location(in: self)
            guard onPicture(p) else { return }
            moveTo(unit(p))
            send(Message(kind: .leftClick))
            if haptics { tapHaptic.impactOccurred() }
        }

        @objc private func twoFingerTapped(_ g: UITapGestureRecognizer) {
            let p = g.location(in: self) // midpoint of the two fingers
            guard onPicture(p) else { return }
            moveTo(unit(p))
            send(Message(kind: .rightClick))
            if haptics { tapHaptic.impactOccurred() }
        }

        @objc private func held(_ g: UILongPressGestureRecognizer) {
            let p = g.location(in: self)
            switch g.state {
            case .began:
                guard onPicture(p) else { return }
                dragging = true
                moveTo(unit(p))
                send(Message(kind: .leftDown))
                if haptics { grabHaptic.impactOccurred() }
            case .changed where dragging:
                moveTo(unit(p))
            case .ended, .cancelled, .failed:
                if dragging { send(Message(kind: .leftUp)) }
                dragging = false
            default: break
            }
        }

        @objc private func moved(_ g: UIPanGestureRecognizer) {
            guard zoom > 1 else { return }
            let t = g.translation(in: self)
            pan.x += t.x
            pan.y += t.y
            g.setTranslation(.zero, in: self)
            setNeedsLayout()
        }

        @objc private func scrolled(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: self)
            switch g.state {
            case .changed:
                if !scrolling {
                    guard !pinching, hypot(t.x, t.y) > 10 else { return }
                    scrolling = true
                    lastScroll = t
                    moveTo(unit(g.location(in: self))) // scroll whatever is under the fingers
                    return
                }
                send(Message(kind: .scroll, dx: Float((t.x - lastScroll.x) * scrollGain), dy: Float((t.y - lastScroll.y) * scrollGain)))
                lastScroll = t
            case .ended, .cancelled, .failed:
                if scrolling {
                    let v = g.velocity(in: self)
                    send(Message(kind: .scrollEnd, dx: Float(v.x * scrollGain), dy: Float(v.y * scrollGain)))
                }
                scrolling = false
            default: break
            }
        }

        @objc private func pinched(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .changed:
                if !pinching {
                    guard !scrolling, abs(g.scale - 1) > 0.08 else { return }
                    pinching = true
                }
                zoom(by: g.scale, at: g.location(in: self))
                g.scale = 1
            case .ended, .cancelled, .failed:
                pinching = false
            default: break
            }
        }

        /// Zooms keeping the spot under the fingers where it is.
        private func zoom(by factor: CGFloat, at p: CGPoint) {
            let anchor = unit(p)
            zoom = min(max(zoom * factor, 1), Self.maxZoom)
            let f = fitted
            let w = f.width * zoom, h = f.height * zoom
            pan = CGPoint(x: p.x - anchor.x * w - (f.midX - w / 2), y: p.y - anchor.y * h - (f.midY - h / 2))
            setNeedsLayout()
        }
    }
}
