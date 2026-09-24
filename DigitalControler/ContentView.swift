//
//  ContentView.swift
//  DigitalControler
//

import SwiftUI

struct ContentView: View {
    @State private var client = Client()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if client.connected || client.reconnecting {
                RemoteView(client: client)
            } else {
                ConnectView(client: client)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .task { client.startBrowsing() }
        // The pairing QR code is a digitalcontroler:// link, so the iPhone's Camera app can pair too.
        .onOpenURL { url in
            if let code = PairingCode(url: url) { client.pair(with: code) }
        }
        .alert(client.error ?? "", isPresented: Binding(get: { client.error != nil }, set: { if !$0 { client.error = nil } })) {
            Button("OK") {}
        }
    }
}

#Preview {
    ContentView()
}
