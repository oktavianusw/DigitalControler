//
//  Prefs.swift
//  DigitalControler
//
//  UserDefaults keys for Settings, shared by every screen's @AppStorage.
//

import Foundation

enum Prefs {
    static let openIn = "openIn"
    static let orientation = "padOrientation"
    static let pointerSpeed = "pointerSpeed"
    static let scrollSpeed = "scrollSpeed"
    static let naturalScrolling = "naturalScrolling"
    static let tapToClick = "tapToClick"
    static let twoFingerRightClick = "twoFingerRightClick"
    static let clickHaptics = "clickHaptics"
    static let fingerDots = "fingerDots"
    static let gestureHints = "gestureHints"
    static let scrollStrip = "scrollStrip"
    static let showLatency = "showLatency"
    static let keyHaptics = "keyHaptics"
    static let miniTrackpad = "miniTrackpad"
    static let screenQuality = "screenQuality"
}

/// How big (and how much Wi-Fi and battery) the Screen tab's video is.
enum ScreenQuality: String, CaseIterable, Identifiable {
    case saver, balanced, sharp
    var id: Self { self }
    var title: String {
        switch self {
        case .saver: "Data saver"
        case .balanced: "Balanced"
        case .sharp: "Sharp"
        }
    }
    /// Longest edge in pixels. The Mac scales its bitrate to match.
    var maxEdge: Int {
        switch self {
        case .saver: 1024
        case .balanced: 1600
        case .sharp: 2400
        }
    }

    static var current: ScreenQuality {
        UserDefaults.standard.string(forKey: Prefs.screenQuality).flatMap(ScreenQuality.init) ?? .balanced
    }
}

enum Mode: String, CaseIterable, Identifiable {
    case trackpad, keyboard, shortcuts, screen
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .trackpad: "hand.point.up.left"
        case .keyboard: "keyboard"
        case .shortcuts: "command"
        case .screen: "display"
        }
    }
}
