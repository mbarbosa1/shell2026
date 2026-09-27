# Produce detector — training requirements (MVP)

This folder defines everything needed to train the on-device produce model. The app already works without it: Apple Vision classifies on device, and the optional cloud assist (`../CloudProxy/`) covers weak frames. The custom model replaces the Apple Vision baseline once it beats it on the held-out test set.

## What is being trained

- A **Create ML Object Detector** trained on **bounding boxes**.
- **Broad labels only.** Every class name is a key in `../Sources/ItemRecognition/Resources/produce-taxonomy.json`. Any onion is `onion`, any apple is `apple`. Never use a variety, organic, size, or brand label.
- The trained model plugs in as the local model behind `ProduceCategoryClassifier`, so the catalog mapping (`mvp.produce.categories.v1`) does not change.

### Classes

| Priority | Labels | Why |
|---|---|---|
| Required (mapped to catalog products) | `onion`, `apple`, `banana`, `orange`, `lime`, `grape`, `strawberry`, `avocado`, `carrot`, `cucumber` | These select visual recognition in `visual-product-mappings.json`. |
| Confusers (label whenever they appear) | `lemon`, `grapefruit`, `potato`, `garlic`, `tomato`, `pear`, `peach`, `mango`, `pineapple`, `watermelon`, `broccoli` | Teach the model the lookalikes: lemon vs lime, potato/garlic vs onion, grapefruit vs orange, tomato vs apple. |

To add a class, add it to the taxonomy first, then map products to it in `Scripts/RecognitionIntegration/Resources/visual-product-mappings.json`. Do not invent labels in the annotation tool.

### How one label covers varieties

| Label | Includes |
|---|---|
| `onion` | yellow, red, white, sweet onions. Leave scallions, leeks and shallots **unlabeled**. |
| `apple` | Gala, Honeycrisp, Granny Smith, Rockit mini, any red or green apple |
| `orange` | navel, mandarin, clementine, Sun Beams |
| `grape` | red, green, bi-color bunches |
| `banana` | single banana or a hand of bananas |
| `carrot` | whole and baby-cut carrots |
| `cucumber` | English, mini, slicing |

## Bounding-box rules

1. **Box every visible instance of every listed class.** An unboxed onion in the image teaches the model that onions are background. If an image has more than about 15 instances (a full bin), reframe the shot instead of using it.
2. **Loose items:** one tight box per item, stem included. **Bunches** (a banana hand, a grape bunch) get one box per bunch.
3. **Bags and clamshells** (limes in a bag, strawberries in a clamshell): one box around the visible produce in the package, labeled with that produce.
4. **Occlusion:** box the visible part if at least about 30% of the item shows. Otherwise leave it unlabeled and prefer another image.
5. **Hands and carts:** box only the produce.
6. **Never box pictures of produce** printed on packaging (strawberry cereal, apple-cinnamon oatmeal, onion chips). Those are hard negatives; see below.
7. Boxes under 16 px on the short side are too small to learn from. Move closer.

## Capture requirements

- **Camera:** the intended iPhone rear camera in portrait, framed the way the app is used (0.3–1.5 m, item roughly centered).
- **Minimum for a first training run:** 100 training images per required class, from at least 10 distinct physical specimens (different onions, not 100 photos of one onion), across at least 3 capture sessions. **Target:** 300 images per class.
- **Vary:** store lighting, daylight, dim/warm home light; store bin, shelf, counter, cart, hand; top, side, and oblique angles; near and far; loose and bagged; one item and several; slight motion blur.
- **Cover varieties within each label:** yellow, red, and white onions; red and green apples; and so on.
- **Hard negatives (at least 20% of labeled images):** packaged products that show produce (catalog examples: TCIN `95193579` strawberry cereal, `14895487` strawberry Pop-Tarts, `86434939` apple-cinnamon oatmeal, `52909342` chips with onion flavour, `78901007` apple sausage), empty shelves, carts, floor. These go in `negatives/`, listed in `captures.csv` with split `negative`. They are used for on-device false-positive checks. Create ML splits contain only images with at least one box.
- **Images:** JPEG, upright pixels (EXIF orientation 1), long side 1024–2048 px. Re-export rotated iPhone photos before labeling; boxes drawn on a rotated display do not match the stored pixels.
- **Privacy:** no faces, no other shoppers, no payment screens. Get store permission before capturing in-store. Photos are never committed (`.gitignore` excludes `dataset/`).

## Splits: by specimen and session, never by frame

