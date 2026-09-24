//
//  RemoteView.swift
//  DigitalControler
//

import SwiftUI
import UIKit

/// The connected screen: a bar (status pill, mode switcher, full screen, settings) above or below the current mode.
struct RemoteView: View {
    let client: Client
    @State private var mode = Mode(rawValue: UserDefaults.standard.string(forKey: Prefs.openIn) ?? "") ?? .trackpad
    @State private var showSettings = false
    @AppStorage(Prefs.orientation) private var orientation = PadOrientation.auto
    @AppStorage(Prefs.showLatency) private var showLatency = true
    @AppStorage(Prefs.barAtBottom) private var barAtBottom = true
    @State private var fullScreen = false
    @State private var islandEdge: Edge?

    var body: some View {
        VStack(spacing: 10) {
            if !fullScreen, !barAtBottom { bar }
            Group {
                switch mode {
                case .trackpad: TrackpadPane(send: client.send, exitFullScreen: exitAction, exitAtTop: !barAtBottom)
                case .keyboard: KeyboardView(send: client.send)
                case .shortcuts: ShortcutsPane(send: client.send)
                case .screen: ScreenPane(client: client)
                }
            }
            // Where the bar's buttons were, so the way out is where you'd reach for it.
            // The trackpad places its own, beside the scroll strip rather than on it.
            .overlay(alignment: barAtBottom ? .bottomTrailing : .topTrailing) {
                if fullScreen, mode != .trackpad {
                    ExitFullScreenButton(action: exitFullScreen).padding(8)
                }
            }
            if !fullScreen, barAtBottom { bar }
        }
        // Landscape safe area pads both sides for the Dynamic Island, but it's only on one side:
        // go edge to edge and keep clear of the island alone.
        .padding(.leading, islandEdge == .leading ? 52 : 16)
        .padding(.trailing, islandEdge == .trailing ? 52 : 16)
        .padding(.vertical, 14)
        .ignoresSafeArea(.container, edges: fullScreen ? .all : .horizontal)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in islandEdge = Self.islandEdge() }
        .defersSystemGestures(on: .all) // edge swipes go to the pad first, not Control Center / Home
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
        .sheet(isPresented: $showSettings) {
            SettingsView(client: client)
        }
        .onAppear {
            orientation.apply()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onChange(of: orientation) { orientation.apply() }
        .onDisappear {
            PadOrientation.auto.apply()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func exitFullScreen() {
        withAnimation(.easeOut(duration: 0.2)) { fullScreen = false }
    }

    private var exitAction: (() -> Void)? {
        guard fullScreen else { return nil }
        return { exitFullScreen() }
    }

    /// Which side the Dynamic Island / notch sits on in landscape, nil in portrait.
    private static func islandEdge() -> Edge? {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return switch scene?.effectiveGeometry.interfaceOrientation {
        case .landscapeRight: .leading   // phone's top edge (with the island) is on the left
        case .landscapeLeft: .trailing
        default: nil
        }
    }

    /// Full labels when there's room (landscape); icons and a bare status dot when there isn't (portrait).
    private var bar: some View {
        ViewThatFits(in: .horizontal) {
            bar(compact: false)
            bar(compact: true)
        }
    }

    private func bar(compact: Bool) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(.white).frame(width: 7, height: 7).shadow(color: .white.opacity(0.8), radius: 4)
                if !compact {
                    Text(client.connected ? client.macName : "Reconnecting…").lineLimit(1)
                    if showLatency, client.connected, let ms = client.latencyMs {
                        Text("\(ms) ms").foregroundStyle(.white.opacity(0.55)).monospacedDigit()
                    }
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, compact ? 16 : 14)
            .frame(height: 40)
            .glass(in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(client.connected ? "Connected to \(client.macName)" : "Reconnecting")
            .fixedSize()
            // Both sides stretch equally, so the mode switcher sits in the middle.
            .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)

            PillPicker(options: Mode.allCases, selection: $mode, title: \.title, icon: compact ? \.icon : nil)
                .fixedSize()

            HStack(spacing: 8) {
                if mode.canFullScreen {
                    Button { withAnimation(.easeOut(duration: 0.2)) { fullScreen = true } } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(GlassButtonStyle(shape: Circle()))
                    .accessibilityLabel("Full screen")
                }
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.2.square")
                        .font(.system(size: 17))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(GlassButtonStyle(shape: Circle()))
                .accessibilityLabel("Settings")
            }
            .frame(maxWidth: compact ? nil : .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Trackpad

/// Reads every pad option from Settings, so each screen that shows a pad behaves the same.
private struct Pad: View {
    let send: (Message) -> Void
    var onGesture: (String?) -> Void = { _ in }
    @AppStorage(Prefs.pointerSpeed) private var pointerSpeed = 1.0
    @AppStorage(Prefs.scrollSpeed) private var scrollSpeed = 1.0
    @AppStorage(Prefs.naturalScrolling) private var naturalScrolling = true
    @AppStorage(Prefs.tapToClick) private var tapToClick = true
    @AppStorage(Prefs.twoFingerRightClick) private var twoFingerRightClick = true
    @AppStorage(Prefs.clickHaptics) private var clickHaptics = true
    @AppStorage(Prefs.fingerDots) private var fingerDots = true

    var body: some View {
        TouchpadView(send: send,
                     options: PadOptions(pointerSpeed: pointerSpeed, scrollSpeed: scrollSpeed, naturalScrolling: naturalScrolling,
                                         tapToClick: tapToClick, twoFingerRightClick: twoFingerRightClick,
                                         haptics: clickHaptics, fingerDots: fingerDots),
                     onGesture: onGesture)
    }
}

/// Leaves full screen. Floats over the mode, so keep it clear of anything you'd touch.
private struct ExitFullScreenButton: View {
    let action: () -> Void
    var size: CGFloat = 40

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: size, height: size)
        }
        .buttonStyle(GlassButtonStyle(shape: Circle()))
        .accessibilityLabel("Exit full screen")
    }
}

private struct TrackpadPane: View {
    let send: (Message) -> Void
    /// Set while in full screen: the way out, under (or over) the scroll strip, or in the pad's corner without one.
    var exitFullScreen: (() -> Void)?
    var exitAtTop = false
    @State private var gesture: String?
    @AppStorage(Prefs.gestureHints) private var gestureHints = true
    @AppStorage(Prefs.scrollStrip) private var scrollStrip = true

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 10) {
                ZStack {
                    if gestureHints {
                        Text("Tap to click · Two-finger tap to right-click")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 12)
                    }
                    Pad(send: send) { g in withAnimation(.easeOut(duration: 0.2)) { gesture = g } }
                }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .glassPanel()
                .overlay(alignment: exitAtTop ? .topTrailing : .bottomTrailing) {
                    if !scrollStrip, let exitFullScreen {
                        ExitFullScreenButton(action: exitFullScreen).padding(8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if gestureHints, let gesture {
                        Text(gesture)
                            .font(.system(size: 12))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .glass(in: Capsule())
                            .padding(.top, 12)
                            .padding(.leading, 14)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
            }
            if scrollStrip {
                VStack(spacing: 10) {
                    if exitAtTop, let exitFullScreen { ExitFullScreenButton(action: exitFullScreen, size: 48) }
                    ScrollStrip(send: send)
                    if !exitAtTop, let exitFullScreen { ExitFullScreenButton(action: exitFullScreen, size: 48) }
                }
                .frame(width: 48)
            }
        }
    }
}

/// One-finger vertical scroll, like the edge of an old laptop trackpad.
private struct ScrollStrip: View {
    let send: (Message) -> Void
    @State private var lastY: CGFloat = 0
    @State private var offset: CGFloat = 0
    @AppStorage(Prefs.scrollSpeed) private var scrollSpeed = 1.0
    @AppStorage(Prefs.naturalScrolling) private var naturalScrolling = true

