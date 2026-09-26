# Persistent Project Memory — Item Detection, Visual Classification, OCR, and SwiftData Matching

## Implementation status — verified September 26, 2026

This checklist records the current local implementation. Checked items are complete within the scope stated. The architecture and examples below also describe planned work; they are not evidence that the entire recognition pipeline is complete.

### Complete

- [x] Create the native Swift `ItemRecognition` library package with iOS 17+ and macOS 14+ support and an XCTest target.
- [x] Define immutable catalog snapshots and the `CatalogReading` protocol, with a concrete SwiftData snapshot adapter in `Scripts/RecognitionIntegration/`.
- [x] Implement `ActivationGate` using supplied target, landmark, progress, reliability, and external-pause context.
- [x] Implement waiting, armed, active, suspended, threshold-passed, and item-not-in-store decisions with typed inactive reasons.
- [x] Activate within the inclusive distance window: `activateAfterMeters <= progress <= deactivateAfterMeters`. Progress strictly greater than the end threshold turns detection off.
- [x] Load and cache activation rules through `CatalogReading`, reset on target changes, and retry loading when a rule is missing.
- [x] Emit `clearTemporalCandidates` and consume it in `RecognitionCoordinator` to invalidate queued work and temporal evidence, including context changes without camera frames.
- [x] Define `RecognitionImage` with a supplied pixel buffer, timestamp, resolution, orientation, and documented buffer ownership requirements. No camera session is created here.
- [x] Validate declared image dimensions and caller-supplied crop bounds before gate evaluation.
- [x] Convert between original-buffer top-left pixel crops and oriented, normalized lower-left Vision regions, with independently specified coordinate tests for all eight ImageIO orientations.
- [x] Implement `VisionTextRecognizer` with `VNRecognizeTextRequest`, accurate recognition, `en-US`, language correction, and explicit image orientation. Real-image and physical-device validation remain pending.
- [x] Implement deterministic text normalization and word/adjacent-word tokenization, including case, whitespace, punctuation, Unicode normalization, and unit formatting.
- [x] Implement `TextExtractionScheduler`: default stride of five active frames, configurable within 5–10, one in-flight request, and one replaceable pending eligible frame.
- [x] Suppress new OCR work while inactive and discard an in-flight observation if the gate is inactive or its target differs at completion.
- [x] Return `ProductTextObservation` with raw and normalized text, confidence, bounding boxes, timestamp, target identifier, and optional shelf side.
- [x] Latest verification (September 26, 2026, after the MVP taxonomy and cloud-assist changes) passed **101 recognition tests** (after the background-margin and threshold change), **16 database integration tests**, **5 cloud-proxy tests**, the unsigned generic-iPhone demo build, a Swift-client-to-mock-proxy round trip, and the training validator on synthetic good/bad datasets. No physical-iPhone accuracy or thermal evaluation has been performed. The Gemini request format was accepted by the live endpoint (checked with an invalid key, which it rejected only for the key), but no labeled Gemini answer has been received yet because no Google AI Studio key is configured.
- [x] Implement automatic label/text-region detection when upstream does not provide a crop, with validated image-coordinate mapping. `VisionLabelRegionDetector` uses `VNDetectTextRectanglesRequest`, unions visible text boxes, adds an 8% margin per edge, and clips to image bounds. This is a text-bearing-region MVP, not a package-outline or SKU classifier.
- [x] Integrate detection and OCR in the same bounded scheduler slot. Supplied crops bypass detection; no detected region skips OCR. Pause/target-change generations prevent obsolete work from reaching OCR or returning observations after reactivation.
- [x] Add a barebones standalone physical-iPhone app in `ItemRecognitionDemo/`, with rear-camera preview, Start/Stop, raw/normalized text, OCR confidence, and processing time. It uses the local package's real automatic detector and OCR with a demo-only active context. The unsigned Debug build for `generic/platform=iOS` succeeded with Xcode 27.0; signed installation and camera behavior on an actual phone remain to be verified.
- [x] Integrate the database owner's concrete SwiftData `CatalogReading` adapter and preload the relevant catalog candidate snapshots.
- [x] Keep product names and persistence in the database layer. Existing `Product` and `StoreLocation` schemas are unchanged; database-owned additive tables store recognition UUIDs, per-location activation settings, and import state. Imports preserve IDs, missing titles, and existing locations. The demo uses one store without store identifiers.
- [x] Implement conservative catalog matching and conflict rejection against the preloaded aisle candidates, plus configurable temporal confirmation. Default policy requires score ≥ 0.70, lead ≥ 0.15, and three observations with gaps ≤ two seconds. Scores are evidence coverage, not calibrated probabilities; physical accuracy remains unverified.
- [x] Implement `RecognitionCoordinator`, `ItemRecognitionResult`, and confirmed `ItemObservation` output. `stop()` ends a session; new targets, imports, locations, or rule edits require a fresh snapshot/coordinator.
- [x] Add product/location selection, persisted rule editing, and manual progress controls to `ItemRecognitionDemo`. ShellApp remains an independent demo; neither UI owns the catalog contract. Preserve camera-only mode for isolated extraction checks.

### Database integration decisions

The database and bridge are local library targets in `Scripts/Package.swift`; no recognition implementation imports SwiftData. `ProductDatabaseStore` confines model access to its model actor, and `SwiftDataCatalogReader` is an immutable session snapshot. No title/ID persistence lives in activation. Rules use explicit product and location selection and are never inferred from an aisle label or stock count. Location data in partial captures is merged, not used to retire old locations. A tested additive schema upgrade preserves an existing Product/StoreLocation store. Detailed ownership, behavior, test commands, limitations, and future database work are in `Scripts/INTEGRATION.md`.

Scheduler unit tests use fake recognizers and detectors. Coordinate and detector-policy tests validate geometry and region selection without invoking real Vision inference. The synthetic image fixtures, generator, and real-Vision integration suite were removed at the user's request. This checklist describes the local working tree rather than a committed release.