Split about 70 / 15 / 15 into `train` / `validation` / `test`. Every photo of the same physical specimen, and every photo from the same capture session, must be in the same split. Otherwise adjacent frames leak into the test set and the scores are inflated. The validator enforces this using `captures.csv`. Tune thresholds on `validation`; look at `test` once, for the final report.

## Folder layout

```text
Training/
  README.md                  this file
  captures-template.csv      copy to dataset/captures.csv
  model-card-template.md     copy to models/<model-id>.md after training
  validate_annotations.swift
  dataset/                   not committed
    captures.csv             image,split,specimen_id,session_id,lighting,background,notes
    train/annotations.json   + images
    validation/annotations.json + images
    test/annotations.json    + images
    negatives/               no-produce and packaged-produce images
  models/                    model cards (committed); .mlmodel files are shared separately
```

`captures.csv` uses the split-relative path, for example `train/IMG_0001.jpg`, `negatives/IMG_0420.jpg`.

## Annotation format (Create ML JSON)

Each split folder has one `annotations.json`. `x` and `y` are the **centre** of the box in pixels, measured from the **top-left** of the upright image. `width` and `height` are also in pixels.

```json
[
  {
    "image": "IMG_0001.jpg",
    "annotations": [
      { "label": "onion", "coordinates": { "x": 812, "y": 640, "width": 410, "height": 395 } },
      { "label": "potato", "coordinates": { "x": 300, "y": 700, "width": 220, "height": 180 } }
    ]
  }
]
```

Any labeling tool that exports Create ML JSON works; confirm the export uses centre coordinates.

## Validate before training

```bash
swift ItemRecognition/Training/validate_annotations.swift ItemRecognition/Training/dataset
```

The validator **fails** on:

- labels outside the taxonomy (for example `yellow_onion`)
- boxes with no area or outside the image
- rotated EXIF orientation
- missing or duplicate images
- images with no boxes inside a split
- images missing from `captures.csv`
- a specimen or session that appears in more than one split

It **warns** about classes below the minimum counts, classes with no validation or test images, and too few negatives. It prints a per-class table of images, boxes, and specimens.

## Train with Create ML

1. Open Create ML and choose **New Document**, then **Object Detection**.
2. Set Training Data to `dataset/train`, Validation Data to `dataset/validation`, and Testing Data to `dataset/test`.
3. Start with **Transfer Learning**, which is smaller and faster on device. Try **Full Network** only if accuracy is short and you have enough data.
4. Train, then review per-class precision and recall and the test set's failure cases.
5. Export `ProduceDetector.mlmodel` and add it to the `ItemRecognitionDemo` target. Xcode compiles it to `ProduceDetector.mlmodelc`.

## Plug the model in

```swift
let detector = try CoreMLVisualClassifier(
    compiledModelURL: Bundle.main.url(forResource: "ProduceDetector", withExtension: "mlmodelc")!,
    modelID: "custom.produce-detector", version: "2026-10-01", cropAndScale: .scaleFit,
    classLabels: ["apple", "avocado", "banana", /* exact class list from the model card */])
let classifier = try ProduceCategoryClassifier(base: detector, cloud: DemoCloudAssist.labeler())
```

Detector boxes are collapsed to the best score per label, because the pipeline still assumes one prominent item per crop. Re-tune `VisualRecognitionPolicy.minimumScore` and `minimumMargin` for the new model on the validation split, and check whether `CloudAssistPolicy.appleVisionSeconds` (time on device before Gemini is asked) still suits it. Detector confidences are not on the same scale as Apple Vision's.

## Acceptance before replacing the Apple Vision baseline

Proposed thresholds, to be agreed before sign-off. Measure on the held-out `test` split and on the intended iPhone:

- per required class: precision ≥ 0.90 and recall ≥ 0.80 at the chosen threshold
- false-positive rate on `negatives/` ≤ 2%
- better than the Apple Vision baseline on the same test images
- latency, memory, and thermal behavior measured with Instruments

Record the results in a model card (`model-card-template.md`).

## Where cloud AI helps, and where it does not

- **Now:** Apple Vision on device plus cloud assist for weak frames supports the MVP demo without a custom dataset. That is why training is not on the critical path.
- **Triage:** the proxy's single-label answers can sort raw captures into class folders and flag likely negatives, which speeds up labeling.
- **Not ground truth:** cloud labels do not come with reliable boxes. Humans draw and review every box. Never put an unreviewed cloud label in `test`.
- The app does not store camera frames. Training photos come from deliberate capture sessions.