    var body: some View {
        let gain = TouchpadView.scrollGain * scrollSpeed * (naturalScrolling ? 1 : -1)
        VStack {
            Image(systemName: "chevron.up")
            Spacer()
            Capsule()
                .fill(.white.opacity(0.85))
                .frame(width: 4, height: 56)
                .shadow(color: .white.opacity(0.5), radius: 5)
                .offset(y: offset)
            Spacer()
            Image(systemName: "chevron.down")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(0.7))
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glass(.panel, in: Capsule())
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                let dy = v.translation.height - lastY
                lastY = v.translation.height
                offset = max(-40, min(40, v.translation.height / 3))
                if dy != 0 { send(Message(kind: .scroll, dy: Float(dy * gain))) }
            }
            .onEnded { v in
                send(Message(kind: .scrollEnd, dy: Float(v.velocity.height * gain)))
                lastY = 0
                withAnimation(.spring(duration: 0.3)) { offset = 0 }
            })
        .accessibilityLabel("Scroll strip")
        .accessibilityAdjustableAction { direction in
            send(Message(kind: .scroll, dy: direction == .increment ? -120 : 120))
            send(Message(kind: .scrollEnd))
        }
    }
}

// MARK: - Screen

/// The Mac's screens, live. With several displays, pick one from a grid of thumbnails first,
/// then work on it directly (see `ScreenSurfaceView` for the gestures).
private struct ScreenPane: View {
    let client: Client
    @AppStorage(Prefs.clickHaptics) private var haptics = true
    @AppStorage(Prefs.scrollSpeed) private var scrollSpeed = 1.0
    @AppStorage(Prefs.naturalScrolling) private var naturalScrolling = true
    @AppStorage(Prefs.gestureHints) private var gestureHints = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let error = client.screenError {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.dashed.badge.record").font(.system(size: 28))
                    Text(error).font(.system(size: 14)).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(24)
            } else if let index = client.selectedDisplay {
                display(index)
            } else if client.displays.count > 1 {
                grid
            } else {
                ProgressView("Waiting for the Mac's screen…").tint(.white).foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(8)
        .glassPanel()
        .onAppear { client.startScreen() }
        .onDisappear { client.stopScreen() }
        // Nobody's watching in the background or with the phone locked: don't make the Mac stream.
        .onChange(of: scenePhase) { _, phase in
            phase == .active ? client.resumeScreen() : client.pauseScreen()
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                ForEach(client.displays.indices, id: \.self) { i in
                    Button { client.selectDisplay(i) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Group {
                                if let frame = client.screenFrames[i] {
                                    Image(uiImage: frame).resizable().scaledToFit()
                                } else {
                                    Rectangle().fill(.white.opacity(0.05))
                                        .aspectRatio(16 / 10, contentMode: .fit)
                                        .overlay { ProgressView().tint(.white) }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text(client.displays[i]).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        }
                        .padding(10)
                    }
                    .buttonStyle(GlassButtonStyle(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)))
                    .accessibilityLabel("Show \(client.displays[i])")
                }
            }
            .padding(4)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Live video once it's flowing; until then the display's thumbnail from the grid, if there is one.
    private func content(for index: Int) -> ScreenSurfaceView.Content? {
        if let size = client.videoSize { return .video(client.video, size) }
        return client.screenFrames[index].map { .image($0) }
    }

    private func display(_ index: Int) -> some View {
        ZStack(alignment: .topLeading) {
            if let content = content(for: index) {
                ScreenSurfaceView(content: content, send: client.send, scrollSpeed: scrollSpeed,
                                  naturalScrolling: naturalScrolling, haptics: haptics)
                    .id(index) // fresh zoom for each display
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel(client.displays.indices.contains(index) ? client.displays[index] : "Mac screen")
                    .overlay(alignment: .bottom) {
                        if gestureHints {
                            ViewThatFits(in: .horizontal) {
                                Text("Tap to click · Hold to drag · Two fingers to scroll · Pinch to zoom")
                                Text("Tap · Hold to drag · 2 fingers scroll · Pinch zoom")
                            }
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .glass(in: Capsule())
                                .padding(.bottom, 8)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if client.displays.count > 1 {
                Button { client.selectDisplay(nil) } label: {
                    Label("All screens", systemImage: "square.grid.2x2")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                }
                .buttonStyle(.glassCapsule)
                .padding(8)
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    let send: (Message) -> Void
    @AppStorage(Prefs.miniTrackpad) private var miniTrackpad = true

    private struct Shortcut: Identifiable {
        let keys: String
        let name: String
        let message: Message
        var id: String { name }
    }

    private static func key(_ code: UInt16, _ mods: Message.Modifiers) -> Message {
        Message(kind: .key, dx: Float(code), dy: Float(mods.rawValue))
    }

    private static func action(_ a: Message.Action) -> Message {
        Message(kind: .action, dx: Float(a.rawValue))
    }

    private let shortcuts = [
        Shortcut(keys: "⌘ C", name: "Copy", message: key(8, .command)),
        Shortcut(keys: "⌘ V", name: "Paste", message: key(9, .command)),
        Shortcut(keys: "⌘ Z", name: "Undo", message: key(6, .command)),
        Shortcut(keys: "⌘ Space", name: "Spotlight", message: key(49, .command)),
        Shortcut(keys: "⌘ Tab", name: "Switch app", message: key(48, .command)),
        Shortcut(keys: "⌃ ↑", name: "Mission Control", message: action(.missionControl)),
        Shortcut(keys: "Vol −", name: "Volume down", message: action(.volumeDown)),
        Shortcut(keys: "▶︎ ❚❚", name: "Play / pause", message: action(.playPause)),
        Shortcut(keys: "Vol +", name: "Volume up", message: action(.volumeUp)),
    ]

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 10) {
                TypeToMacField(send: send)
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(0..<3) { r in
                        GridRow {
                            ForEach(shortcuts[r * 3..<r * 3 + 3]) { s in
                                Button { send(s.message) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.keys).font(.system(size: 15, weight: .semibold))
                                        Text(s.name).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                }
                                .buttonStyle(GlassButtonStyle(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)))
                                .accessibilityLabel(s.name)
                            }
                        }
                    }
                }
            }
            if miniTrackpad {
                Pad(send: send)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .glassPanel()
                    .overlay(alignment: .topLeading) {
                        Caption("Mini trackpad").padding(.top, 12).padding(.leading, 16).allowsHitTesting(false)
                    }
                    .containerRelativeFrame(.horizontal) { w, _ in w * 0.3 }
            }
        }
    }
}

/// Whatever you type here is typed on the Mac, character by character.
private struct TypeToMacField: View {
    let send: (Message) -> Void
    @State private var text = ""

