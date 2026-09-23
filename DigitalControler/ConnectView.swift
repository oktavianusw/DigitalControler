//
//  ConnectView.swift
//  DigitalControler
//

import SwiftUI
import Network

/// "Connect to your Mac": nearby Macs found over Bonjour, plus a manual IP fallback.
struct ConnectView: View {
    let client: Client
    @State private var pickedMac: NWEndpoint?
    @State private var pin = ""
    @State private var askingForIP = false
    @State private var ip = ""

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

                Button {
                    pin = ""
                    askingForIP = true
                } label: {
                    Text("Enter IP manually")
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glassCapsule)
                .padding(.top, 24)
            }
            .padding(20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .alert("Enter the PIN shown in your Mac's menu bar",
               isPresented: Binding(get: { pickedMac != nil }, set: { if !$0 { pickedMac = nil } }),
               presenting: pickedMac) { mac in
            TextField("PIN", text: $pin).keyboardType(.numberPad)
            Button("Connect") { client.connect(to: mac, pin: pin) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Connect by IP address", isPresented: $askingForIP) {
            TextField("192.168.1.20", text: $ip).keyboardType(.decimalPad)
            TextField("PIN", text: $pin).keyboardType(.numberPad)
            Button("Connect") { client.connect(host: ip, pin: pin) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The IP is in System Settings → Wi-Fi → Details on your Mac.")
        }
    }

    private func macCard(_ mac: NWEndpoint) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
                    .glass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(mac.name).font(.system(size: 16, weight: .semibold))
                    Text(Client.lastMac == mac.name ? "Last used" : "Nearby")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
            }
            Button("Connect") {
                pin = Client.savedPin(for: mac)
                pickedMac = mac
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(client.connecting)
        }
        .padding(16)
        .glassPanel(radius: 24)
    }
}
