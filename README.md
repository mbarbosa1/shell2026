# Mira

A voice-first grocery assistant for blind and low-vision shoppers, built at ShellHacks 2026.

You build the list by talking to **Mira** (the voice agent). At the store, an iPhone mounted on the
cart guides you aisle by aisle with ARKit. The camera finds each product on the shelf, and an Apple
Watch gives every cue as a vibration: turns, obstacles ahead, and which way to move your hand.

![Screens](UI/Shellhacks%20%E2%80%94%20Voice%20Grocery%20iOS.png)

## Parts

| Part | What it does | Docs | Owner |
|---|---|---|---|
| UI (iOS app) | SwiftUI app: list, history, onboarding, camera screen | [docs/ui.md](docs/ui.md) | Camila, Arwa (onboarding) |
| Voice agent | ElevenLabs conversational agent "Mira" and its client tools | [docs/voice-agent.md](docs/voice-agent.md) | Camila, Arwa (onboarding) |
| Computer vision | On-device OCR, produce classification, hand pose, LiDAR distance | [docs/computer-vision.md](docs/computer-vision.md) | Humberto, Arwa (hand guide) |
| Item recognition logic | Target catalog, list-to-product matching, the "Is this …?" flow | [docs/item-recognition.md](docs/item-recognition.md) | Camila (catalog), Humberto (matching) |
| In-store navigation | ARKit tracking, store map, route planning | [docs/navigation.md](docs/navigation.md) | Gerard |
| Smartwatch haptics | watchOS app that plays every cue on the wrist | [docs/watch-haptics.md](docs/watch-haptics.md) | Gerard, Arwa |
| 3D model / cart hardware | ESP32 cart arm: 3 servos, phone clamp, ultrasonic sensor | [docs/cart-hardware.md](docs/cart-hardware.md) | Arwa |

## How it fits together

```
 Voice (ElevenLabs) ──client tools──▶ AppModel ◀──▶ SwiftData
                                          │         (lists + catalog)
          ┌──────────────────┬────────────┴─────┬──────────────────┐
          ▼                  ▼                  ▼                  ▼
   RouteNavigator       ItemScanner       CartBluetooth        WatchLink
       (ARKit)           (Vision)        (BLE, ESP32)     (WatchConnectivity)
                                                                   │
                                                                   ▼
                                                              ShellWatch
                                                         (Apple Watch haptics)
```

The navigator, scanner, and cart report back to `AppModel`, which speaks each cue and sends it to the watch through `WatchLink`.

## Quick start

1. Install **Xcode 26.3 or newer** (the team used 26.3 and 27) and select it: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
2. Open `ShellApp.xcodeproj` at the repo root. Swift packages (ElevenLabs SDK, local `ItemRecognition`, `PersonDistance`) resolve on their own.
3. Under **Signing & Capabilities**, pick your team. Set a unique bundle ID (e.g. `com.<you>.ShellApp`).
4. Set the environment variables in **Product → Scheme → Edit Scheme → Run → Arguments** (see [voice-agent.md](docs/voice-agent.md)).
5. Run on a **physical iPhone** (iOS 17+). The simulator has no camera, ARKit, or Bluetooth, so shopping falls back to a simulated walk.

Optional: add the watch target ([watch-haptics.md](docs/watch-haptics.md)), flash the cart ([cart-hardware.md](docs/cart-hardware.md)), and start the Gemini proxy ([computer-vision.md](docs/computer-vision.md)).

## Environment variables (scheme only, never committed)

| Name | Required | Used by |
|---|---|---|
| `ELEVENLABS_AGENT_ID` | Yes, for voice | `VoiceConfig.swift` |
| `ELEVENLABS_API_KEY` | Only for a private agent (Debug builds) | `VoiceConfig.swift` |
| `CLOUD_PROXY_URL` | No | `CloudAssistConfig.swift` (Gemini produce assist) |
| `CLOUD_PROXY_TOKEN` | With `CLOUD_PROXY_URL` | `CloudAssistConfig.swift` |

Keep your own copies in `.env` (git-ignored). The app can't read `.env`; paste the values into the scheme.

## Repo map

| Path | Contents |
|---|---|
| `UI/ShellApp/ShellApp/` | iPhone app source |
| `UI/ShellApp/ShellWatch/` | Apple Watch app source |
| `ItemRecognition/` | Swift package: recognition pipeline, demo app, Gemini proxy, baseline tools |
| `PersonDistance/` | Swift package: phone-to-product distance (LiDAR) |
| `Scripts/` | Target HAR scraper and the SwiftData catalog |
| `firmware/` | ESP32 cart firmware (PlatformIO) |
| `map-preview/` | Drawings of the store map |
| `DEPENDENCIES.md` | Every tool and package, with versions |
| `PROJECT_MEMORY.md` | Recognition design decisions log |

## Limits of this MVP

- The store map is **Aventura Target** only. Another store needs new calibration walks ([navigation.md](docs/navigation.md)).
- API keys are read on the device in Debug builds only. A shipped app needs a backend that issues tokens.
