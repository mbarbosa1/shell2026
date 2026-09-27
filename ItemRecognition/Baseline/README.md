# Recognition baseline — protocol

A repeatable measurement of where recognition fails today, run on a phone in the store. Every trial records which pipeline stage its frames stopped at, so a failure is attributed to **activation**, **localization**, **cropping**, **OCR/classification**, or **matching** instead of to "recognition" in general. The stages are defined in `../DefiningSuccess.md` and computed by `RecognitionUpdate.stageOutcome` (`../Sources/ItemRecognition/Evaluation/RecognitionStage.swift`), so the demo, tests and a future ShellApp integration all use the same definition.

No results exist yet. Nothing below is a measured number.

## What counts as correct

| Trial kind | What is in view | Correct when |
|---|---|---|
| `target` | The selected item itself | The app asks and the tester answers **Yes** |
| `lookalike` | A near neighbor of the selected item (Cool Ranch for Nacho Cheese, potato for onion) | The app never asks |
| `negative` | Anything else: another product, empty shelf, hand, the shelf tag alone | The app never asks |

A question on a lookalike or negative trial is a **false ask**. Answer **No** (the app keeps looking and counts the rejection), then **Stop**.

## Setup

1. Build `ItemRecognition/Demo` to the phone (see `../Demo/README.md`). Record the phone model; the CSV records it too.
2. In the app, turn on **Record baseline trials**. Leave calibration at its defaults (65% of list words, 30% produce, 3–20 m window, position 5 m, reliable) unless a trial is testing activation.
3. Decide the Gemini proxy setting once per session and keep it fixed. Leave it empty for the on-device baseline.

## One trial

1. Pick the **selected item** in the list.
2. On the Baseline trial card, choose **target / lookalike / negative**, type what is actually in view, and set place, light, distance and motion. Do this **before** Start: the expected answer is fixed before any result is seen.
3. Tap **Start**. Hold the phone as a shopper would. Follow the on-screen arrow at most twice; do not hunt for a lucky angle.
4. Stop when one of these happens:
   - asked on a target → **Yes** (saves the trial);
   - asked on a lookalike/negative → **No**, then **Stop**;
   - 30 seconds without a question → **Stop**;
   - the one-minute notice appears → **Stop** (saved as `timedOut`).
5. Read the saved summary line on the card, then start the next trial.

## Trial plan

### Phase 1 — find the failing items (about 20 minutes)

One `target` trial per preset item (17 items), in the store, normal light, arm's length, still. Any item not answered within 30 seconds is a **failing item**. Also check these, which are suspected risks but not measured:

| Item | Why it is suspected |
|---|---|
| Fresh Yellow Onion | An earlier phone frame scored onion at about 31% against a 30% threshold. |
| Quaker Instant Oatmeal | The list entry "Quaker maple brown sugar oatmeal" needs four of five words; the flavor words may be small. |
| Doritos Cool Ranch / Nacho Cheese | The stylized DORITOS logo may not be read; each entry then needs both flavor words. |
| Grade A Large Eggs | "EGGS" is often printed twice on the carton, far apart. |

Label items are scored against the grocery-list entry on the scan screen, not the long catalog title. Keep the prefilled entry for the baseline so runs compare.

### Phase 2 — baseline (about 1.5 hours)

Five trials per row, in the store. Include at least four failing items from Phase 1; replace the examples below with what Phase 1 found.

