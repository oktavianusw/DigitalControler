//
//  SettingsView.swift
//  DigitalControler
//

import SwiftUI

struct SettingsView: View {
    let client: Client
    @Environment(\.dismiss) private var dismiss

    @AppStorage(Prefs.openIn) private var openIn = Mode.trackpad
    @AppStorage(Prefs.orientation) private var orientation = PadOrientation.auto
    @AppStorage(Prefs.pointerSpeed) private var pointerSpeed = 1.0
    @AppStorage(Prefs.scrollSpeed) private var scrollSpeed = 1.0
    @AppStorage(Prefs.naturalScrolling) private var naturalScrolling = true
    @AppStorage(Prefs.tapToClick) private var tapToClick = true
    @AppStorage(Prefs.twoFingerRightClick) private var twoFingerRightClick = true
    @AppStorage(Prefs.clickHaptics) private var clickHaptics = true
    @AppStorage(Prefs.fingerDots) private var fingerDots = true
    @AppStorage(Prefs.gestureHints) private var gestureHints = true
    @AppStorage(Prefs.scrollStrip) private var scrollStrip = true
    @AppStorage(Prefs.showLatency) private var showLatency = true
    @AppStorage(Prefs.keyHaptics) private var keyHaptics = true
    @AppStorage(Prefs.miniTrackpad) private var miniTrackpad = true
    @AppStorage(Prefs.screenQuality) private var screenQuality = ScreenQuality.balanced

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("Settings").font(.system(size: 34, weight: .bold)).kerning(-0.6)
                    Spacer()
                    Button { dismiss() } label: {
                        Text("Done")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                    }
                    .buttonStyle(.glassCapsule)
                }

                section("Open in") {
                    PillPicker(options: Mode.allCases, selection: $openIn, title: \.title, height: 44, fillWidth: true)
                }
                section("Orientation") {
                    PillPicker(options: PadOrientation.allCases, selection: $orientation, title: \.title, height: 44, fillWidth: true)
                }
                section("Pointer") {
                    group {
                        speedRow("Tracking speed", value: $pointerSpeed)
                        speedRow("Scroll speed", value: $scrollSpeed)
                        toggle("Natural scrolling", $naturalScrolling, last: true)
                    }
                }
                section("Clicks") {
                    group {
                        toggle("Tap to click", $tapToClick)
                        toggle("Two-finger tap to right-click", $twoFingerRightClick)
                        toggle("Haptic on click", $clickHaptics, last: true)
                    }
                }
                section("On screen", footer: "Turn these off for a plain, empty pad.") {
                    group {
                        toggle("Finger dots", $fingerDots)
                        toggle("Gesture hints", $gestureHints)
                        toggle("Scroll strip", $scrollStrip)
                        toggle("Connection latency", $showLatency, last: true)
                    }
                }
                section("Keyboard") {
                    group {
                        toggle("Key haptics", $keyHaptics)
                        toggle("Mini trackpad in Shortcuts", $miniTrackpad, last: true)
                    }
                }
                section("Screen", footer: "Sharper uses more Wi-Fi and battery on both devices.") {
                    PillPicker(options: ScreenQuality.allCases, selection: $screenQuality, title: \.title, height: 44, fillWidth: true)
                }
                section("Gestures") {
                    group {
                        gestureRow("Hold, then move", "Drag")
                        gestureRow("Pinch", "Zoom in / out")
                        gestureRow("Three fingers up", "Mission Control")
                        gestureRow("Three fingers down", "App windows")
                        gestureRow("Three fingers left / right", "Switch desktop", last: true)
                    }
                }

                connectedCard
            }
            .padding(20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: screenQuality) { client.resumeScreen() } // apply to a stream that's already running
        .background(Color.black.ignoresSafeArea())
        .presentationBackground(.black)
    }

    private var connectedCard: some View {
        HStack(spacing: 12) {
            Circle().fill(.white).frame(width: 8, height: 8).shadow(color: .white.opacity(0.8), radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(client.macName).font(.system(size: 16, weight: .semibold))
                Text(client.latencyMs.map { "Connected · \($0) ms" } ?? "Connected")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button {
                dismiss()
                client.disconnect()
            } label: {
                Text("Disconnect")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
            }
            .buttonStyle(.glassCapsule)
        }
        .padding(16)
        .glassPanel(radius: 24)
    }

    // MARK: Building blocks

    private func section(_ title: String, footer: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(title).padding(.horizontal, 16)
            content()
            if let footer { Caption(footer).padding(.horizontal, 16) }
        }
    }

    private func group(@ViewBuilder rows: () -> some View) -> some View {
        VStack(spacing: 0) { rows() }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
            .glassPanel(radius: 24)
    }

    private func row(last: Bool, @ViewBuilder content: () -> some View) -> some View {
        content()
            .font(.system(size: 16))
            .frame(minHeight: 50)
            .overlay(alignment: .bottom) {
                if !last { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) }
            }
    }

    private func toggle(_ title: String, _ isOn: Binding<Bool>, last: Bool = false) -> some View {
        row(last: last) {
            Toggle(title, isOn: isOn).toggleStyle(MonoToggleStyle())
        }
    }

    private func speedRow(_ title: String, value: Binding<Double>) -> some View {
        row(last: false) {
            VStack(spacing: 8) {
                HStack {
                    Text(title)
                    Spacer()
                    Text("\(value.wrappedValue, format: .number.precision(.fractionLength(1)))×")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.55))
                        .monospacedDigit()
                }
                Slider(value: value, in: 0.4...2.5).tint(.white)
            }
            .padding(.vertical, 10)
        }
    }

    private func gestureRow(_ gesture: String, _ does: String, last: Bool = false) -> some View {
        row(last: last) {
            HStack {
                Text(gesture)
                Spacer()
                Text(does).foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}
