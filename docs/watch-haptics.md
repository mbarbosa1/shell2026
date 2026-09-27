# Smartwatch haptics

An Apple Watch app (`ShellWatch`) that plays every cue on the wrist, so the shopper can follow the route and reach for products without looking or listening.

Source: `UI/ShellApp/ShellWatch/` (watch), `UI/ShellApp/ShellApp/Navigation/WatchLink.swift` (phone).

## Stack

| Framework | Used for |
|---|---|
| WatchConnectivity | Phone → watch messages (`sendMessage`, live only; nothing is queued) |
| WatchKit | `WKHapticType` patterns, `WKExtendedRuntimeSession` to stay awake with the wrist down |
| SwiftUI | The watch screen (shows the latest cue as text) |

## Cues

| Cue | Feel | Sent by |
|---|---|---|
| Turn right / left / around | 1 / 2 / 3 taps | `RouteNavigator` |
| Start walking | start | `RouteNavigator` |
| Stop at the item's aisle | stop | `RouteNavigator`, and with "Is this …?" |
| Wrong way | failure | `RouteNavigator` |
| Reached the cashier | success | `RouteNavigator` |
| Obstacle ahead | failure, repeating until clear | `ObstacleDetector` (cart sensor) |
| Product found on shelf | 2 clicks | `PickupGuide` |
| Move hand left / right | 2 / 1 taps, repeating | `HandGuide` |
| Move hand up / down | rising / falling, repeating | `HandGuide` |
| Hand is on the product | success ×2 | `HandGuide` |

Obstacle alarm: on after 2 readings under 100 cm, off after 3 readings over 130 cm (or no echo). Tune it in `ObstacleDetector.swift`.

## Setup (the watch target isn't in the Xcode project yet)

1. In `ShellApp.xcodeproj`: **File → New → Target → watchOS → App**. Name it `ShellWatch`, choose **Watch App for Existing iOS App**, companion `ShellApp`.
2. Delete the generated `ContentView.swift` and `ShellWatchApp.swift`. Add `ShellWatchApp.swift` and `WatchReceiver.swift` from `UI/ShellApp/ShellWatch/` to the watch target.
3. Watch target → **Signing & Capabilities → + Capability → Background Modes**. Set **Session type** to **Physical therapy**.
4. Pair the watch with the iPhone, run the watch scheme once to install it.
5. **Open the watch app before starting navigation.** Cues sent while it's not reachable are dropped.

## Adding a cue

Add the case to the `WatchHaptic` enum on **both** sides (`WatchLink.swift` and `WatchReceiver.swift`). The raw values are the wire format, so they must match. Then give it a pattern in `WatchReceiver.swift`.
