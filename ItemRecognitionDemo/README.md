# iPhone text extraction demo

Barebones standalone app for a **physical iPhone running iOS 17 or later**.
It uses the local `../ItemRecognition` package. Keep both folders together.
No account, database, localization service, downloaded model, or image fixtures are needed.

## Install and run on your iPhone

1. Open `ItemRecognitionDemo.xcodeproj` in Xcode 16 or later. Use an Xcode
   version that supports the iOS version installed on your phone.
2. Connect your iPhone to the Mac with a cable. Unlock it and accept **Trust This
   Computer** if prompted. Let Xcode finish pairing/preparing the device.
3. On the iPhone, enable **Settings > Privacy & Security > Developer Mode**.
   Restart and confirm if requested. The option may appear after pairing with Xcode.
4. In Xcode, select the blue project icon, then the **ItemRecognitionDemo** app
   target. In **Signing & Capabilities**, keep **Automatically manage signing**
   enabled and select your development team. Add your Apple Account in Xcode's
   settings if there is no team available; a Personal Team can be used for testing.
5. Replace the example bundle identifier `com.example.ItemRecognitionDemo` with
   a unique value, such as `com.yourname.ItemRecognitionDemo`, if signing requires it.
6. Select the **ItemRecognitionDemo** scheme and **your iPhone's name** as the
   destination. Do not select an iPhone simulator or a generic build-only destination.
7. Press **Command-R**. Follow any signing/developer-trust instructions Xcode or
   the phone presents, then allow camera access when the app asks.

## Test extraction

1. Hold the phone **upright in portrait**. The app uses the rear wide-angle camera.
2. Point at a clear product label or printed page in good lighting. Keep it in
   focus and avoid holding it too close to the lens.
3. The camera preview appears above the latest extracted lines. Each line shows
   raw text, normalized text, and OCR confidence. The status reports line count
   and detection-plus-OCR time; this is not a product-identity score.
4. Tap **Stop (keep text)** to freeze the result for inspection. Tap **Start camera**
   to clear the old text and start a fresh recognition session.
5. If text disappears, the latest eligible frame contained no detected region or
   readable text. Move closer, improve lighting, or try larger printed text.

The camera stops when the app becomes inactive and starts again when it returns
to the foreground. If access is denied, use the in-app settings button to allow
camera access, then return and tap Start if necessary. There is no microphone
access, recording, image saving, or upload.

## What this exercises

The demo owns one `AVCaptureSession` and supplies upright BGRA pixel buffers to
the existing `TextExtractionScheduler`. The scheduler uses its default automatic
`VisionLabelRegionDetector` and real `VisionTextRecognizer`. No explicit crop is
supplied. It processes every fifth submitted active frame; capture drops incoming
frames while a submission runs rather than creating an unbounded task backlog.

The demo-only `CatalogReading` implementation supplies a fixed activation rule
with a 3–20 metre window. The demo supplies reliable progress of 5 metres past
`demo-aisle`, so the gate is active without actual localization. It supplies no
catalog candidates and does not identify products or confirm matches.

Both the capture buffers and preview are rotated to portrait. Do not add a second
orientation correction: the buffer passed to recognition already uses `.up`.
Each Start creates a new scheduler; results from an earlier stopped run are discarded.
Capture configuration and start/stop run on a serial background queue; UI updates
run on the main actor. The standalone demo owns the camera, not the library.

## Build check without a phone or signing

From the repository root:

```sh
xcodebuild -project ItemRecognitionDemo/ItemRecognitionDemo.xcodeproj \
  -scheme ItemRecognitionDemo -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/ItemRecognitionDemoBuild \
  CODE_SIGNING_ALLOWED=NO build
```

This only checks an iPhone-target build. It does not install the app or verify
camera operation. Use the signed Command-R workflow above for physical testing.

Verified: unsigned Debug build for physical iPhone (`arm64`, minimum iOS 17)
succeeded with Xcode 27.0. No physical-device camera run has been performed yet.
