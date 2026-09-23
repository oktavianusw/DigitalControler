//
//  DigitalControlerApp.swift
//  DigitalControler
//
//  Created by Jua on 23/09/26.
//

import SwiftUI
import UIKit

@main
struct DigitalControlerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// SwiftUI has no API to lock orientation; UIKit asks the app delegate instead.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
}

/// Touchpad orientation. Forcing it works even with the iPhone's rotation lock on.
enum PadOrientation: String, CaseIterable, Identifiable {
    case auto, portrait, landscape

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .auto: "arrow.triangle.2.circlepath"
        case .portrait: "iphone"
        case .landscape: "iphone.landscape"
        }
    }

    private var mask: UIInterfaceOrientationMask {
        switch self {
        case .auto: .allButUpsideDown
        case .portrait: .portrait
        case .landscape: .landscape
        }
    }

    func apply() {
        AppDelegate.orientationLock = mask
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }
}
