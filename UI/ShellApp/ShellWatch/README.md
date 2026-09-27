# ShellWatch

The Apple Watch side of navigation. The iPhone's `RouteNavigator` sends each cue over
WatchConnectivity (`WatchLink`), and this app plays it on the wrist:

| Cue | Feel |
|---|---|
| Turn right | 1 tap |
| Turn left | 2 taps |
| Turn around | 3 taps |
| Start walking | start pattern |
| Stop, you're at the item's aisle | stop pattern |
| Wrong way | failure pattern |
| Reached the cashier | success pattern |

New cues go in `WatchHaptic` on both sides: `ShellApp/WatchLink.swift` and `WatchReceiver.swift`.

## Adding the target (once, in Xcode)

1. File → New → Target → watchOS → **App**. Name it `ShellWatch`, and choose
   **Watch App for Existing iOS App** with `ShellApp` as the companion.
2. Delete the `ContentView.swift` and `ShellWatchApp.swift` Xcode generates, and add the two
   Swift files from this folder to the new target.
3. In the watch target → Signing & Capabilities → **+ Capability → Background Modes**, set
   **Session type** to **Physical therapy**. That lets `WKExtendedRuntimeSession` keep the app
   running for the trip with the wrist down, so cues still arrive.
4. Open the watch app before starting navigation on the phone.