### Current automatic-detection behavior

1. Validate the supplied image and any explicit crop, evaluate activation, and apply the existing 5–10-frame cadence.
2. Use an explicit crop unchanged when supplied. Otherwise run `VisionLabelRegionDetector` on this same frame with its orientation metadata.
3. Combine detected text boxes into one padded region. Convert it back to original-resolution stored-buffer pixel coordinates. No region returns `nil` from the scheduler without OCR.
4. Convert that crop to the oriented Vision ROI and run OCR on the original pixel buffer. No resized image or box from another frame is substituted.
5. Return the selected pixel crop in `ProductTextObservation.boundingBox`. Individual candidate boxes remain normalized lower-left coordinates relative to the whole oriented image.

Several visible labels may be combined into one region. Isolating individual packages in a crowded shelf and identifying a catalog product are not provided by this detector. Camera ownership, SwiftData schema, localization, and catalog matching remain with their existing boundaries.

### Pending — required to complete product recognition


- [ ] Tune the lexical matcher against real packaging and verified brand/alias metadata; validate neighboring variants, sizes, and multi-label scenes on the intended device.
- [ ] Add explicit location retirement/reconciliation and multi-store inventory only if needed, with the database owner. Existing stored locations are preserved on partial captures.
- [ ] Integrate the main iOS application with the real upstream camera and localization inputs. The standalone demo uses its own camera session and simulated activation inputs, not the navigation application's integration.
- [ ] Connect optional result recording through the database owner's adapter if persistence is required.
- [ ] Run end-to-end tests on the intended iPhone and record accuracy, wrong-variant acceptance, latency, memory, thermal behavior, and agreed acceptance thresholds.

### Visual classification for unlabeled items — implementation and remaining validation

Requested and implemented as a first native visual path September 26, 2026. **The pipeline and Apple Vision baseline are implemented; a custom produce model, exact-SKU accuracy validation, and physical-device evaluation remain pending.** This explicitly extends the text-recognition scope below. All existing platform and ownership constraints still apply. Earlier OCR-only flow descriptions describe that sibling path, not the only available recognition mode.

Implementation uses Apple's built-in `VNClassifyImageRequest` revision 2 immediately, plus an injectable `CoreMLVisualClassifier` for a future validated custom model. All mapped produce goes through `ProduceCategoryClassifier` (`mvp.produce.categories.v1`), which collapses model labels into the broad taxonomy in `Resources/produce-taxonomy.json`. Every taxonomy alias was checked against the installed Vision vocabulary. No shared database schema change or second camera session was added.

#### MVP decisions — September 26, 2026 (user direction; supersedes earlier "category-only, no cloud" rules)

1. **Broad labels only.** Onion is `onion`: yellow, red, white, and sweet are not differentiated. The same applies to every fruit and vegetable (all apple varieties are `apple`, and so on). Variety, organic status, size, and brand are never classes.
2. **Category-level confirmation.** A mapping on the MVP taxonomy model with `allowsConfirmation: true` confirms the selected product when three observations pass the policy. The result reason is `acceptedCategory` ("variety not checked"), and neighbors sharing the label do not block it. Raw `apple.vision.classify-image` mappings still cannot confirm, and SKU-level custom models keep the `accepted`/`ambiguousCatalog` rules.
3. **Choosing OCR or image recognition.** The choice is made per product at session setup: a product mapped in `visual-product-mappings.json` uses image recognition, and everything else uses label detection plus OCR. 27 fresh-produce products are mapped. Packaged items with produce imagery (cereal, snacks, oatmeal) stay on OCR. Evidence from the two paths is never combined.
4. **Cloud assist (approved, optional).** When the best on-device produce score is below `CloudAssistPolicy.localScoreBelow` (library default 0.8; the demo sets it to the Apple Vision produce threshold, 0.3), `ProduceCategoryClassifier` sends one upright crop (at most 512 px on the long side) through `HTTPCloudProduceLabeler` to `ItemRecognition/CloudProxy/server.py`. The cloud provider is **Google Gemini** (user decision, replacing OpenAI). The proxy holds the Google AI Studio key in `GEMINI_API_KEY` and sends one `generateContent` request with the JPEG as `inline_data`, `responseMimeType: application/json`, and a `responseJsonSchema` whose label enum is the taxonomy. The default model is `gemini-3.1-flash-lite`, overridable with `GEMINI_MODEL`. Safety blocks map to `unknown`. No provider key is stored in the app. Cloud answers carry `kind: .cloudSuggestion`, share the local model-version string so switching source does not reset confirmation, pass the same threshold and three-observation rule, and fall back to the on-device result on any error, invalid label, or the 200-request session cap. The scheduler's single slot serializes requests. Answers slower than the 2-second confirmation gap cannot chain into a confirmation.
5. **Training uses bounding boxes.** The custom model will be a Create ML Object Detector trained on the same broad labels. `CoreMLVisualClassifier` accepts detector output and collapses boxes to the best score per label. The model plugs in as `ProduceCategoryClassifier(base:)`, so mappings do not change. Requirements, annotation rules, and the validator are in `ItemRecognition/Training/`.
6. **Background does not compete; lower Apple Vision threshold (September 26, 2026, after first iPhone test).** On-device, onion scored 29–31% while the folded `unknown` bucket (e.g. "table") scored 73%, so every frame was `noMatch`. Because `VNClassifyImageRequest` scores labels independently, for the MVP taxonomy model `VisualCatalogMatcher` now compares the selected item's label (onion, apple, orange, …, whichever the product maps to) only against other produce labels; `unknown` is ignored. Other models (custom detectors) still treat every non-target label, including `unknown`, as competition. The demo uses `VisualRecognitionPolicy.appleVisionProduce` (0.3 score, 0.1 margin over the best other produce label, three observations) for MVP mappings; the library default stays 0.8/0.2 for custom models. Both values are provisional until step 8. `VisualObservation.backgroundLabel` keeps the raw label behind `unknown`, and the demo log/screen always list the selected item's score, other produce labels above 0% (top three), and `unknown(<label>)`, sorted by score, e.g. `unknown(table)=73%, onion=31%, potato=4%`.

