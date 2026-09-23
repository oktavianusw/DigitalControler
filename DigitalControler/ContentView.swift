//
//  ContentView.swift
//  DigitalControler
//
//  Created by Jua on 23/09/26.
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
        .alert(client.error ?? "", isPresented: Binding(get: { client.error != nil }, set: { if !$0 { client.error = nil } })) {
            Button("OK") {}
        }
    }
}

#Preview {
    ContentView()
}
