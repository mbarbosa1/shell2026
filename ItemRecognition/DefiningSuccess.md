# Defining success

The recognition pipeline answers four different questions, in order. Each one produces *evidence*, not a verdict. The only real success event is the shopper's answer: `RecognitionCoordinator.acceptInsight()` returning a non-nil `ItemObservation`. Everything upstream of that exists to decide when it's worth asking the shopper — never to skip asking them, even when the machine is highly confident.

## Stage 1 — Locate: is there an object to look at?

- **Type:** `FrameAssessment` (`Sources/ItemRecognition/Extraction/FrameAssessing.swift`)
- **Evidence:** `quality` (`usable`, `notLocated`, `multipleObjects`, `moving`, `focusing`, `tooSmall`, `clipped`) plus `objectRegion`/`objectBoxes` — foreground-instance-mask boxes, normalized lower-left.
- **Success at this stage:** `isSuitable` (`quality == .usable && objectRegion != nil`).
- `focusing` comes from the camera, not from the image: the camera owner sets `RecognitionImage.isAdjustingFocus` from `AVCaptureDevice.isAdjustingFocus` on every frame (the demo does; ShellApp must too). Without it, frames taken while the lens refocuses count as evidence.
- For OCR frames there's a second, related signal: `LabelRegionDetection.Readiness` (`.unsuitable`, `.noText`, `.textTooSmall`, `.readable`, in `VisionLabelRegionDetector.swift`), gated by `minimumPackageConfidence = 0.5` and `minimumTextHeight = 32` oriented pixels.
- This is purely geometric/legibility evidence. As `VisionFrameAssessor.swift` states directly: **"A location is not evidence of identity."** Passing Stage 1 means only "worth running classification/OCR on this frame" — it says nothing about *what* the object is.

## Stage 2 — Categorize: what kind of thing is it?

- **Types:** `VisualObservation` / `VisualClassification` (`Visual/VisualClassifying.swift`), `ProduceCategoryClassifier`'s broad taxonomy (`Visual/ProduceCategoryClassifier.swift`), `CloudProduceLabel` (`Visual/CloudProduceLabeling.swift`).
- **Evidence:** raw model `score`, explicitly documented as *"Model score, not a calibrated probability of an exact catalog match,"* gated by `VisualRecognitionPolicy`: `minimumScore` (0.8 general model, 0.3 produce), `minimumMargin`, and a `noiseFloor` of 0.1.
- **Success at this stage:** the category label clears its threshold and margin over competing labels. `ProduceCategoryClassifier.swift` states the boundary: **"Variety, brand, size and organic status are not classes."** Category success answers "is this an onion," never "is this *the* onion on the shopper's list."
- The OCR path has an analogous, weaker signal: normalized text tokens (`TextNormalizer`) are words read, not yet scored against any specific catalog item — evidence of the same kind, before verification.

## Stage 3 — Verify: is this the specific catalog item?

- **Types:** `CatalogMatch` (text path, `Catalog/CatalogMatcher.swift`), `VisualCatalogMatch` (visual path, `Catalog/VisualCatalogMatcher.swift`), unified in `ItemRecognitionResult` (`Catalog/ItemRecognitionResult.swift`).
- **Evidence:**
  - *Text:* `score` as evidence coverage. With the shopper's grocery-list entry (`GroceryQuery`, the normal case): the share of the list words read on one package (lines grouped by proximity), each word matched approximately (plurals, one OCR slip in up to seven letters, two from eight; numbers exact), gated by `minimumQueryScore = 0.65`, `minimumMargin = 0.15` over the best competing aisle product's title score, and no competing product's own name words read. A product the list entry also describes ("Doritos" fits both flavors) does not compete. Without a list entry: weighted matched catalog-title terms / expected term count, gated by `minimumScore = 0.4`.
  - *Visual:* `VisualCatalogMatch.Reason` — `.accepted` (SKU-level model, unambiguous), `.acceptedCategory` (MVP broad-category model, *"variety not checked"*), `.categoryOnly`, `.ambiguousCatalog`, `.insufficientEvidence` — plus a `confidence` (0...1, relative to competing labels) documented as *"Not a calibrated probability."*
  - Both paths smooth evidence across repeated frames via `TemporalConfirmation` (N observations inside `maximumGap`) and `MatchConfidenceSmoother`, rather than trusting a single frame.
