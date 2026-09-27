# Computer vision

Everything that looks at camera frames. It all runs on the phone, except an optional Gemini call for hard produce.

| Code | Job |
|---|---|
| `ItemRecognition/` (Swift package) | Finds the list item on the shelf: label OCR for packages, image classification for produce |
| `PersonDistance/` (Swift package) | Phone-to-product distance from LiDAR |
| `UI/.../HandGuide.swift` | Finds the shopper's hand and says which way to move it |
| `ItemRecognition/CloudProxy/` | Small Python server that asks Gemini to label produce |

How a match becomes a checked-off item is in [item-recognition.md](item-recognition.md).

## Stack

| Framework | Used for |
|---|---|
| Vision | `VNRecognizeTextRequest` (OCR, `.accurate`), `VNDetectTextRectanglesRequest`, `VNDetectRectanglesRequest` (package crop), `VNGenerateForegroundInstanceMaskRequest` (object boxes), `VNClassifyImageRequest` (produce), `VNTrackObjectRequest`, `VNDetectHumanHandPoseRequest` (hand) |
| Core ML | `CoreMLVisualClassifier`, a slot for a custom model (none shipped) |
| ARKit | The one camera session: frames at up to 30 fps, LiDAR `sceneDepth`, raycasts |
| Core Image / CoreVideo | Cropping and pixel buffers |
| Python 3 (standard library only) | Gemini proxy |
| Google Gemini API | Optional produce labels (default model `gemini-3.1-flash-lite`) |

No third-party Swift packages. Vision request revisions are pinned (`VisionRevisions.swift`) so iOS updates can't quietly change results.

## Pipeline (per frame)

1. **Locate:** box the objects in view; skip frames that are blurry, moving, or taken while the lens refocuses.
2. **Read or classify:** the path is chosen once per item.
   - Packaged goods → crop to the package → OCR. No text-to-image fallback.
   - Loose produce → Apple Vision classifier, mapped to a broad class (onion, banana, apple, avocado, lime, orange, carrot).
3. **Guide:** while nothing is readable, tell the shopper to move left, right, or closer.
4. **Score** against the catalog, then ask the shopper (see [item-recognition.md](item-recognition.md)).

Only one frame is processed at a time, every 5th to 10th active frame. The full contract is in `ItemRecognition/DefiningSuccess.md`.

## Hand guide

`HandGuide` finds the index and middle fingertips and the wrist with `VNDetectHumanHandPoseRequest` and compares it to the product's box: left, right, up, down, or on the item. `PickupGuide` sends those as watch haptics. There's no model to train. For now it's triggered from the Debug **Test hand guide** button on the camera screen.

## Distance (PersonDistance)

`ProductDepthEstimator` measures one product: the median LiDAR depth in the middle of its box, converted to straight-line range. Without LiDAR it falls back to an ARKit raycast. The value is display-only ("Looking for Oat milk · 1.2 m"). Needs an iPhone Pro with LiDAR. The design plan is in `PersonDistance/README.md`.

## Run the tests

```bash
cd ItemRecognition && swift test                        # Swift unit tests (macOS 14+)
cd ItemRecognition/CloudProxy && python3 -m unittest test_server
```

## Standalone camera demo

`ItemRecognition/Demo/ItemRecognitionDemo.xcodeproj` runs recognition without the app, map, or database. Useful for tuning. See `ItemRecognition/Demo/README.md`.

## Optional: Gemini produce assist

Apple Vision always goes first. Gemini is asked only after 5 s at the item with no match, at most 2 calls per item. Packaged goods never leave the phone.

1. Get a key at [Google AI Studio](https://aistudio.google.com/apikey). Keep it on the Mac only.
2. Start the proxy on a Mac on the same Wi-Fi as the phone:
   ```bash
   cd ItemRecognition/CloudProxy
   GEMINI_API_KEY=<key> PROXY_TOKEN=<any password> python3 server.py
   # No key? Test the connection with: CLOUD_PROXY_MOCK_LABEL=onion PROXY_TOKEN=dev-token python3 server.py
   ```
3. In the app's scheme, set `CLOUD_PROXY_URL=http://<your-mac>.local:8787/v1/produce-label` and `CLOUD_PROXY_TOKEN=<same password>`.
4. Allow Local Network access on the phone when asked.

It's a development proxy (plain HTTP, one shared token). Details: `ItemRecognition/CloudProxy/README.md`.

## Measuring accuracy

Turn on **Tester mode** (Settings app → ShellApp). A **Trials** button appears on Shop; each item scan is logged to a CSV you can export. Protocol and summary script: `ItemRecognition/Baseline/README.md`. Training a custom model: `ItemRecognition/Training/README.md`.
