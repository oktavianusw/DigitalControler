//
//  KeyboardView.swift
//  DigitalControler
//

import SwiftUI
import UIKit

/// Mac keyboard. Sends Mac virtual key codes, so shortcuts work like the real thing.
/// Modifiers are sticky: tap ⌘, then C. Caps lock is kept on the iPhone and applied as Shift to letters.
struct KeyboardView: View {
    let send: (Message) -> Void
    @AppStorage(Prefs.keyHaptics) private var keyHaptics = true
    @State private var modifiers: Message.Modifiers = []
    @State private var capsLock = false
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        let rows = Self.rows
        GeometryReader { geo in
            let gap: CGFloat = 5
            let rowHeight = (geo.size.height - gap * CGFloat(rows.count - 1)) / CGFloat(rows.count)
            VStack(spacing: gap) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let keyUnit = (geo.size.width - gap * CGFloat(row.keys.count - 1)) / row.keys.map(\.width).reduce(0, +)
                    HStack(spacing: gap) {
                        ForEach(Array(row.keys.enumerated()), id: \.offset) { _, key in
                            Button { press(key) } label: {
                                Text(key.label)
                                    .font(.system(size: key.label.count > 1 ? 12 : 14))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .buttonStyle(KeyStyle(active: isActive(key)))
                            .accessibilityLabel(key.accessibilityLabel)
                            .frame(width: keyUnit * key.width, height: rowHeight)
                        }
                    }
                }
            }
        }
        .padding(10)
        .glassPanel(radius: 24)
    }

    private func isActive(_ key: Key) -> Bool {
        switch key.kind {
        case .modifier(let m): modifiers.contains(m)
        case .caps: capsLock
        case .code: false
        }
    }

    private func press(_ key: Key) {
        switch key.kind {
        case .modifier(let m):
            modifiers.formSymmetricDifference(m)
        case .caps:
            capsLock.toggle()
        case .code(let code, let isLetter):
            var mods = modifiers
            if capsLock, isLetter { mods.insert(.shift) }
            send(Message(kind: .key, dx: Float(code), dy: Float(mods.rawValue)))
            modifiers = [] // sticky modifiers apply to one key
        }
        if keyHaptics { haptic.impactOccurred() }
    }

    // MARK: Layout (widths from the design, codes from the Mac's ANSI layout)

    struct Key {
        enum Kind {
            case code(UInt16, isLetter: Bool)
            case modifier(Message.Modifiers)
            case caps
        }
        let label: String
        let kind: Kind
        var width: CGFloat = 1
        var accessibilityLabel: String { label == " " ? "Space" : label }
    }

    struct Row {
        let keys: [Key]
    }

    private static func k(_ label: String, _ code: UInt16, _ width: CGFloat = 1) -> Key {
        Key(label: label, kind: .code(code, isLetter: label.count == 1 && label.first!.isLetter), width: width)
    }

    private static func mod(_ label: String, _ m: Message.Modifiers, _ width: CGFloat = 1) -> Key {
        Key(label: label, kind: .modifier(m), width: width)
    }

    private static let rows: [Row] = [
        Row(keys: [k("`", 50), k("1", 18), k("2", 19), k("3", 20), k("4", 21), k("5", 23), k("6", 22), k("7", 26),
                   k("8", 28), k("9", 25), k("0", 29), k("-", 27), k("=", 24), k("delete", 51, 1.6)]),
        Row(keys: [k("tab", 48, 1.6), k("Q", 12), k("W", 13), k("E", 14), k("R", 15), k("T", 17), k("Y", 16), k("U", 32),
                   k("I", 34), k("O", 31), k("P", 35), k("[", 33), k("]", 30), k("\\", 42)]),
        Row(keys: [Key(label: "caps", kind: .caps, width: 1.9), k("A", 0), k("S", 1), k("D", 2), k("F", 3), k("G", 5), k("H", 4),
                   k("J", 38), k("K", 40), k("L", 37), k(";", 41), k("'", 39), k("return", 36, 1.9)]),
        Row(keys: [mod("shift", .shift, 2.4), k("Z", 6), k("X", 7), k("C", 8), k("V", 9), k("B", 11), k("N", 45), k("M", 46),
                   k(",", 43), k(".", 47), k("/", 44), mod("shift", .shift, 2.4)]),
        Row(keys: [mod("fn", .function), mod("⌃", .control), mod("⌥", .option), mod("⌘", .command, 1.3), k(" ", 49, 5.6),
                   mod("⌘", .command, 1.3), mod("⌥", .option), k("←", 123), k("↑", 126), k("↓", 125), k("→", 124)]),
    ]
}

/// A keycap: translucent, lit white while its modifier is armed.
private struct KeyStyle: ButtonStyle {
    var active: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .foregroundStyle(active ? .black : .white)
            .background {
                shape.fill(.white.opacity(active ? 0.92 : configuration.isPressed ? 0.24 : 0.10))
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                    .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
            }
            .contentShape(shape)
    }
}
