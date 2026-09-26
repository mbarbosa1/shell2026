# iPhone item recognition demo

Barebones standalone app for a **physical iPhone running iOS 17 or later**.
It uses the local `../ItemRecognition` and `../Scripts` packages. Keep these folders
together. The landing screen offers a database-backed test and the original
**Camera only (no database)** mode. No localization service or downloaded model is needed.

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

Choose **Camera only (no database)** on the landing screen for the original test.

1. Hold the phone **upright in portrait**. The app uses the rear wide-angle camera.
2. Point at a clear product label or printed page in good lighting. Keep it in
   focus and avoid holding it too close to the lens.
3. The camera preview is followed by an **Extracted text** card: the latest
   OCR lines, Vision's mean **OCR confidence** for that frame, and (in a
   database scan) the catalog **Match** confidence. Skipped frames keep the
   last extraction so the text does not flicker. The list below repeats each
   line with its own confidence. The status reports line count and
   detection-plus-OCR time; OCR confidence is Vision's read quality, not a
   product-identity score.
4. Tap **Stop (keep text)** to freeze the result for inspection. Tap **Start camera**
   to clear the old text and start a fresh recognition session.
5. If text disappears, the latest eligible frame contained no detected region,
   no readable text, or a package whose text was under 32 pixels tall. The
   guidance line under the preview says what to do ("Move closer to the item",
   "Move more to the right", …); otherwise improve lighting or try larger
   printed text.

The camera stops when the app becomes inactive and starts again when it returns
to the foreground. If access is denied, use the in-app settings button to allow
camera access, then return and tap Start if necessary. There is no microphone
access, recording, image saving, or upload.

## Test the database and activation together

1. Wait for the landing screen to show the imported product count (142 in the
   current bundled single-store capture; no store ID is required).
2. Select a product and then explicitly select one of its locations.
3. Enter a landmark ID, start distance, and end distance, then tap **Save rule**.
   For a home test you can use `demo-aisle`, `3`, and `20`. These are test values,
   not measured store positions. Choose the shelf side if known and whether the
   store carries the item; sold-out stock does not automatically disable it.
4. Tap **Scan selected product**. The camera opens with manual progress at 0,
   so a 3–20 metre rule remains armed and does not run OCR yet.
5. Set progress to 5 and tap **Apply progress / restart**. With the matching
   landmark and reliable progress, extraction and catalog matching run.
6. Try another landmark, progress above 20, unreliable progress, or Pause and tap
   Apply. The displayed gate reason should explain why recognition is disabled.
7. Return to the setup screen to edit a rule or reload the bundled catalog, then
   open a new scan. The database snapshots are refreshed on each new scan.
8. Close and relaunch the app to check that your saved rule and product selection
   identity persist. The UI does not remember the selection itself; select it again.

The match display reports `disabled`, `noMatch`, `candidate`, or `confirmed`.
The default lexical matcher needs at least 70% confidence-weighted word coverage,
a 15 percentage-point lead over other candidates, and three accepted observations
without a gap over two seconds. Its evidence score is not a probability. Real
packaging may differ from scraped titles, so device tuning and verified metadata
are still needed. The demo uses manual progress, not real phone localization.

## Test an unlabeled onion at home

1. Select **Fresh Yellow Onion - each** (TCIN `13474244`) and an available location.
2. Save a demo rule: landmark `home-test`, activate at `3`, deactivate at `20`,
   **Carried at this store** on. These are manual test inputs, not surveyed values.
3. Tap **Scan selected product**. Set passed landmark to `home-test`, metres to
   `5`, **Reliable** on and **Pause** off, then tap **Apply progress / restart**.
4. Frame one onion prominently in good lighting. No written label is needed.
   Because this product is mapped to the MVP produce taxonomy, the app uses
   image recognition (Apple Vision on device), not OCR, and shows the top labels
   collapsed to broad categories (`onion`, `potato`, `unknown`, …).
5. After three strong `onion` observations the result is `confirmed` with
   **onion confirmed (category level; variety not checked)**. For the MVP, any
   onion confirms the onion product; red/white/yellow are not distinguished.
   The same applies to apples, grapes, oranges and the other mapped produce.
