# PersonDistance

How far things are from the shopper, measured with the iPhone's LiDAR. Every piece of phone-to-object and hand-to-object distance code in the project lives in this folder. App code (ShellApp) only passes in boxes and points and displays or acts on the results.

Status, September 27, 2026: steps 1–5 and the self-checkout distance are implemented. They build for iOS device and simulator, and 33 Mac tests pass here (175 in ItemRecognition, 12 for the proxy). **Nothing has been measured on a phone or the cart yet**: the thresholds below are drafts, and step 8 is the test that sets them.

## What it measures

| Measurement | From → to | Starts | Ends | Used for |
|---|---|---|---|---|
| **Product distance** | Rear camera → the product | When the shopper says **Yes** to "Is this Oat milk?" | Pickup done, No, product lost, or shopping ends | Pointing the arm at the product; the "From camera" pill |
| **User distance (hand → product)** | The shopper's fingertip → the product | When the arm has centered on the product and hand guiding starts | "Got it", or pickup stops | "Reach further" and the 3D "got it" on the watch |
| **Self-checkout distance** | Rear camera → the self-checkout machine | As soon as the machine is recognized (no Yes: the shopper can't be asked "Is this the self checkout?") | Reached, lost, or the route ends | "Self checkout on your right, 2 meters" and the reached cue |

**User distance** is the hand-to-product option. HandGuide (ShellApp) finds the index fingertip with Apple Vision's hand pose detection. PersonDistance reads the LiDAR depth at that fingertip and compares it with the product's position, which is frozen in world coordinates just before the hand covers it. The result is a `HandSample`:

- **meters**: straight-line distance from the fingertip to the product.
- **gap**: how far the product is behind the fingertip, along the camera's view. A positive gap means the hand is lined up but hasn't reached the product yet.

`HandReachPolicy` turns that into "touching" (gap within 5 cm), "reach further" (more than 5 cm short), or "can't tell" (no confident depth at the fingertip). "Got it" needs "touching" for about half a second. A hand that only covers the product on screen is not enough.

## Setup this is built for

- **Phone:** iPhone 18 Pro, which has LiDAR, in a pan/tilt clamp on the cart (`ArmController`, three servos). The phone doesn't move with the shopper, so phone distance is not the shopper's distance. That's why the user-distance option measures the hand.
- **App:** ShellApp, with cues on the existing ShellWatch app. The ItemRecognition Demo is not a target.
- **Scene depth** is checked at runtime (`supportsFrameSemantics(.sceneDepth)`). Without LiDAR there is no distance at all, rather than a guessed one: the raycast fallback was removed.
- **Watch:** Apple Watch Series 5 is not on the watchOS 27 compatibility list. Test Series 5 and a current watch as separate cases before claiming either.

## Decisions (user, September 27, 2026)

1. **Trigger:** product distance starts at the shopper's **Yes**, not at recognition's automatic confirmation. Recognition's "settle after one frame" rule has not been validated for starting guidance without a person's check. The product is only *followed* (tracked) while the question is asked.
2. **User distance = hand to product**, as above.
3. **Collected:** an item is checked off when the fingertip reaches it in 3D. The watch plays success and the next item starts. Saying "check it off" still works.
4. **Pickup guidance:** the existing hand cues (left, right, up, down, got it), plus one new watch cue, **"reach further"** (`handForward`, WKHapticType `.retry`, repeating like the other hand directions).
5. **Self-checkout:** the machines are along the **Entrance ↔ Turn 1** walkway (7.48 m, store-walk calibration), on the **right** when walking from Turn 1 toward the entrance. Every route now ends by driving that row. This replaces the old 58.86 m "Cashier" end, whose map position was a guess.
6. **Self-checkout recognition:** Gemini (the existing cloud proxy, new `/v1/self-checkout` endpoint) is **primary**. Apple Vision is the fallback when the proxy isn't set up, fails, or times out. The fallback reads sign and screen text ("Self Checkout", "Scan", "Pay") and uses the classifier labels `atm`, `computer_monitor` and `machine` as support. Apple Vision's 1,303 labels include no checkout, register or kiosk label. Recognition lives in ItemRecognition (`Landmarks/`); only the distance is here.

## Rules

- **One object only:** the product recognition matched, or the only object in view, never a region around several.
- **Same frame:** a box and the depth it's measured in always come from the same `ARFrame` (`CameraSnapshot`). The frame is copied off `ARFrame` at once, because holding frames stalls ARKit.
- **Coordinates:** every box and point passed in is in ARKit's landscape `capturedImage` pixels from the top left. App code converts from Vision's upright coordinates with ItemRecognition's `VisionRegionOfInterest`.
- **LiDAR only while measuring:** `ProductRangeSession` adds `.sceneDepth` to the running configuration without reset options, and removes it when it stops. The camera service never turns it on. There is one `ProductRangeSession` per app; pickup and the self-checkout finder never run at the same time.
- **No reading beats a wrong one:** `SpatialValidityPolicy` rejects readings with little confident depth, disagreeing depths, or old frames.
- **No hand claims from phone distance:** hand advice comes only from the fingertip's own depth. Without it, pickup falls back to on-screen (2D) guidance and says so on screen.

## How it runs

**At each stop** (ShellApp `ItemScanner` + `PickupGuide`):

1. The arm sweeps the shelf: the map's side when known, otherwise left then right. Recognition looks for the item.
2. Recognition asks "Is this Oat milk?". The arm holds, and `ProductRangeSession.follow` tracks the one matched product with Vision object tracking.
3. **Yes:** `measure` turns LiDAR on. The arm centers on the tracked box.
4. Centered: `anchorProduct` freezes the product's world position from the latest valid reading and stops tracking, since the hand is about to cover it.
5. Hand guiding: each check takes one `CameraSnapshot`. HandGuide finds the fingertip, and PersonDistance gives the `HandSample`. The watch plays left, right, up or down until the hand is lined up, then "reach further" until it touches.
6. Touching for about 0.5 s: "Got it." The item is checked off, LiDAR goes off, and the next item starts. If the product is lost before anchoring, the item is looked for again.

Tester test scans (Trials screen) stop at the validated Yes and skip pickup. With no single product box, or no LiDAR, a Yes checks the item off straight away, as before pickup was connected.

**After the last item** (`RouteNavigator` + `CheckoutFinder`): the route drives Turn 1 → Entrance ("Turn …, then go straight 7 meters past the self checkouts, on your right"). The arm looks ahead and to the right (`ArmController.lookoutPoses`). Every 0.7 s a frame, copied down to 960 px so ARKit's buffer isn't held during the call, goes to Gemini first. Apple Vision answers when Gemini isn't set up or fails, and for 10 s of camera time after a failure. Once a machine is sighted, `measureNow` follows and measures it, and the shopper hears "Self checkout on your right", then "about 3 meters" when the distance changes. At 1.5 m or closer, "You've reached the self checkout" ends the trip. If the row ends first, the shopper hears either "The self checkout is right here, on your right" (it was seen) or that none was found and to ask staff.

## Where the app uses it

| App file | Uses |
|---|---|
| `UI/ShellApp/ShellApp/Recognition/ItemScanner.swift` | `follow` on the question, `measure` on Yes; checks the item off when pickup finishes |
| `UI/ShellApp/ShellApp/PickupGuide.swift` | `box` to center the arm, `anchorProduct()`, `CameraSnapshot` and `handSample(at:in:)` for each hand check, `HandReachPolicy` |
| `UI/ShellApp/ShellApp/HandGuide.swift` | Finds the fingertip on screen (Vision hand pose); no distance code |
| `UI/ShellApp/ShellApp/Recognition/CheckoutFinder.swift` | `measureNow` for the self-checkout, `sample` for the spoken distance |
| `UI/ShellApp/ShellApp/CameraScreen.swift` | Pills: "From camera", "Hand to item", "Self checkout" |
| `ItemRecognition/Sources/ItemRecognition/Landmarks/` | Self-checkout recognition (Gemini first, Apple Vision fallback); no distance code |
| `ItemRecognition/CloudProxy/server.py` | `POST /v1/self-checkout` for Gemini |
| `UI/ShellApp/ShellWatch/WatchReceiver.swift` | The "reach further" cue (`handForward`, `.retry`) |

## Files

| File | What it does |
|---|---|
| `Sources/PersonDistanceCore/DistanceSample.swift` | One product reading: meters, depth coverage, depth spread, frame time |
| `Sources/PersonDistanceCore/DepthGeometry.swift` | Depth window, median/coverage/spread, off-axis range, 3D points, box conversions |
| `Sources/PersonDistanceCore/SpatialValidityPolicy.swift` | Which product readings are good enough |
| `Sources/PersonDistanceCore/MeasurementGate.swift` | Follow on the question, measure only after Yes |
| `Sources/PersonDistanceCore/HandReach.swift` | `HandSample` and `HandReachPolicy` (touching, reach further, can't tell) |
| `Sources/PersonDistanceIOS/ProductDepthEstimator.swift` | `CameraSnapshot`, and a product's LiDAR reading in it |
| `Sources/PersonDistanceIOS/ConfirmedProductTracker.swift` | Vision object tracking of the confirmed product |
| `Sources/PersonDistanceIOS/ProductRangeSession.swift` | The one object apps use: follow, measure, anchor, hand samples, LiDAR on/off |
| `Tests/PersonDistanceCoreTests/` | Geometry, validity, gate and hand-reach tests (run on a Mac: `swift test`) |

`PersonDistanceCore` imports no ARKit, so its tests run on a Mac. `PersonDistanceIOS` only compiles for iOS.

## Draft thresholds (set them from the bench test)

| Setting | Draft | Where |
|---|---|---|
| Minimum confident depth over the product | 30% of the box's middle half | `SpatialValidityPolicy.minimumCoverage` |
| Largest depth spread over one face | 8 cm (25th–75th percentile) | `SpatialValidityPolicy.maximumSpread` |
| Oldest usable frame | 0.5 s | `SpatialValidityPolicy.maximumAge`, `HandReachPolicy.maximumAge` |
| Product lost after | 1 s unseen | `ProductRangeSession.lostAfter` |
| Touching | fingertip within 5 cm of the product's depth | `HandReachPolicy.touchingGap` |
| Self-checkout reached | 1.5 m from the camera | `CheckoutFinder.reachedMeters` |

## Status by step

| Step | What | Status |
|---|---|---|
| 1 | Core target and tests | Done (`9c04ac1`); 21 Mac tests |
| 2 | Same-frame measuring, no frozen reading | Done (`9c04ac1`) |
| 3 | Measure only after Yes; LiDAR only while measuring | Done (`9c04ac1`) |
| 4 | Hand-to-product distance (user distance) | Implemented; 12 new Mac tests; not measured on a phone |
| 5 | Pickup connected: sweep, center, hand guidance, check-off on touch | Implemented; builds; not run on the cart |
| — | Self-checkout: route end, recognition (Gemini first), distance, guidance | Implemented; 14 recognition tests and 6 proxy tests; not run in the store |
| 6 | Watch cues | Partly: "reach further" added with step 5 (type-checked for watchOS); proximity pulses not planned yet |
| 7 | README | This file |
| 8 | Phone and cart bench test | Not started (needs the cart and the store) |

## Bench test (step 8, on the cart)

1. **Product distance:** one opaque package, well lit, at 1.0, 0.75 and 0.5 m from the rear camera, measured with a tape. Record the reading, the depth coverage and spread, and the latency. Proposed target, not yet approved: 90% of valid readings within 10 cm.
2. **Trigger:** confirm no reading and no LiDAR before Yes, and that a reading appears after Yes without another tap.
3. **Hand:** reach slowly toward the product. "Reach further" should play until the fingertip touches, and "got it" only when it does. Hover 10–20 cm in front: there must be no "got it". Try a sleeve, a glove, and a hand coming in from the side.
4. **Tracking:** move the cart a little while "Is this …?" is asked. Occlude the product, and put a similar neighbor beside it.
5. **Self-checkout:** drive Turn 1 → Entrance with and without the proxy running. Note where it's first sighted, the spoken distance, and the reached point.
6. **Session:** after enabling and disabling LiDAR mid-walk, check that navigation tracking doesn't jump. Watch battery and heat over a full trip.
