# Dependencies

Nothing in this repo uses third-party packages: no Swift packages, CocoaPods, or pip
installs. You only need Apple's tools and Python 3.

## What to install

| Tool | Version | Needed for |
|---|---|---|
| macOS | One that runs the Xcode below | Everything |
| Xcode | 16 or newer (built with Xcode 27) | Building the iOS app and the SwiftData scripts |
| iOS | 17.0 or newer, on an iPhone or simulator | Running the app |
| Python | 3.x (standard library only) | `Scripts/extract_har.py` |
| Apple ID | Free is fine | Installing on a physical iPhone |

The project uses Xcode 16's folder-synced project format, so older Xcode versions can't open it.

After installing Xcode, make sure it's the selected toolchain (not just Command Line Tools):

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

## iOS app: `UI/ShellApp`

The app uses only Apple frameworks:

| Framework | Used for |
|---|---|
| SwiftUI | All screens |
| Observation | `AppModel` state (`@Observable`) |
| SwiftData | Grocery list database: numbered lists, their items and history (`Models.swift`) |
| AVFoundation | Rear camera preview |
| Foundation | Models, dates |

Project settings: iOS deployment target 17.0, iPhone only, portrait only, Swift 5 language mode.

Permissions (already set in the target's build settings):

- `NSCameraUsageDescription`: the camera screen.

To run it, open `UI/ShellApp/ShellApp.xcodeproj`, choose an iPhone simulator or your iPhone,
and press ⌘R. On a physical iPhone, first choose your Apple ID under
**Signing & Capabilities → Team**. The simulator has no camera, so the camera screen shows
black there.

## Product data scripts: `Scripts/` (on `main` / `product_database`)

| File | Needs |
|---|---|
| `extract_har.py` | Python 3, standard library only |
| `run.sh` | bash, Python 3, `swiftc` from Xcode |
| `SwiftData/*.swift`, `verify_import.swift` | Full Xcode (SwiftData macros) |
| `verify_decode.swift` | Works with Command Line Tools alone |

```bash
cd Scripts
./run.sh            # ../milk.har + ../others.har → output/products.json, then verifies it
```

The HAR captures (`milk.har`, `others.har`) are local files and aren't committed.

## Coming later

When these parts are added, list their requirements here:

- **Voice agent / backend:** runtime, packages (e.g. a `requirements.txt`), and provider API keys (kept on the server, never in the app).
- **Microphone in the app:** `NSMicrophoneUsageDescription`, plus `NSSpeechRecognitionUsageDescription` if using Apple Speech.
- **Talking to a backend on your Mac over plain `http://`:** App Transport Security `NSAllowsLocalNetworking`, plus `NSLocalNetworkUsageDescription`.