| Selected item | Kind | In view | Conditions |
|---|---|---|---|
| Each failing item from Phase 1 | target | the item | normal · arm · still |
| Doritos Nacho Cheese | lookalike | Doritos Cool Ranch | normal · arm · still |
| Doritos Cool Ranch | lookalike | Doritos Nacho Cheese | normal · arm · still |
| Oreo Chocolate | lookalike | Oreo Golden | normal · arm · still |
| Oreo Golden | lookalike | Oreo Chocolate | normal · arm · still |
| Fresh Yellow Onion | lookalike | potato (then shallot) | normal · arm · still |
| Fresh Limes | lookalike | lemons | normal · arm · still |
| Fresh Gala Apple | lookalike | tomato | normal · arm · still |
| Navel Oranges | lookalike | grapefruit | normal · arm · still |
| any OCR item | negative | a product not in the list (water bottle) | normal · arm · still |
| any OCR item | negative | the item's **shelf tag only**, product removed | normal · arm · still |
| any produce item | negative | empty shelf / floor | normal · arm · still |
| any item | negative | the tester's hand | normal · arm · still |

Then, for two items that pass (one OCR, one produce) and one failing item, three trials each under: **dim**, **glare**, **far**, **walking**. These show whether a failure is the item or the conditions.

The shelf-tag negative matters: OCR can read the product name from the tag, which would be a false ask that looks right on screen.

## Reading the results

Export the CSV from the app (**Export … trials**), save it as `results/<date>-<store>-<phone>.csv` in this folder, then:

```sh
python3 ItemRecognition/Baseline/summarize.py ItemRecognition/Baseline/results/<file>.csv
```

It prints correct rates by kind, per-item target results, every false ask, where failed target trials stopped, and success by condition. Keep each run's CSV; compare runs only when thresholds, path and phone match (the CSV records all three).

## CSV columns

One row per trial.

| Column | Meaning |
|---|---|
| `started`, `device`, `ios` | When, which phone model id (e.g. `iPhone16,1`), iOS version |
| `place`, `light`, `distance`, `motion` | Conditions declared before Start |
| `kind`, `target_tcin`, `target_title`, `shown` | What was selected and what was actually in view |
| `path` | `ocr`, `appleVision` or `gemini` |
| `coverage_threshold`, `produce_threshold` | Thresholds the scan ran with (coverage is the share of grocery-list words) |
| `outcome` | `accepted` (Yes), `stopped`, `timedOut`, `error` |
| `correct` | See the table at the top |
| `asks`, `rejections` | Questions shown; No answers |
| `asked_level` | `product` or `category` for the first question. A `category` answer means only the produce class was recognized |
| `seconds_to_first_ask`, `seconds` | Time to the first question; trial length |
| `frames` | Processed frames (about one in five camera frames) |
| `furthest_stage` | The latest stage any frame reached |
| `blocker` | The failure stage most frames stopped at; ties go to the earlier stage |
| `frames_<stage>` | Frame count per stage |
| `top_reasons` | Most frequent `stage/reason`, e.g. `cropping/textTooSmall 14` |
| `max_score_pct`, `max_match_pct` | Best single-frame evidence and best smoothed match confidence for the target |
| `leading_neighbor` | OCR only: the other item that most often outscored the target |
| `last_read` | Last OCR text, or top produce labels |
| `notes` | Free text |
| `list_entry` | The grocery-list words the scan matched against |

## Reasons by stage

| Stage | Reasons | Usual fix area |
|---|---|---|
| activation | `beforeActivationThreshold`, `pastDeactivationThreshold`, `unreliableProgress`, `externalPause`, `landmarkMismatch`, … | localization / rule window, not recognition |
| localization | `notLocated`, `focusing`, `moving`, `multipleObjects` | framing guidance, camera focus |
| cropping | `tooSmall`, `clipped`, `textTooSmall`, `noText`, `unsuitable` | distance guidance, label-region detector |
| ocr/classification | `noWordsRead`, `targetClassAbsent`, `belowScoreOrLead` | OCR settings, produce model, threshold |
| matching | `neighborLeads`, `partialTitle`, `noTargetWords`, `categoryOnly`, `ambiguousCatalog` | list entry wording, competing aisle products, coverage/lead policy (`partialTitle` means part of the list entry was read) |
| confirming | `needsMoreFrames` | not a failure; temporal policy |
