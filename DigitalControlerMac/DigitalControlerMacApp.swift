//
//  DigitalControlerMacApp.swift
//  DigitalControlerMac
//

import SwiftUI
import ApplicationServices
import CoreImage.CIFilterBuiltins

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
            MenuContent(server: server)
        }

        Window("Pair iPhone", id: "pair") {
            PairView(server: server)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed) // only when asked for, from the menu
    }
}

private struct MenuContent: View {
    let server: Server
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Pair iPhone…") {
            openWindow(id: "pair")
            NSApp.activate() // menu bar apps don't come forward on their own
        }
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
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// The QR code an iPhone scans to pair. Anyone who can see it can pair, so it's only shown on request.
private struct PairView: View {
    let server: Server
    @State private var confirmingReset = false

    var body: some View {
        let code = server.pairingCode
        VStack(spacing: 16) {
            Text("Scan to pair your iPhone").font(.title2.bold())
            Image(nsImage: Self.qr(code.url.absoluteString))
                .interpolation(.none) // keep the modules crisp
                .resizable()
                .frame(width: 240, height: 240)
                .padding(12)
                .background(.white, in: .rect(cornerRadius: 12))
                .accessibilityLabel("Pairing QR code for \(code.name)")
            Text("Open DigitalControler on your iPhone and tap **Scan QR code**, or point the iPhone's Camera at it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(width: 280)
            Button("Reset pairing…", role: .destructive) { confirmingReset = true }
                .confirmationDialog("Reset pairing?", isPresented: $confirmingReset) {
                    Button("Reset", role: .destructive) { server.resetPairing() }
                } message: {
                    Text("Every iPhone paired with this Mac will need to scan the new code.")
                }
        }
        .padding(28)
    }

    private static func qr(_ text: String) -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return NSImage() }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