6. Try a potato, garlic, an empty scene, and poor lighting; inspect the actual
   labels rather than assuming the selected target was detected. Set metres to
   `21` and Apply to verify recognition stops outside the saved window.
7. In Xcode's debug console, search for `[ItemRecognition]`. Visual diagnostics
   include class scores, `[on-device]`/`[cloud]` source, and match status;
   confirmed outputs include the stored product title, TCIN, and UUID.

No model download is needed. This is prominent-item classification, not
crowded-bin recognition. It does not infer variety, organic status, supplier,
weight, or package count.

### How the app chooses OCR or image recognition

The choice is per product, made once when the scan session starts:

- **Mapped in** `Scripts/RecognitionIntegration/Resources/visual-product-mappings.json`
  (fresh produce: onion, apple, banana, orange, lime, grape, strawberry, avocado,
  carrot, cucumber) → image recognition. Text detection and OCR never run.
- **Not mapped** (all packaged products, including cereal or snacks that show
  fruit on the box) → package crop plus OCR (below).

Both paths share one inference slot and the same activation gate and
three-observation confirmation; evidence from the two paths is never combined.
A single failed OCR frame never switches. **Three processed frames in a row with no extracted text** (the ones that say "Move closer to the item") leave OCR for Apple Vision, and Gemini still waits for its own three weak visual frames. The next confident result — the OCR words, or the object Apple Vision or Gemini names — stops the scan. The screen asks **Yes, that's it** or **No, keep looking**. Yes ends the scan. No keeps looking on the path already chosen.

### Package crop before OCR

For a packaged product the detector first looks for the package itself. Vision's
rectangle detector proposes up to three rectangles; the largest one with
confidence of at least **0.5** becomes the crop. That 0.5 only accepts the crop.
It says nothing about which product it is: the product is still confirmed from
the words (70% coverage, 15-point lead, three observations).

Text boxes inside that rectangle are unioned, padded 8%, and clipped to the
package, so a neighboring box on the shelf is left out. OCR then reads that
region of the **original** camera frame. Nothing is scaled up: if the tallest
text line inside the package is under 32 pixels, the frame is skipped and the
app waits for a closer frame, which adds real pixels. Move closer instead of
expecting a zoom. When no rectangle reaches 0.5 (a printed page in camera-only
mode, for example), every visible text box is unioned as before.

### What the screen tells the user

Two lines sit directly under the camera preview. The user cannot check the
image themselves, so the app says what it is doing and what to do next, in
plain words. No coordinates are ever shown.

**Recognition mode** (always visible; orange when the heavier model runs):

| Text on screen | When |
|---|---|
| `Using OCR to read the label` | Packaged product; text is being read on the phone |
| `Using on-device Apple Vision` | Mapped produce; Apple's classifier on the phone |
| `Using cloud assist (Gemini)` | The frame's answer came from the Gemini proxy |

The Gemini line appears only on frames whose evidence came from the cloud; the
on-device frames between the two allowed calls go back to the Apple Vision line.

**Guidance** (shown only when the latest processed frame has advice; cleared
when the item is framed well). OCR path only:

| Text on screen | When |
|---|---|
| `Move closer to the item` | Package text too small and the package covers under a quarter of the frame, or nothing readable is in view |
| `Keep walking toward the item` | The package is already large but its text is still under 32 pixels |
| `Move more to the left` | The package (or the text, with no package) sits in the left third of the frame |
| `Move more to the right` | It sits in the right third |

Left and right mean the way the user should step so the item ends up in the
middle of the phone. An off-centre package is still read on that frame; only
the "too small" cases skip OCR. Both lines are also printed in the Xcode console
as `[ItemRecognition] Mode: …` and `[ItemRecognition] Guidance: …` when they
change. `RecognitionUpdate.guidance` and `RecognitionUpdate.modeNotice` carry
the same values for ShellApp.

### Reading visual scores

For produce, the selected item's label must reach
`VisualRecognitionPolicy.appleVisionProduce.minimumScore` (currently **50%**)
and lead every other produce label by **10 points**. Background labels are
folded into `unknown` and do not compete, because Apple Vision scores each label
independently (a table and an onion can both score high). The screen and the
Xcode console always show the selected item's label, other produce labels above
0%, and the real label behind `unknown`, highest first:

```text
[ItemRecognition] noMatch | ... | Visual: unknown(table)=73%, onion=31%, potato=4% | [on-device] ...
```

Here onion leads potato by 27 points but 31% is below the 50% threshold, so the
frame does not count. The same rule applies to apple, orange, and every other
mapped item. Three passing observations in a row, each no more than 2 seconds
apart, confirm the product.

### Match confidence

`ItemRecognitionResult.matchConfidence` (0…1) answers "how closely do the
recent frames match the selected product?" independently of the status. Per
frame it is the selected label's share among produce labels (background
excluded), scaled so that reaching the threshold alone counts as full strength,
and 0 when the label is below the 10% noise floor. The value is averaged over
the last three processed frames so it does not flicker. Examples with a 30%
threshold: onion 31% / potato 4% → 0.89; onion 35% / potato 30% → 0.54; a
cereal box (onion 0–4%) → 0. A Gemini answer contributes its own confidence for
its label and 0 for any other. The demo shows it as `match N%` in the status
line and as `Match: N%` in the console line, which reprints whenever the value
crosses a 10-point step:

```text
[ItemRecognition] noMatch | Match: 55% | Item: No confirmed database match | Visual: unknown(table)=73%, onion=31%, potato=4% | ...
```

### Optional cloud assist

In the setup screen, **Cloud assist for produce** sends a downscaled crop to
`ItemRecognition/CloudProxy/` after **three consecutive processed frames** whose
on-device produce score is below the produce threshold. The camera is a video
stream and only every fifth frame is processed, so one blurry frame stays on the
phone; three weak processed frames in a row mean this look will not confirm
locally. The proxy calls Gemini and holds the Google AI Studio key; the app
stores only the proxy URL and a proxy token.

Frame counting per selected item, in processed frames:

| Processed frame | Local score | What happens |
|---|---|---|
| 1, 2 | weak | Stay on device |
| 3 | weak | First Gemini call |
| 4, 5 | weak | Stay on device |
| 6 | weak | Second and last Gemini call for this item |
| 7 onward | weak | Stay on device until the next product |

A strong frame resets the count. Cloud answers are shown as `[cloud]`, must
pass the same threshold, and count as one accepted observation each. Returning
the product still takes three accepted observations within two seconds, and the
weak on-device frames between two cloud answers reset that count, so two cloud
answers alone leave the item a **candidate** until an on-device frame also
clears the threshold. Any timeout or error falls back to the on-device result
and still uses up one of the two calls.
Run the proxy with `CLOUD_PROXY_MOCK_LABEL=onion` to test the connection
without an API key; see `ItemRecognition/CloudProxy/README.md`.

## Custom Core ML model (bounding boxes)

Training requirements, annotation rules, and the dataset validator are in
`ItemRecognition/Training/`. `CoreMLVisualClassifier` accepts either a classifier
or a Create ML object detector (pass `classLabels` for detectors that do not
publish them). Inject it as `ProduceCategoryClassifier(base:)` so the catalog
mapping stays unchanged. No custom model is bundled yet.

Visual policy values are provisional, not calibrated accuracy claims: `0.3`
score and `0.1` margin for the Apple Vision produce baseline, and the library
default of `0.8` and `0.2` for other models. Re-tune them for a custom model on
its validation split.

## What this exercises

The demo owns one `AVCaptureSession` and supplies upright BGRA pixel buffers to
`RecognitionCoordinator`. Its shared `RecognitionFrameScheduler` routes mapped
visual items to classification before text detection; the OCR path uses
`VisionLabelRegionDetector` (package rectangle, then text inside it) and
`VisionTextRecognizer`. The public
`TextExtractionScheduler` remains an OCR compatibility facade. No explicit crop
is supplied by the demo. It processes every fifth submitted active frame; capture drops incoming
frames while a submission runs rather than creating an unbounded task backlog.

In camera-only mode, a fixed 3–20 metre rule and progress of 5 metres past
`demo-aisle` activate extraction without product matching. In database mode,
`ProductDatabaseStore` owns persistence, `SwiftDataCatalogReader` loads snapshots,
and `RecognitionCoordinator` handles activation, extraction, matching, and temporal
confirmation. No database query runs for each camera frame. ShellApp remains a
separate browser demo and its local database is not shared with this app.

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