#### Intended first outcome

Point the iPhone demo camera at one prominently framed, unlabeled onion of any color. The pipeline recognizes `onion` and confirms the database's `Fresh Yellow Onion - each` record (TCIN `13474244`) at category level, at a selected location (currently G10 or G13, floor 01). The adapter resolves the current persisted recognition UUID. Neither the model nor activation owns product names or generates product IDs.

Category confirmation means "an onion is in view while searching for the onion product." It does not establish variety, organic status, supplier, price, weight, or package count. The first version assumes one prominent item; crowded-bin localization, multiple-object tracking, and instance counting are later work.

#### Stack and ownership

- Keep iOS 17+, macOS 14+, native Swift, actors, async/await, immutable Sendable values, and XCTest.
- Use the installed Apple Vision image classifier for the initial category demo; execute an injected custom Core ML classifier through `VNCoreMLRequest` when a validated artifact is supplied; supply the existing Core Video pixel buffer and ImageIO orientation. Keep inference off the main actor and keep the model resident for the session.
- Use Apple's Create ML app on the development Mac to train/export the model (Object Detector, bounding boxes). Do not add Python ML libraries. The only cloud or LLM use is the optional, off-by-default cloud assist through the server-side proxy described in the MVP decisions above. The on-device path must keep working without it.
- Preserve the existing camera owner, activation gate, localization boundary, and SwiftData gateway. Do not create another camera session, implement landmark recognition, change shared SwiftData models/migrations, or add per-frame database access.
- Keep product-image URLs, purchase URLs, prices, and inventory fields out of inference snapshots. The model consumes camera pixels; catalog linking consumes IDs and explicit visual-class metadata.

#### Implementation sequence — completed pipeline and pending model validation

1. [x] **Define initial catalog eligibility.** `Scripts/RecognitionIntegration/Resources/visual-product-mappings.json` maps 27 fresh-produce TCINs (including onion `13474244`) to broad classes of `mvp.produce.categories.v1`, with category-level confirmation enabled. Mapping presence selects visual mode; unmapped products retain OCR. `VisualProductMappings` validates version, duplicate TCINs, and empty labels, and still prohibits confirmation with the raw Vision model ID. The adapter joins mappings only to actual preloaded catalog records, preserving their existing UUIDs/titles. No title substring guesses are used. Durable editable metadata remains database-owner work.

2. [ ] **Train and validate the actual model.** Requirements are defined in `ItemRecognition/Training/README.md`: Create ML Object Detector, broad taxonomy labels, bounding-box rules, capture counts (≥100 train images and ≥10 specimens per required class for a first run), hard negatives, a specimen/session split, a Create ML JSON format, and proposed acceptance thresholds. `validate_annotations.swift` enforces labels, box geometry, orientation, and split leakage. **Photo capture, labeling, training, and evaluation have not started.** Record each trained model in `Training/models/` using `model-card-template.md`.

3. [x] **Add immutable visual contracts.** `Visual/VisualClassifying.swift` contains the classifier protocol, model information, observations, eligibility metadata, policy, and typed errors. `CatalogItemSnapshot` carries optional visual metadata. Results carry explicit visual evidence/source and preserve empty OCR text for visual-only observations. Input regions describe the classified pixels, not detected object boxes.

4. [x] **Implement Vision/Core ML execution.** `VisionImageClassifier.swift` provides the installed Apple classifier; `CoreMLVisualClassifier.swift` accepts a compiled custom model and explicit preprocessing. Models/requests stay resident on an actor. Both use the supplied pixel buffer, orientation, and validated optional crop; neither requires text detection. Model compatibility, class vocabulary, scores, and observation metadata are validated. Custom model training/bundling is pending in step 2.

5. [x] **Share the bounded inference budget.** Extract the current cadence/slot/generation mechanics into `Extraction/RecognitionFrameScheduler.swift`, preserving the OCR behavior through `TextExtractionScheduler`. One scheduler owns both modes: every fifth to tenth active frame, at most one in-flight job and one replaceable pending eligible frame. Route using the target's explicit mode before text detection. Distinguish skipped frames from completed empty evidence and errors. Check activation and generation before and after inference; reset evidence on stop, pause, target/context changes, or model/catalog revision changes. Do not run independent OCR and visual queues or apply cadence twice.

6. [x] **Implement visual-to-catalog matching (policy calibration pending).** Add `Catalog/VisualCatalogMatcher.swift`. Evaluate the classifier's full competing-class scores before narrowing to the preloaded target/neighborhood; do not discard a potato prediction because only an onion is being searched for. Then apply the explicit catalog mapping and ambiguity checks. Expose a separate configurable visual policy and require repeated evidence; defaults are provisional until step 8 validates model-specific score/margin thresholds; the existing OCR coverage threshold is not a visual probability threshold. Start temporal testing with the existing three-observation/two-second-gap policy, but tune it on device. Do not sum OCR and visual scores or alternate weak evidence across modes to reach confirmation. For ambiguous identity, return the class evidence without a matched UUID; for approved unique matches, return the database's UUID. Inference failures reset confirmation evidence. Selecting an onion target is not evidence that the image contains an onion.

7. [x] **Integrate the existing coordinator and barebones demo.** Update `RecognitionCoordinator` and `RecognitionUpdate` to carry either OCR or visual observations through the same gate and confirmation lifecycle. Update `ItemObservation` so visual evidence is explicit and does not masquerade as extracted words; preserve supplied side metadata independently of OCR. Extend `SwiftDataCatalogReader` to join reviewed visual metadata while creating the immutable session snapshot. In `ItemRecognitionDemo`, display/print evidence source, visual class, model score, candidate/confirmed status, and the matched database title/TCIN/UUID only on confirmation. Keep ShellApp independent. Use the existing manual landmark progress for home testing; real localization will later supply the same context without changing the classifier.