- **Success at this stage:** `ItemRecognitionResult.status == .confirmed`. This is a **machine** verdict, not shopper-visible success — `RecognitionUpdate.confirmedObservation` says so directly: **"Machine suggestions awaiting a verdict are never final item-found events."**
- OCR text evidence and visual/category evidence are never summed or blended into one score. A session picks one path at setup and keeps it: appearance for mapped produce, label text for everything else. There is no text-to-appearance fallback, because a produce classifier cannot tell one packaged product from another; it could only ever claim a category.
- `ItemRecognitionResult.matchLevel` names what a confirmed match established: `.product` (label text, or a SKU-level model, set this item apart from every aisle candidate) or `.category` (the MVP produce model matched the broad class only; variety, brand, size and organic status were not checked). Both still require Stage 4, but the question differs: `RecognitionUpdate.verdictPrompt` asks "Is this 2% milk?" for a product match and "This looks like onion. Is it yellow onion?" for a category match, naming the shopper's grocery-list entry. Without a list entry it names the catalog title.
- `ItemRecognitionResult.leadingItemID` names the catalog item whose words scored highest on the frame, even when that is a lookalike neighbor. `matchedItemID` stays nil until the target itself is confirmed.

## Stage 4 — Shopper confirmation: the only real success

- **Types:** `RecognitionCoordinator.acceptInsight()` / `.rejectInsight()` (`Extraction/RecognitionCoordinator.swift`), the `awaitingVerdict` flag, `ItemObservation` (`Catalog/ItemRecognitionResult.swift`) — the actual success payload.
- **Evidence:** a human yes/no answer to "Is this `<product name>`?" Implemented today only in the throwaway Demo app (`Demo/Sources/ScanModel.swift`'s `confirmInsight()`/`negateInsight()`, backed by the verdict UI in `Demo/Sources/CameraDemoView.swift`). ShellApp has no confirmation UI yet.
- **Success:** only `acceptInsight()` returning a non-nil `ItemObservation`. This holds even for an unambiguous SKU-level (`.accepted`) visual match — **there is no fast path that skips the shopper.** The library's own default-policy comment states why: *"the shopper's Accept/Deny is the final check."*
- The receipt keeps `matchLevel` and, for `.category`, the `category` label. A `.category` receipt means the shopper, not the recognizer, vouched for the exact product.
- This is the gap ShellApp integration (step 5 of the agreed integration order in `PROJECT_MEMORY.md`) still has to close: whatever UI is built there must produce exactly this event, not just display a `.confirmed` status.

## Summary

| Stage | Question | Evidence type | Threshold | Not evidence of |
|---|---|---|---|---|
| 1. Locate | Is there something to look at? | `FrameAssessment.quality` | `isSuitable` | identity |
| 2. Categorize | What kind of thing is it? | `VisualObservation.score` | `minimumScore` / `minimumMargin` | the exact SKU |
| 3. Verify | Is it *this* catalog item? | `ItemRecognitionResult.status` | `.confirmed` (score, margin, repeated observations) | shopper agreement |
| 4. Confirm | Did the shopper say yes? | `ItemObservation` from `acceptInsight()` | shopper tap | — this *is* success |

## Measuring where frames stop

`RecognitionUpdate.stageOutcome` (`Sources/ItemRecognition/Evaluation/RecognitionStage.swift`) names the stage each processed frame stopped at, with a reason: activation, localization, cropping, OCR/classification, matching, confirming, or awaiting the shopper. `RecognitionStageTally` counts them per scan. The baseline protocol in `Baseline/README.md` uses these to attribute every failed trial to a stage.
