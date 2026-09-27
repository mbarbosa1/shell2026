# UI: iOS app

The iPhone app everything else plugs into. Source: `UI/ShellApp/ShellApp/`. Designs: the two PNGs in `UI/`.

## Stack

| Framework | Used for |
|---|---|
| SwiftUI | Every screen |
| Observation | `AppModel` state (`@Observable`) |
| SwiftData | Grocery lists, history, and the product catalog (`Models.swift`) |
| AVFoundation | `Narrator` (speech before the agent starts), mic permission |
| UIKit | VoiceOver notifications, keeping the screen awake while shopping |

Target: iOS 17.0, iPhone only, portrait, Swift 5 mode.

## Screens

| File | Screen |
|---|---|
| `RootView.swift` | Two-tab bar (Shop, History) from the Figma |
| `ShopView.swift` | The open list, the listen button, **Start shopping**, **Finish list** |
| `HistoryView.swift` | Finished lists and their change history |
| `OnboardingView.swift` | Voice-guided welcome and mic permission |
| `CameraScreen.swift` | Shown while shopping: camera, "Looking for …" pill, Yes/No card, mic button |
| `Navigation/RouteView.swift` | Route drawn on the store map |
| `Recognition/TrialsView.swift` | Tester-only recognition trials |
| `Theme.swift` | Colors sampled from the Figma (dark indigo and lavender) |

`AppModel.swift` owns the state and wires the parts together: voice, database, navigation, scanner, cart, and watch.

## Data

`GroceryDatabase` (in `Models.swift`) opens one SwiftData container with two files:

- `default.store`: the user's lists (`GroceryList`, `GroceryItem`). Never replaced.
- `catalog.store`: Target products, rebuilt from the bundled `Scripts/output/products.json` when that file changes.

Only one list is open at a time. **Finish list** moves it to History and starts the next number.

## Accessibility

- The voice agent turns off while VoiceOver is on, so the two don't talk over each other.
- `Narrator` reads text aloud before the agent is connected. If `onboarding_<n>.mp3` clips exist in the bundle, it plays those instead, so the voice matches Mira's.
- Every navigation and scan message is spoken **and** sent to the watch.

## Settings app switches (`Settings.bundle`)

| Switch | Effect |
|---|---|
| Replay onboarding | Shows onboarding again next time the app opens |
| Tester mode | Debug builds: adds a **Trials** button to Shop for recognition trials |

## Permissions (already in build settings)

Camera, Microphone, Bluetooth, and Local Network. `Info.plist` adds `NSAllowsLocalNetworking` for the Gemini proxy.

## Run it

1. Open `ShellApp.xcodeproj` (repo root) in Xcode 26.3+.
2. **Signing & Capabilities → Team**: pick yours. Set a unique bundle ID.
3. Choose your iPhone and press ⌘R.

Adding files: the project uses synced folders, so new files in `UI/ShellApp/ShellApp/` are picked up automatically.