8. [ ] **Complete real-produce and physical-device evaluation.** Automated contract, lifecycle, mapping, and real-Vision smoke tests pass; the held-out real-produce dataset, model calibration, and physical-iPhone measurements below remain pending. Use fake classifiers to verify inactive-gate suppression, missing-model failures, unknown/unmapped classes, lookalike rejection, duplicate/out-of-order timestamps, expiry, ambiguous catalog identities, and pause-during-inference invalidation. Test mapping to TCIN `13474244` and its persisted UUID, including restart/reimport stability. Add real visual-model image tests with held-out produce and explicit orientation/crop cases; this new scope does not restore the previously removed real-OCR fixture suite. Re-run OCR regressions after extracting shared scheduling. On the intended iPhone, measure class precision/recall, false confirmed product matches, time to confirmation, inference latency, memory, and thermal behavior. Report sample counts and failure cases; agree numerical acceptance thresholds before marking complete.

9. [ ] **Complete the physical home demonstration.** Select the existing onion product and location, save an explicit demo activation rule, and supply matching manual progress inside its window. Show a real unlabeled onion and verify visual evidence and the correct persisted catalog identity. Repeat with confusing produce, no item, bad lighting, and a closed gate. Reopen the app to verify identity stability. Mark this section complete only after the model, mapping, automated checks, and physical-device results are all available; record limitations for exact-SKU recognition and multi-item scenes.

#### Files and responsibilities

| Area | Files/resources | Change |
|---|---|---|
| Classifier contracts and inference | `ItemRecognition/Sources/ItemRecognition/Visual/` (new) | Immutable observations, injected classifier, model-specific policy, Vision/Core ML execution. |
| Scheduling and orchestration | `Extraction/RecognitionFrameScheduler.swift` (new), `TextExtractionScheduler.swift`, `RecognitionCoordinator.swift` | Shared inference slot/cadence and mode routing without changing activation ownership. |
| Catalog matching and output | `Catalog/VisualCatalogMatcher.swift` (new), `CatalogReading.swift`, `ItemRecognitionResult.swift` | Explicit visual metadata, ambiguity handling, evidence source, and confirmed database identity. |
| Database integration | `Scripts/RecognitionIntegration/SwiftDataCatalogReader.swift`, `Resources/visual-product-mappings.json` (new), `Scripts/Package.swift` | Load/validate mapping resources at session setup; no shared model/schema changes. |
| Training requirements and dataset validation | `ItemRecognition/Training/` | Bounding-box rules, capture/split requirements, Create ML steps, validator, and model-card template. No dataset or model is committed. |
| Cloud assist | `Visual/CloudProduceLabeling.swift`, `Visual/ProduceCategoryClassifier.swift`, `ItemRecognition/CloudProxy/` | Weak-local fallback, HTTP client, JPEG crop encoder, and a Python standard-library proxy holding the Gemini (Google AI Studio) key. |
| Custom model artifact and provenance (pending) | demo Xcode project (future) | No custom artifact is bundled. Supply a validated model with its model card. |
| Demo | `CatalogDemoView.swift`, `DemoScanConfiguration.swift`, `CameraDemoView.swift`, `Info.plist` | Construct `ProduceCategoryClassifier` (with optional cloud assist settings), display `[on-device]`/`[cloud]` evidence, and allow local-network HTTP to the proxy. |
| Verification | `ItemRecognition/Tests/ItemRecognitionTests/`, `Scripts/Tests/` | Visual contract/inference tests, adapter tests, OCR regression, and recorded device checks. |