    var body: some View {
        TextField("", text: $text, prompt: Text("Type to Mac…").foregroundStyle(.white.opacity(0.5)))
            .font(.system(size: 15))
            .autocorrectionDisabled() // autocorrect rewrites words after they were already typed on the Mac
            .textInputAutocapitalization(.never)
            .submitLabel(.return)
            .padding(.horizontal, 18)
            .frame(height: 44)
            .glass(in: Capsule())
            .onChange(of: text) { old, new in sendDiff(from: old, to: new) }
            .onSubmit {
                send(Message(kind: .text, dx: Float(Unicode.Scalar("\n").value)))
                text = ""
            }
            .accessibilityLabel("Type to Mac")
    }

    /// Mirrors edits as keystrokes: backspaces for what was removed, then the new characters.
    private func sendDiff(from old: String, to new: String) {
        let common = zip(old, new).prefix { $0 == $1 }.count
        for _ in 0..<(old.count - common) {
            send(Message(kind: .key, dx: 51)) // delete
        }
        for scalar in new.dropFirst(common).unicodeScalars {
            send(Message(kind: .text, dx: Float(scalar.value)))
        }
    }
}

#Preview("Remote") {
    RemoteView(client: .preview()).appChrome()
}

#Preview("Trackpad") {
    TrackpadPane { _ in }.padding(16).appChrome()
}

#Preview("Trackpad, full screen") {
    TrackpadPane(send: { _ in }, exitFullScreen: {}).padding(16).appChrome()
}

#Preview("Shortcuts", traits: .landscapeLeft) {
    ShortcutsPane { _ in }.padding(16).appChrome()
}

#Preview("Screen, all displays", traits: .landscapeLeft) {
    ScreenPane(client: .preview()).padding(16).appChrome()
}

#Preview("Screen, one display", traits: .landscapeLeft) {
    ScreenPane(client: .preview(selected: 0)).padding(16).appChrome()
}

#Preview("Screen, waiting") {
    ScreenPane(client: Client()).padding(16).appChrome()
}
