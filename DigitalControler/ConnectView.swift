//
//  ConnectView.swift
//  DigitalControler
//

import SwiftUI
import Network
import Vision
import VisionKit

/// "Connect to your Mac": nearby Macs found over Bonjour. A Mac is paired once by scanning the QR code
/// from its menu bar; after that it connects with one tap.
struct ConnectView: View {
    let client: Client
    @State private var scanning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect to your Mac")
                    .font(.system(size: 34, weight: .bold))
                    .kerning(-0.6)
                Text("Same Wi-Fi network, helper app open on the Mac.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 16)

                HStack {
                    Caption("Nearby")
                    Spacer()
                    Caption(client.connecting ? "Connecting…" : "Scanning…")
                }
                .padding(.horizontal, 4)

                ForEach(client.macs, id: \.endpoint) { mac in
                    macCard(mac.endpoint)
                }

                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text(client.macs.isEmpty ? "Looking for Macs…" : "Looking for other Macs…")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)

                Button { scanning = true } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder")
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glassCapsule)
                .padding(.top, 24)
                Text("New Mac, or a network that hides it? On the Mac, open the Touche menu → Pair iPhone…")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .sheet(isPresented: $scanning) {
            ScanSheet { code in
                scanning = false
                client.pair(with: code)
            }
        }
    }

    private func macCard(_ mac: NWEndpoint) -> some View {
        let secret = Client.savedSecret(for: mac)
        return VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
                    .glass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(mac.name).font(.system(size: 16, weight: .semibold))
                    Text(secret == nil ? "Not paired yet" : Client.lastMac == mac.name ? "Last used" : "Paired")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
            }
            Button(secret == nil ? "Pair" : "Connect") {
                if let secret { client.connect(to: mac, secret: secret) } else { scanning = true }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(client.connecting)
        }
        .padding(16)
        .glassPanel(radius: 24)
    }
}

/// Camera view that picks up the Mac's pairing QR code.
private struct ScanSheet: View {
    let found: (PairingCode) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Scan to pair").font(.system(size: 22, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Text("Cancel").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 16).frame(height: 36)
                }
                .buttonStyle(.glassCapsule)
            }
            Text("On your Mac, click the Touche icon in the menu bar → Pair iPhone…, then point this camera at the code.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if DataScannerViewController.isSupported {
                    QRScanner(found: found)
                } else {
                    Text("This device can't scan here. Point the iPhone's Camera app at the code instead; it opens Touche.")
                        .font(.system(size: 14))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .glassPanel(radius: 24)
        }
        .padding(20)
        .foregroundStyle(.white)
        .presentationBackground(.black)
        .preferredColorScheme(.dark)
    }
}

/// VisionKit's live scanner, QR codes only. Reports the first valid pairing link it sees.
private struct QRScanner: UIViewControllerRepresentable {
    let found: (PairingCode) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (PairingCode) -> Void
        private var done = false
        init(found: @escaping (PairingCode) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in items {
                guard !done, let text = barcode.payloadStringValue, let url = URL(string: text),
                      let code = PairingCode(url: url) else { continue }
                done = true // one pairing per scan, even if the code stays in view
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                found(code)
            }
        }
    }
}

#Preview("Connect") {
    ConnectView(client: Client()).appChrome()
}

#Preview("Scan sheet") {
    ScanSheet { _ in }.appChrome()
}
