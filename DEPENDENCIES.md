# Dependencies

## Tools

| Tool | Version | Needed for |
|---|---|---|
| Xcode | 26.3 or newer (team used 26.3 and 27) | iOS app, watch app, Swift packages |
| iPhone | iOS 17+; a Pro model with LiDAR for distance | Camera, ARKit, Bluetooth (the simulator has none) |
| Apple Watch | Paired with the iPhone | Haptics (optional) |
| Python | 3.x, standard library only | HAR scraper, Gemini proxy |
| VS Code + PlatformIO IDE | Latest | Cart firmware (optional) |
| Apple ID | Free is fine | Installing on your devices |

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Packages

| Package | Version | Where | How it's installed |
|---|---|---|---|
| [elevenlabs-swift-sdk](https://github.com/elevenlabs/elevenlabs-swift-sdk) | 3.3.1 | iOS app (voice) | Swift Package Manager, automatic |
| livekit client-sdk-swift, webrtc-xcframework, livekit-uniffi | 2.17.0 / 150.7871.2 / 0.1.9 | Pulled in by ElevenLabs | Automatic |
| `ItemRecognition`, `PersonDistance` | Local | iOS app | Local Swift packages, automatic |
| [ESP32Servo](https://github.com/madhephaestus/ESP32Servo) | Latest | Firmware | PlatformIO `lib_deps`, automatic |
| espressif32 platform (Arduino framework) | Latest | Firmware | PlatformIO, automatic |

Everything else uses Apple frameworks: SwiftUI, SwiftData, Observation, ARKit, Vision, Core ML, AVFoundation, CoreBluetooth, WatchConnectivity, WatchKit.

## Accounts and keys

| Service | Needed for | Where the key goes |
|---|---|---|
| ElevenLabs | Voice agent | Xcode scheme env vars (`ELEVENLABS_AGENT_ID`, `ELEVENLABS_API_KEY`) |
| Google AI Studio (Gemini) | Optional produce assist | `GEMINI_API_KEY` on the Mac running the proxy, never in the app |

Setup per part: see [README.md](README.md) and [docs/](docs/).
