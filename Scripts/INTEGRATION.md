# Product catalog and recognition integration

## Ownership

`ProductDatabase` owns persisted product names, stable recognition IDs, imports,
and saved activation settings. `ItemRecognition` consumes immutable snapshots;
activation does not save or invent product names, identities, locations, or rules.
`CatalogIntegration` bridges the two libraries. Neither library depends on a UI.
`ShellApp` and `ItemRecognitionDemo` are independent development demos.

The existing `Product` and `StoreLocation` schemas have not changed. Three small
additive tables are registered only by `ProductDatabaseStore`:

| Table | Purpose |
| --- | --- |
| ProductRecognitionProfile | TCIN → stable UUID; optional database-owned brand and aliases |
| ProductActivationSettings | Explicit rule for one TCIN/floor/block/aisle |
| CatalogImportState | Last content digest and import time |

Product titles still live on `Product`. Activation settings do not duplicate them.
The database validates that the product and selected location exist. A sold-out
product can still be carried by the store: membership is configured separately
from `soldOut` and quantity. Missing rules keep the gate inactive.

## Import behavior

`Scripts/run.sh` supplies `--include-unlocated`. The demo has one store:
imports, saved rules, and scan sessions require no store identifier. Capture all
HAR files from that same store; the extractor merges products by TCIN.

The database actor validates the envelope, imports by TCIN, creates missing stable
IDs, records the digest, and saves once. An unchanged digest skips the import.
Errors roll back the actor's pending changes. Partial captures do not delete
absent products or locations; a missing title preserves the saved title. New
locations are added without replacing matching location objects. Explicit location
retirement and full-inventory reconciliation need a separate future workflow.

The original ShellApp can still use `ProductImporter` directly for its demo.
Production callers and the camera demo use `ProductDatabaseStore`; ShellApp is
not the source of catalog data or a requirement for recognition.

## Session contract

1. Import the catalog, then obtain product summaries from `ProductDatabaseStore`.
2. Select an explicit product UUID and location. Multiple locations never fall
   back to the first alphabetical aisle.
3. Save a surveyed or explicitly marked development activation rule. Distances
   must be finite and satisfy `0 <= start <= end`; side is left, right, or unknown.
4. `SwiftDataCatalogReader.load` obtains target, same-aisle candidate records, and
   the selected activation rule in one database-actor operation.
5. The bridge builds `CatalogItemSnapshot` terms using the same `TextNormalizer`
   used for OCR. Only values leave the database actor; no SwiftData model/context
   crosses into recognition.
6. Construct a `RecognitionCoordinator` with those snapshots. Pass coherent
   `RecognitionContext` and `RecognitionImage` values from upstream.
7. Stop and recreate the session after imports, rule edits, location changes,
   or target changes. There are no per-frame SwiftData reads or writes. For context
   changes without camera frames, call `updateContext` to invalidate old work.
8. On completion call `stop`; a stopped coordinator rejects further submissions.

The current candidate set includes the target and other products in the selected
aisle/floor. A larger catalog will need a narrower surveyed shelf-neighborhood
index. Candidate loading is outside the frame-processing path.

## Matching behavior

The lexical MVP compares informative normalized words, weighted by OCR confidence.
Generic words alone do not count. Evidence for a competing close variant rejects
the affected candidate. A target must have at least 0.70 coverage and lead the
next candidate by at least 0.15 for three observations, with no gap over two seconds.
`RecognitionPolicy` configures these defaults. Missing detections, conflicting
observations, pauses, session changes, and expiration prevent stale confirmation.
Duplicate/out-of-order timestamps cannot advance confirmation.

`ItemRecognitionResult` distinguishes disabled, noMatch, candidate, and confirmed.
`RecognitionUpdate.confirmedObservation` exposes an `ItemObservation` only for a
confirmed target. Scores are evidence coverage, **not calibrated probabilities**.
Matching needs real-product tuning: long scraped titles, aliases, multiple labels
in one region, and unseen neighboring variants can reduce accuracy. No stock is
updated and no match is automatically persisted.

## Physical iPhone demo

Open `ItemRecognitionDemo/ItemRecognitionDemo.xcodeproj` and run on the phone.
The landing form imports the bundled JSON into its own local database. Select a
product and location, enter a test rule (for example landmark `demo-aisle`, start
3, end 20), then save. These example values are not a store survey.

Open **Scan selected product**. Progress initially reads 0. Change it to 5 and
tap **Apply progress / restart** to activate the saved 3–20 metre rule. Try a wrong
landmark, unreliable progress, Pause, and progress above 20. These are manual
development inputs, not physical localization. Extracted text and match status
appear together. Close and reopen the scan after a rule edit to load fresh values.

**Camera only (no database)** retains the original extraction demo. It does not
claim product identity. The two demo apps do not share their sandboxed stores.

## Verification and future work

Run from the repository root:

```sh
swift test --package-path Scripts
swift test --package-path ItemRecognition
python3 -m unittest discover -s Scripts/PythonTests
```

Database tests cover duplicate/partial imports, durable IDs/rules, invalid
configuration, explicit location selection, imports without store metadata, real bundled
JSON decoding/import, and opening an existing Product/StoreLocation-only store
with the additive schema. No database reset or destructive migration is used.
No removed OCR image-fixture tests have been reintroduced.

Verification status: earlier runs passed 72 recognition tests, all 12 database
tests, and both unsigned iPhone-target app builds. Final code adds two gate tests
(74 recognition tests total), configurable confirmation, and gallon/quart unit
normalization. Their final Swift reruns were blocked by an automatic approval
review usage limit. Both Python tests, project plist validation, and diff checks
passed after those edits. Physical-device testing is still required.

Still needed: real upstream localization, product-image/device accuracy evaluation,
explicit location retirement, verified brand/alias editing, multi-store inventory
if required, and optional confirmed-result recording. Future changes to the
existing model shapes need versioned migration design with the database owner.
