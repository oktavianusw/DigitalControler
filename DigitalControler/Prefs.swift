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
    static let showClickButtons = "showClickButtons"
    static let clickHaptics = "clickHaptics"
    static let fingerDots = "fingerDots"
    static let gestureHints = "gestureHints"
    static let scrollStrip = "scrollStrip"
    static let showLatency = "showLatency"
    static let keyHaptics = "keyHaptics"
    static let miniTrackpad = "miniTrackpad"
}

enum Mode: String, CaseIterable, Identifiable {
    case trackpad, keyboard, shortcuts
    var id: Self { self }
    var title: String { rawValue.capitalized }
}
