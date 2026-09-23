//
//  DigitalControlerMacApp.swift
//  DigitalControlerMac
//

import SwiftUI
import ApplicationServices

@main
struct DigitalControlerMacApp: App {
    @State private var server = Server()

    init() {
        // Shows the system "allow Accessibility" prompt on first launch.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    var body: some Scene {
        // The icon turns into a display while the iPhone is watching the screen, so it's never a secret.
        MenuBarExtra("DigitalControler", systemImage: server.sharingScreen ? "display" : "hand.point.up.left") {
            Text("PIN: \(server.pin)")
            Text(server.status)
            if AXIsProcessTrusted() {
                Text("Accessibility: allowed ✓")
            } else {
                Text("Accessibility: NOT allowed. Cursor won't move.")
                Button("Allow Accessibility… (then quit & reopen)") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
            if ScreenStreamer.hasPermission {
                Text(server.sharingScreen ? "Sharing screen with iPhone" : "Screen Recording: allowed ✓")
            } else {
                Text("Screen Recording: NOT allowed. iPhone can't show the screen.")
                Button("Allow Screen Recording… (then quit & reopen)") {
                    CGRequestScreenCaptureAccess()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            Divider()
            Button("New PIN") { server.newPin() }
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
