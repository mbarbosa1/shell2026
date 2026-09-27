# Model card: <model-id> <version>

- **Model ID / version** (passed to `CoreMLVisualClassifier`):
- **Date trained / trained by:**
- **Create ML version, algorithm (Transfer Learning / Full Network), iterations:**
- **Input size and crop/scale option used in the app:**
- **Class list, in model order:**
- **Taxonomy version** (`produce-taxonomy.json`):

## Data

| Class | Train images / boxes | Validation images / boxes | Test images / boxes | Specimens |
|---|---|---|---|---|

Negatives: <count>. Capture sessions: <list>. Paste the validator output.

## Results (held-out test split)

| Class | Precision | Recall | Threshold |
|---|---|---|---|

- False-positive rate on negatives:
- Apple Vision baseline on the same test images:
- On-device latency / memory / thermal (iPhone model, iOS version):

## Known failure cases

## Tuned app thresholds

- `VisualRecognitionPolicy.minimumScore` / `minimumMargin`:
- `CloudAssistPolicy.appleVisionSeconds` (time on device before Gemini is asked):
