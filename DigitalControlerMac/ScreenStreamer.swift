//
//  ScreenStreamer.swift
//  DigitalControlerMac
//

import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Sends the Mac's screens to the iPhone as JPEG snapshots, only while the iPhone asks for it:
/// either small thumbnails of every display (for picking one) or one display at full size.
// ponytail: JPEG stills at ≤5 fps prove the pipeline; H.264 streaming (phase 7) replaces this for 30 fps.
@MainActor
final class ScreenStreamer {
    /// The display being shown large, in global coordinates, for mapping taps back onto it.
    private(set) var displayBounds: CGRect?
    private var task: Task<Void, Never>?

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// `display` is an index into the displays (left to right), or nil for thumbnails of all of them.
    /// `send` returns false once the connection is gone. It resolves when the frame has left, which paces
    /// the loop: a slow network lowers the frame rate instead of piling frames up.
    func start(maxEdge: Int, display: Int?, send: @escaping (Downstream, Data) async -> Bool) {
        stop()
        task = Task { [weak self] in
            do {
                let displays = try await Self.displays()
                let names = displays.map(\.name).joined(separator: "\n")
                guard await send(.displays, Data(names.utf8)) else { return }

                let shown = display.map { [min(max($0, 0), displays.count - 1)] } ?? Array(displays.indices)
                self?.displayBounds = display == nil ? nil : displays[shown[0]].bounds
                let targets = shown.map { i in (index: i, filter: displays[i].filter, config: Self.config(displays[i].bounds, maxEdge)) }
                let interval = display == nil ? 0.5 : 0.2 // thumbnails at 2 fps, one display at 5 fps

                while !Task.isCancelled {
                    let started = Date()
                    for t in targets {
                        let image = try await SCScreenshotManager.captureImage(contentFilter: t.filter, configuration: t.config)
                        let jpeg = await Task.detached(priority: .userInitiated) { Self.jpeg(image) }.value
                        guard let jpeg, !Task.isCancelled else { continue }
                        guard await send(.frame, Data([UInt8(t.index)]) + jpeg) else { return }
                    }
                    let wait = interval - Date().timeIntervalSince(started)
                    if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                }
            } catch is CancellationError {
            } catch {
                let reason = Self.hasPermission
                    ? "Couldn't capture the Mac's screen: \(error.localizedDescription)"
                    : "Allow Screen Recording for DigitalControlerMac on your Mac, then reopen it."
                _ = await send(.screenError, Data(reason.utf8))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        displayBounds = nil
    }

    /// Every display, left to right as arranged in System Settings → Displays.
    // ponytail: read once per start; plugging a display in mid-share needs reopening the Screen tab.
    private static func displays() async throws -> [(name: String, bounds: CGRect, filter: SCContentFilter)] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let sorted = content.displays
            .map { (display: $0, bounds: CGDisplayBounds($0.displayID)) }
            .sorted { ($0.bounds.minX, $0.bounds.minY) < ($1.bounds.minX, $1.bounds.minY) }
            .prefix(Int(UInt8.max)) // index travels in one byte
        guard !sorted.isEmpty else { throw CocoaError(.featureUnsupported) }
        return sorted.enumerated().map { i, d in
            (name(of: d.display.displayID) ?? "Display \(i + 1)", d.bounds, SCContentFilter(display: d.display, excludingWindows: []))
        }
    }

    private static func name(of id: CGDirectDisplayID) -> String? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }?.localizedName
    }

    /// Scaled so the longest edge is at most `maxEdge` pixels, never past Retina's 2×.
    private static func config(_ bounds: CGRect, _ maxEdge: Int) -> SCStreamConfiguration {
        let scale = min(2, CGFloat(max(maxEdge, 160)) / max(bounds.width, bounds.height))
        let config = SCStreamConfiguration()
        config.width = Int(bounds.width * scale)
        config.height = Int(bounds.height * scale)
        config.showsCursor = true
        return config
    }

    nonisolated private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        // ponytail: fixed quality; the Settings quality picker comes in phase 8.
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
