//
//  Theme.swift
//  DigitalControler
//
//  The design's monochrome "glass": translucent white fills, hairline borders
//  that catch light at the top, deep shadows on pure black.
//

import SwiftUI

enum GlassLevel {
    case panel    // big surfaces: trackpad, keyboard, settings groups
    case control  // buttons, pills, fields

    var fill: Double { self == .panel ? 0.06 : 0.10 }
    var border: Double { self == .panel ? 0.14 : 0.18 }
}

extension View {
    func glass(_ level: GlassLevel = .control, in shape: some InsettableShape) -> some View {
        background {
            shape.fill(.white.opacity(level.fill))
                .strokeBorder(LinearGradient(colors: [.white.opacity(level.border + 0.14), .white.opacity(level.border - 0.06)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
                .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
        }
    }

    func glassPanel(radius: CGFloat = 28) -> some View {
        glass(.panel, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Translucent pill/rounded button that brightens while pressed.
struct GlassButtonStyle<S: InsettableShape>: ButtonStyle {
    var shape: S

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .glass(in: shape)
            .overlay(shape.fill(.white.opacity(configuration.isPressed ? 0.12 : 0)))
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == GlassButtonStyle<Capsule> {
    static var glassCapsule: Self { GlassButtonStyle(shape: Capsule()) }
}

/// Solid white capsule with black text: the one loud button on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.75 : 0.92)))
    }
}

/// The design's switch: white track when on, near-black knob.
struct MonoToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer()
                Capsule()
                    .fill(.white.opacity(configuration.isOn ? 0.92 : 0.16))
                    .frame(width: 51, height: 31)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(configuration.isOn ? Color(white: 0.07) : .white)
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
                            .padding(2)
                    }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: configuration.isOn)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// Segmented pill: selected option is a white capsule with black text.
struct PillPicker<T: Hashable & Identifiable>: View {
    let options: [T]
    @Binding var selection: T
    let title: (T) -> String
    var height: CGFloat = 40
    var fillWidth = false
    /// When set, options show as icons (titles stay as accessibility labels). For tight spaces.
    var icon: ((T) -> String)?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    if let icon {
                        Label(title(option), systemImage: icon(option)).labelStyle(.iconOnly)
                    } else {
                        Text(title(option)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                }
                    .font(.system(size: fillWidth ? 14 : 13, weight: fillWidth ? .semibold : .medium))
                    .foregroundStyle(selected ? .black : .white.opacity(0.8))
                    .padding(.horizontal, fillWidth ? 6 : 14)
                    .frame(maxWidth: fillWidth ? .infinity : nil, maxHeight: .infinity)
                    .background(Capsule().fill(.white.opacity(selected ? 0.92 : 0)))
                    .contentShape(Capsule())
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(height: height)
        .glass(in: Capsule())
        .animation(.snappy(duration: 0.2), value: selection)
    }
}

/// Small grey caption above a settings group or panel.
struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
    }
}
