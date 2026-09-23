# DigitalControler

Turn your iPhone into a trackpad and keyboard for your Mac, over your local Wi-Fi.

Move the pointer, tap to click, scroll with two fingers, drag, pinch to zoom, swipe with three fingers for
Mission Control, type on a full Mac keyboard, or fire common shortcuts, all from your phone.

## How it works

An iPhone can't pretend to be a Bluetooth trackpad (iOS doesn't let apps act as a Bluetooth input device),
so DigitalControler comes in two parts:

```
iPhone app ──(local Wi-Fi, TLS)──▶ Mac helper (menu bar) ──(CGEvent)──▶ pointer, clicks, scroll, keys
reads your fingers                  turns messages into real input events
```

- **Discovery:** the Mac helper announces itself with Bonjour (`_digitalctl._tcp`), so the iPhone finds it
  with no IP typing. If Bonjour is blocked on your network, you can connect by IP (the helper listens on port `51515`).
- **Pairing and encryption:** the helper shows a 6-digit PIN in the menu bar. The PIN becomes a TLS pre-shared key,
  so a wrong PIN fails the handshake and all traffic is encrypted. After 10 wrong PINs the helper stops
  accepting connections until you make a new PIN.
- **Protocol:** every message is 9 bytes (1-byte kind + two Float32 values), sent over TCP with Nagle off.
  The traffic is marked as interactive so Wi-Fi power saving doesn't hold packets back.
- **Input on the Mac:** the helper posts `CGEvent`s. Scrolls are trackpad-style (continuous pixel deltas with
  scroll and momentum phases), so apps rubber-band and glide like they do with a real trackpad.

## Features

**Trackpad**

| Gesture | Does |
|---|---|
| One finger | Move the pointer (with acceleration) |
| Tap | Left click (tap twice quickly to double-click) |
| Two-finger tap | Right click |
| Hold, then move | Drag (the phone vibrates when it grabs) |
| Two fingers | Scroll, with momentum when you flick |
| Pinch | Zoom in / out (⌘+ / ⌘−) |
| Three fingers up / down | Mission Control / App windows |
| Three fingers left / right | Switch desktop (Space) |

Also on the trackpad screen: Left and Right click buttons you can hold (hold Left click with your thumb and
drag on the pad), a one-finger scroll strip, and a live connection latency readout.

**Keyboard:** a full Mac layout with sticky modifiers (tap ⌘, then C) and caps lock.

**Shortcuts:** a "Type to Mac" field that types anything, including emoji, plus one-tap buttons for Copy, Paste,
Undo, Spotlight, Switch app, Mission Control, volume, and play/pause. It also has a mini trackpad.

**Settings:** tracking and scroll speed, natural scrolling, tap to click, orientation lock
(portrait / landscape, works even with rotation lock on), haptics, and toggles for every on-screen extra.
The app reconnects to your last Mac automatically.

## Requirements

- iPhone on iOS 18.6 or later
- Mac on macOS 15 or later
- Xcode 26 or later
- Both devices on the same Wi-Fi network

## Setup

1. **Clone and open** `DigitalControler.xcodeproj`. In *Signing & Capabilities*, set your own team for the
   `DigitalControler` and `DigitalControlerMac` targets.
2. **Build the Mac helper:** run the `DigitalControlerMac` scheme. A hand icon appears in the menu bar with the PIN.
   Tip: copy the built app to `~/Applications` and open it from there. macOS ties the Accessibility permission
   to the app's location, and Xcode's build folder moves around.
3. **Allow Accessibility:** System Settings → Privacy & Security → Accessibility → turn on **DigitalControlerMac**.
   Then quit the helper from its menu and open it again. macOS only lets an app post input events after a relaunch.
4. **Run the iPhone app:** run the `DigitalControler` scheme on your iPhone and allow Local Network access.
5. **Pair:** tap your Mac, enter the PIN from the menu bar, and you're in.

## Troubleshooting

- **The pointer doesn't move.** Open the helper's menu. If it says *Accessibility: NOT allowed*, grant it
  (step 3) and relaunch the helper.
- **The helper isn't in the Accessibility list.** Click **+** under the list and pick the app. Alternatively, reset
  its permission so macOS asks again:
  ```bash
  tccutil reset Accessibility com.jua.DigitalControlerMac
  ```
- **The Mac doesn't show up on the iPhone.** Check that both devices are on the same Wi-Fi and that Local Network
  access is on for DigitalControler (iPhone Settings → Privacy & Security → Local Network). Or use
  *Enter IP manually*.
- **"Couldn't connect. Check the PIN".** The PIN changes when you click *New PIN*. Use the one shown in the menu bar.

## Project structure

```
Shared/Protocol.swift             Wire format, service name/port, TLS-PSK pairing (used by both apps)

DigitalControler/                 iPhone app
  Client.swift                    Bonjour browsing, connection, auto-reconnect, latency ping
  TouchpadView.swift              Multi-touch surface: pointer, taps, scroll, drag, pinch, 3-finger swipes
  RemoteView.swift                Connected screen: Trackpad and Shortcuts modes, click buttons, scroll strip
  KeyboardView.swift              Mac keyboard layout
  ConnectView.swift               Find and pair with a Mac
  SettingsView.swift, Prefs.swift Settings screen and stored preferences
  Theme.swift                     Monochrome glass styling

DigitalControlerMac/              Mac menu bar helper
  Server.swift                    Bonjour listener, PIN pairing, lockout, ping echo
  Injector.swift                  Turns messages into mouse, scroll, and keyboard events
```

## Known limitations

- **Pinch and three-finger gestures are approximations.** They send keyboard shortcuts, because real trackpad
  gesture events need private macOS APIs.
- **Keys don't auto-repeat when held.**
- **Not on the Mac App Store.** The helper runs outside the App Sandbox because it posts input events.
- **The PIN is short.** A 6-digit PIN is fine on a home network, but someone who records the pairing traffic
  could brute-force it offline. A long random key shared by QR code would fix that.
