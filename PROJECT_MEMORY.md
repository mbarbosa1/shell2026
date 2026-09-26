# Persistent Project Memory — Item Detection, OCR, and SwiftData Matching

## Purpose

This document is the durable architectural memory for implementing grocery-item text recognition and SwiftData catalog matching in the Target-Navigation iOS application. Future design and implementation work should preserve the decisions below unless the user explicitly changes them.

This branch receives image input and recognition context from other parts of the application. It uses Apple Vision OCR, optional Core ML element/label-region detection, and a narrow SwiftData catalog gateway. It does not implement user localization, database registration, or bracelet sensors.

## Branch ownership and coordination boundary

This scope is intentionally narrow.

### Work owned by this branch

- Accept a provided camera image or detected-element crop through a Swift interface.
- Detect a product package, label, or text-bearing element when a crop is not already supplied.
- Extract text from that element with Apple Vision OCR.
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
- **Apple Vision** — `VNRecognizeTextRequest` for OCR and `VNCoreMLRequest` when a Core ML detector is used through Vision.
- **Core ML** — on-device model execution for locating a product package, label, or text-bearing region when needed.
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


