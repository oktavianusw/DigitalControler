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
        MenuBarExtra("DigitalControler", systemImage: "hand.point.up.left") {
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
            Divider()
            Button("New PIN") { server.newPin() }
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