Apple references: [VNClassifyImageRequest](https://developer.apple.com/documentation/vision/vnclassifyimagerequest) supplies the built-in category classifier. [Vision and Core ML image classification](https://developer.apple.com/documentation/coreml/classifying-images-with-vision-and-core-ml) describes model reuse, preprocessing, orientation, and classification output. [Creating an image classifier](https://developer.apple.com/documentation/createml/creating-an-image-classifier-model) describes the Apple-native training/evaluation workflow. [VNCoreMLRequest](https://developer.apple.com/documentation/vision/vncoremlrequest) documents model-dependent output and score semantics; thresholds must respect the chosen model rather than assume calibrated probabilities.

### Test the completed work in Xcode

1. Open `ItemRecognition/Package.swift` in Xcode.
2. Select the `ItemRecognition` package scheme and **My Mac** destination to reproduce the verified platform.
3. Choose **Product > Test** (`Command-U`). Review the suites in the Test navigator; the recognition package now contains 101 tests, including visual-path and `CloudAssistTests` checks. Run `python3 -m unittest test_server` in `ItemRecognition/CloudProxy/` for the proxy. Open `Scripts/Package.swift` to run the database integration suite.
4. Run individual `ActivationGateTests` with a breakpoint in `ActivationGate.evaluate` to inspect the state and inactive reason. The fixture uses `aisle_25_top` and an inclusive 3–20 metre window.
5. Run `testFirstFourFramesSkipAndFifthRunsOCR` in `TextExtractionSchedulerTests` and inspect the unwrapped observation. The fake recognizer supplies `Honey Nut CHEERIOS` and `12 OZ`, which normalize to `honey nut cheerios` and `12oz`.
6. Run `testPauseDiscardsPendingFrameAndInFlightResult` and `testResumeAfterPauseRequiresFreshStride` to inspect pause/resume behavior.
7. Run `VisionRegionOfInterestTests` and `VisionLabelRegionDetectorTests` for coordinate mapping and detector-policy checks. Run `testPauseAndResumeDuringDetectionDiscardOldFrameBeforeOCR` for interruption behavior. These are unit tests, not real-image Vision integration tests.

For live camera testing, open `ItemRecognitionDemo/ItemRecognitionDemo.xcodeproj`, select your signing team and connected physical iPhone, then run with Command-R. Choose camera-only mode for the original test, or select a database product/location, save a rule, and open a scan. Database-mode progress starts at zero; change it and tap Apply to test the gate. Rules and names persist in the database; progress is a manual development input. Setup details are in `ItemRecognitionDemo/README.md`. The demo owns one camera session; the recognition library consumes supplied frames and owns none.

## Purpose

This document is the durable architectural memory for implementing grocery-item text recognition, unlabeled-item visual classification, and SwiftData catalog matching in the Target-Navigation iOS application. Future design and implementation work should preserve the decisions below unless the user explicitly changes them.

This branch receives image input and recognition context from other parts of the application. It uses Apple Vision OCR, optional Core ML element/label-region detection, and a narrow SwiftData catalog gateway. It does not implement user localization, database registration, or bracelet sensors.

## Branch ownership and coordination boundary

This scope is intentionally narrow.

### Work owned by this branch

- Accept a provided camera image or detected-element crop through a Swift interface.
- Detect a product package, label, or text-bearing element when a crop is not already supplied.
- Extract text from that element with Apple Vision OCR.
- Classify a prominently framed unlabeled item with Apple Vision or an injected Core ML classifier, using explicit catalog eligibility and conservative identity matching.
- Normalize the extracted text.
- Read product records through the SwiftData catalog interface supplied by the database branch.
- Load the target item's aisle-landmark activation rule and detection threshold from the SwiftData adapter.
- Implement the detection activation gate that arms after the supplied aisle landmark is passed and activates after the configured threshold is crossed.
- Compare OCR text with the relevant catalog records.
- Return an immutable recognition result to the caller.
- Unit-test text normalization, catalog matching, and recognition result handling.

### Work explicitly excluded from this branch

- **Do not add, replace, or modify user localization.** Localization and `FusionActor` work are currently being developed on another branch.
- **Do not implement graph construction, edge snapping, drift correction, Dijkstra, Held–Karp, route recovery, or position estimation.** These may provide inputs to this feature later, but they are not implementation tasks here.
- **Do not create or redesign SwiftData object-registration workflows.** Another contributor/branch owns registration of detected objects and the SwiftData database schema.
- **Do not add SwiftData migrations or change shared `@Model` types without coordination with the database owner.** This branch consumes the agreed database interface.
- **Do not implement bracelet sensors, bracelet communication, or bracelet feedback.** Sensor integration for the bracelets is being developed on another branch.
- **Do not create a second camera session.** Image ownership belongs to the upstream camera/navigation integration.
- **Do not implement obstacle avoidance, navigation guidance, or watch/bracelet haptics.** An upstream state may pause recognition; this feature only honors that input.

### Integration ownership summary

| Area | Owner | This branch's responsibility |
|---|---|---|
| User localization and position estimation | Separate localization branch | Accept landmark-passage/progress observations; do not calculate position or decide that a landmark was passed. |
| SwiftData schema and object registration | Separate database branch/contributor | Read catalog and activation-rule snapshots through an agreed protocol; return match results through an agreed protocol. |
| Bracelet sensors and feedback | Separate sensor branch | No implementation; return recognition results that another layer may translate into feedback. |
| Landmark-threshold activation, product element detection, OCR, and text matching | **This branch** | Compare supplied landmark progress with the configured threshold, then detect/crop, extract text, normalize, compare, score, and return results. |

## Explicit tools and frameworks in use

Use only iOS-friendly Swift tooling and Apple-native interfaces unless the project explicitly approves another dependency:

- **Xcode** — project editing, building, signing, Instruments, and test execution.
- **Swift** — all production interfaces and implementation.
- **Swift concurrency** — `actor`, `async`/`await`, `Task`, and immutable `Sendable` value types.
- **SwiftData** — read access to registered catalog objects through the database branch's schema and gateway.
- **Apple Vision** — `VNRecognizeTextRequest` for OCR, `VNClassifyImageRequest` for the built-in visual-category baseline, and `VNCoreMLRequest` for injected Core ML inference.
- **Core ML** — on-device model execution for product/label-region detection when needed, and injected custom visual classifiers or Create ML object detectors. No custom produce model is currently bundled.
- **Optional cloud assist** — `URLSession` to the development proxy in `ItemRecognition/CloudProxy/` (Python standard library, Gemini API `generateContent`). Off by default; never on the OCR path.
- **Core Video** — `CVPixelBuffer` image input supplied by the upstream camera owner.
- **Core Graphics / ImageIO** — crop geometry and explicit image orientation metadata.
- **Foundation** — identifiers, strings, normalization, timestamps, and collection types.
- **XCTest** — unit and integration tests for OCR normalization, matching, and SwiftData gateway behavior.
- **Xcode Instruments** — latency, memory, and thermal profiling of the recognition path.

ARKit, route planning, WatchConnectivity, and bracelet APIs are **not tools owned or implemented by this branch**. If their types appear at an integration boundary, adapt them to the small Swift contracts defined here rather than importing their internal architecture into this feature.

## Non-negotiable platform constraints

- Application code and interfaces must be native iOS Swift.
- Persistence integration must use the SwiftData interface owned by the database branch.
- Camera ownership remains upstream; this branch consumes a supplied `CVPixelBuffer` or already-created crop rather than opening a capture session.
- Use Apple frameworks where practical: Vision, Core ML, SwiftData, Core Video, Foundation, and Swift concurrency.
- SwiftData models are persistence objects, not hot-path actor messages.
- Values crossing actors must be immutable `Sendable` Swift structs.
- Do not read or write SwiftData for every camera frame.
- Person/cart safety detection is not implemented here; upstream code may disable recognition while safety work has priority.

## Upstream integration contract

Localization, routing, obstacle handling, and item placement exist outside this feature. Upstream localization reports which landmark was passed and progress after that landmark. This branch owns the small activation gate that compares that supplied progress with the target item's SwiftData-derived threshold. Do not import or recreate the upstream graph, route, or localization internals.

## End-to-end recognition flow owned by this branch

```text
Upstream feature supplies:
- target item identifier
- passed aisle-landmark identifier
- measured progress after the landmark
- progress reliability and external pause state
- expected shelf side, when available
        ↓
ActivationGate loads the target's SwiftData activation rule
        ↓
matching landmark passed?
        ↓ yes
configured distance threshold crossed?
        ↓ yes
item detection becomes active
        ↓
RecognitionCoordinator receives a supplied image
        ↓
Core ML/Vision finds a product package or label region
        ↓
Crop the original-resolution captured image
        ↓
Vision OCR extracts candidate text
        ↓
Normalize text and compare it with the in-memory catalog
        ↓
Temporal confirmation across observations
        ↓
Emit ItemObservation
        ↓
Return ItemRecognitionResult to the caller
        ↓
Database/navigation/sensor branches decide how to persist or present it
```

## Aisle-landmark detection threshold

The item detector must remain off until the shopper passes the configured aisle landmark and then crosses the configured activation threshold. This activation gate belongs to this branch; determining the shopper's position and declaring that a landmark was passed do not.

The database adapter supplies an activation rule for the selected target:

```text
target item: cereal
trigger landmark: aisle_25_top
activate after: 3.0 metres past the landmark
deactivate after: 20.0 metres past the landmark
expected side: left
```

The localization branch supplies observations such as:

```text
passed landmark: aisle_25_top
progress past landmark: 2.4 metres
progress reliable: true
```

`ActivationGate` compares those values. It does not derive them from ARKit, camera poses, graph edges, or sensor data.

Activation rules:

1. A new target resets the gate and clears old temporal OCR candidates.
2. A landmark with an ID different from the target rule does not arm detection.
3. Passing the matching aisle landmark arms the gate.
4. Detection activates when reliable progress is greater than or equal to `activateAfterMeters`.
5. Detection remains active until `deactivateAfterMeters`, target completion, target change, or an external pause.
6. An obstacle, degraded upstream confidence, or safety pause suspends detection without pretending the item was passed.
7. Re-entering the valid threshold window may resume detection, but stale OCR candidates must not survive the suspension.
8. If the activation rule or landmark progress is missing, detection stays off and returns a typed inactive reason.

The initial threshold may match the current project value, but it must be stored/configured per item or shelf zone rather than hard-coded into the detector. The survey and localization owners determine the actual landmark and measured offsets.

## Navigation and obstacle interaction — external signal only

Obstacle and route handling belong to other branches. This feature only honors an upstream pause through `RecognitionContext.externalPause`, suspends the activation gate, cancels or allows the current bounded request to finish according to coordinator policy, and emits no new confirmed match while suspended.

## SwiftData integration contract

Another contributor owns the SwiftData schema and registration of detected/catalog objects. This document intentionally does **not** define replacement `@Model` classes. The database branch must provide an adapter that maps its real SwiftData entities into the immutable recognition snapshots below.

```swift
import Foundation

enum ShelfSide: String, Codable, Sendable {
    case left
    case right
}
```

The database adapter may use `@ModelActor` internally, but that implementation belongs to the database branch. Recognition code depends only on `CatalogReading` and immutable snapshots.

## In-memory snapshots

Load SwiftData catalog records through the supplied adapter into immutable snapshots. Detection and matching use these snapshots only. This is demo, not production code. This is a moch database, not a real one. do not use this code as a guide for production code.

```swift
struct CatalogItemSnapshot: Sendable, Hashable {
    let id: UUID
    let catalogKey: String
    let displayName: String
    let brand: String?
    let normalizedTerms: Set<String>
}

struct DetectionActivationRuleSnapshot: Sendable, Hashable {
    let targetItemID: UUID
    let edgeID: String
    let alongStartMeters: Double
    let alongEndMeters: Double 
    let side: ShelfSide? // add comment here that refers to block for redsky
}

struct ProductSearchTarget: Sendable, Hashable {
    let item: CatalogItemSnapshot
    let activationRule: DetectionActivationRuleSnapshot
}
```

## Actor boundary

Recommended responsibilities:

```swift
actor DetectionActor {
    // Locates text-bearing product elements and runs bounded OCR work.
}

actor CatalogMatcher {
    // Normalizes OCR text, scores candidates, and confirms the target identity.
}

actor ActivationGate {
    // Arms on the configured aisle landmark and activates item detection only
    // after supplied progress crosses the configured threshold.
}

actor RecognitionCoordinator {
    // Accepts upstream landmark progress and images, coordinates activation,
    // detection, and matching, then returns ItemRecognitionResult.
}
```

`FusionActor`, localization, navigation, database registration, and bracelet actors are external collaborators—not actors to implement in this branch.

`DetectionActor` must receive a coherent image context. Never combine boxes detected from one image with metadata from a later image.

```swift
import CoreVideo
import Foundation
import ImageIO

struct RecognitionImage: @unchecked Sendable {
    let timestamp: TimeInterval
    let pixelBuffer: CVPixelBuffer
    let imageResolution: CGSize
    let orientation: CGImagePropertyOrientation
}
```

`CVPixelBuffer` requires careful isolation. The implementation must either keep it inside the owning actor for its full lifetime or copy the data needed by another actor. `@unchecked Sendable` is acceptable only with a documented ownership rule and no concurrent mutation.

## External recognition interface

// one measurement about your position relative to a landmark.


```swift
struct LandmarkProgressObservation: Sendable, Equatable {
    let timestamp: TimeInterval
    let passedLandmarkID: String?
    let metersPastLandmark: Double?
    let isReliable: Bool
}
// all the information the recognition/detection system needs to make a decision
struct RecognitionContext: Sendable, Equatable {
    let targetItemID: UUID
    let landmarkProgress: LandmarkProgressObservation
    let externalPause: Bool
}
// is the dectition gate activated 
enum DetectionGateState: Sendable, Equatable {
    case waitingForLandmark
    case armed
    case active
    case suspended
    case thresholdPassed
}

struct ItemRecognitionResult: Sendable, Equatable {
    let timestamp: TimeInterval
    let targetItemID: UUID
    let matchedItemID: UUID?
    let normalizedObservedText: Set<String>
    let score: Float
    let status: Status

    enum Status: Sendable, Equatable {
        case confirmed
        case candidate
        case noMatch
        case disabled
    }
}

protocol CatalogReading: Sendable {
    func catalogCandidates(for targetItemID: UUID) async throws
        -> [CatalogItemSnapshot]

    func activationRule(for targetItemID: UUID) async throws
        -> DetectionActivationRuleSnapshot?
}

protocol RecognitionResultRecording: Sendable {
    func record(_ result: ItemRecognitionResult) async throws
}
```

The database branch supplies concrete implementations of `CatalogReading` and, if persistence of recognition results is wanted, `RecognitionResultRecording`. This branch must not depend directly on that branch's `ModelContext` outside its adapter. The localization branch supplies `LandmarkProgressObservation`; this branch must not calculate it.

## Vision and Core ML pipeline

Use Vision requests around a Core ML model rather than manual image orientation and crop math when possible.

1. Receive `RecognitionContext` from the upstream integration.
2. Load the target's `DetectionActivationRuleSnapshot` through `CatalogReading`.
3. Update `ActivationGate` with the supplied landmark and progress observation.
4. If the gate is not `.active`, do not schedule product detection or OCR.
5. When active, receive a `RecognitionImage` from the upstream camera integration.
6. Apply the correct `CGImagePropertyOrientation` for the mounted device and current interface/camera orientation.
7. Optionally restrict processing to the activation rule's expected shelf side when validated against real camera geometry.
8. Run the product/package/label-region detector.
9. Convert the detected normalized rectangle back to the original captured-image coordinate system, accounting for Vision crop-and-scale behavior.
10. Expand the crop slightly so brand and variant text are not cut off.
11. Run `VNRecognizeTextRequest` on the crop.
12. Send recognized strings and confidences to `CatalogMatcher`.
13. Confirm a match across time before emitting a final observation.

The first model does not have to classify every SKU. For the MVP, it may detect a general package or label region. OCR and catalog matching then establish the product identity.

## OCR result contract

```swift
import CoreGraphics
import Foundation

struct RecognizedTextCandidate: Sendable, Hashable {
    let rawText: String
    let normalizedText: String
    let confidence: Float
}

struct ProductTextObservation: Sendable {
    let timestamp: TimeInterval
    let targetItemID: UUID
    let boundingBox: CGRect
    let candidates: [RecognizedTextCandidate]
    let side: ShelfSide
}

struct ItemObservation: Sendable {
    let timestamp: TimeInterval
    let itemID: UUID
    let matchConfidence: Float
    let observedTerms: Set<String>
    let bearingRadians: Float?
    let depthMeters: Float?
    let side: ShelfSide
}
```

`ItemObservation` is distinct from:

- `ProximityEvent`, which represents a person/cart safety condition.
- `CorrectionObservation`, which provides localization evidence such as a surveyed sign.

Product text is not automatically a localization correction.

## Text normalization

Normalize both database terms and OCR output with the same deterministic pipeline:

1. Unicode canonical normalization.
2. Locale-stable case folding.
3. Remove punctuation that is not meaningful to a product name.
4. Collapse repeated whitespace.
5. Normalize common unit formatting, such as `12 OZ` and `12OZ`.
6. Preserve meaningful numbers and variant terms.
7. Tokenize into words and useful multiword phrases.

Do not use unrestricted fuzzy matching across the entire catalog. Candidate selection should be constrained by the current target and, when useful, a small set of nearby shelf items.

```swift
protocol TextNormalizing: Sendable {
    func normalize(_ text: String) -> String
    func tokens(from text: String) -> Set<String>
}

struct CatalogMatch: Sendable, Equatable {
    let itemID: UUID
    let score: Float
    let matchedTerms: Set<String>
    let conflicts: Set<String>
}

protocol CatalogMatching: Sendable {
    func match(
        observation: ProductTextObservation,
        against candidates: [CatalogItemSnapshot]
    ) async -> [CatalogMatch]
}
```

## Matching policy

Matching should combine evidence rather than accepting one weak OCR string.

Recommended evidence:

- Exact normalized phrase match.
- Brand match.
- Product-family match.
- Variant or flavor match.
- Package-size match when present.
- OCR confidence.
- Agreement across consecutive observations.
- Agreement with the route target, edge, search interval, and shelf side.

Recommended rejection evidence:

- Conflicting brand.
- Conflicting variant or size.
- Only generic terms such as “original,” “family,” or “new.”
- Observation outside the active search zone.
- Stale frame timestamp.
- Observation received while the upstream recognition context is disabled.

Nearby products must be distinguished, compare with a small preloaded shelf-neighborhood candidate set rather than every product in SwiftData.

## Temporal confirmation

A single OCR result should normally produce a candidate, not a final item match.

Maintain a short rolling confirmation window keyed by target item:

```text
observation 1: brand + family name
observation 2: family name + variant
observation 3: brand + family name
                    ↓
confirmed ItemObservation
```

Confirmation policy should be configurable and tested on the demo device. A high-confidence exact phrase may require fewer observations than a fuzzy partial match. All candidates expire quickly so stale detections cannot confirm a later frame.

## Inference scheduling

The upstream application may run safety inference at a higher priority than item recognition. This branch does not implement obstacle detection, but its scheduler must yield promptly when recognition is disabled.

```text
External priority: safety and navigation work
This branch priority 1: active product/label-region detection
This branch priority 2: OCR and catalog matching
```

Do not run every request on every frame. Use bounded, latest-frame-wins scheduling:

- No unbounded task queue.
- Drop frames when the appropriate inference slot is occupied.
- Keep the Core ML models loaded for the navigation session.
- Activating product search means feeding selected frames to the resident model, not loading the model at that moment.
- Tune cadence using latency, thermal state, and recall measurements on the actual iPhone.

## SwiftData read/write boundary

The database contributor owns object registration, shared `@Model` definitions, migrations, and persistence policy. This branch must:

- Read candidate catalog objects through `CatalogReading`.
- Convert database objects into immutable `CatalogItemSnapshot` values before OCR matching.
- Return `ItemRecognitionResult` to the caller.
- Persist a result only when the database branch provides `RecognitionResultRecording` and explicitly defines the supported record format.
- Avoid direct schema assumptions outside the SwiftData adapter.

This branch must not independently persist:

- Every camera image.
- Every bounding box.
- Every OCR candidate.
- Raw image crops by default.
- Localization, route, obstacle, or bracelet sensor data.
- New catalog objects or registration records using an uncoordinated schema.

Diagnostic image storage must be an explicit development setting with retention limits and privacy review.

## Catalog data expected from the database branch

Record:

- Expected product name, brand, aliases, variant, and package size.
- Stable item identifier.
- Optional barcode or catalog key.
- Optional nearby-item candidate identifiers for distinguishing shelf variants.
- A stable trigger aisle-landmark identifier for each detectable target or shelf zone.
- The activation threshold in metres after that landmark.
- The deactivation threshold in metres after that landmark.
- Optional expected shelf side supplied as recognition metadata.

The database owner decides how these activation fields are represented in SwiftData. The localization/navigation owner supplies landmark progress. This branch consumes both through protocols and owns the threshold comparison that enables or disables item detection.

## Failure behavior

- If OCR is inconclusive, return `.candidate` or `.noMatch`; do not announce a match.
- If `RecognitionContext.externalPause` becomes true, suspend the gate, stop scheduling new work, and return no confirmed result from later frames until safely resumed.
- If the matching aisle landmark has not been passed, keep detection off with `.waitingForLandmark`.
- If progress has not reached `activateAfterMeters`, keep detection armed but off.
- If progress exceeds `deactivateAfterMeters`, stop detection and report that the configured recognition window was passed without inventing a match.
- If landmark progress is unreliable, suspend detection rather than estimating the user's location locally.
- If catalog data for the target is unavailable, return a typed integration error rather than scanning the entire database or inventing a record.
- If the supplied image orientation or pixel buffer is invalid, reject that image without affecting localization, navigation, persistence, or sensors.
- Presentation, rerouting, item-passed decisions, and bracelet feedback belong to their owning branches.

## Verification plan

### Offline OCR and matching

- Evaluate representative images for all demo items.
- Include glare, blur, oblique angles, partial occlusion, and neighboring variants.
- Measure exact-target acceptance, wrong-variant acceptance, false-positive rate, and no-match rate.

### Integration-context behavior

- Verify the gate remains `.waitingForLandmark` for unrelated landmarks.
- Verify the matching aisle landmark changes the gate to `.armed`.
- Verify detection remains off immediately after the landmark but before `activateAfterMeters`.
- Verify detection turns on exactly when reliable supplied progress crosses `activateAfterMeters`.
- Verify detection turns off after `deactivateAfterMeters`.
- Verify reverse movement and re-entry behavior follows the agreed rule without reusing stale OCR candidates.
- Verify no new OCR work is scheduled while `RecognitionContext.externalPause` is true.
- Verify unreliable progress suspends recognition without invoking localization code.
- Verify the expected item identifier is used to request SwiftData catalog candidates.
- Verify the activation rule's optional expected side is applied only as supplied metadata.
- Verify re-enabling recognition does not reuse stale OCR candidates.

### End-to-end behavior

- Run recognition against representative images for every demo item.
- Record image-input-to-result latency and memory use.
- Verify the concrete SwiftData adapter returns the same catalog snapshots as its test fixture.
- Verify confirmed results can be handed to the database branch's recorder without this branch depending on its internal `ModelContext`.
- Verify no localization, routing, or bracelet modules are required to run the OCR/matching test suite.

## Final retained decisions

1. This branch implements the aisle-landmark/threshold activation gate plus product/label element detection, OCR text extraction, normalization, SwiftData catalog reading, and text-to-catalog matching.
2. Do not add or modify user localization; another branch owns it.
3. Do not implement SwiftData object registration, shared schema design, or migrations; another contributor/branch owns them.
4. Do not implement bracelet sensors or bracelet communication; another branch owns them.
5. Upstream localization supplies the passed landmark, measured progress after it, and reliability; this branch compares those values with the SwiftData-derived activation rule but does not calculate position.
6. Object detection and OCR stay off until the matching aisle landmark is passed and `activateAfterMeters` is crossed; they stop at `deactivateAfterMeters` or an external pause.
7. Upstream camera code supplies `RecognitionImage`; this branch does not open a camera session.
8. Core ML/Vision may find the candidate region; Vision OCR extracts text; an in-memory matcher compares it with SwiftData-derived catalog snapshots.
9. Results leave this feature as `ItemRecognitionResult`; database, navigation, presentation, and sensor layers decide what to do next.
10. SwiftData access is isolated behind `CatalogReading` and the optional `RecognitionResultRecording` protocol; no per-frame images, boxes, or OCR candidates are persisted by default.
11. Xcode, Swift, Swift concurrency, SwiftData, Vision, Core ML, Core Video, Core Graphics/ImageIO, Foundation, XCTest, and Instruments are the explicit tools for this work.
