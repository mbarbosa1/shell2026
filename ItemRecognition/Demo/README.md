# Item Recognition Test app

A standalone iPhone app for testing `ItemRecognition` with the camera. It needs no database,
no localization, and no network. The target items are built into the app, and a
calibration panel stands in for the navigation signal that will later turn recognition on.

## Run it on an iPhone (iOS 17+)

1. Open `ItemRecognition/Demo/ItemRecognitionDemo.xcodeproj` in Xcode.
2. In **Signing & Capabilities**, pick your team. If signing complains, change the bundle ID
   `com.example.ItemRecognitionDemo` to something unique.
3. Choose the **ItemRecognitionDemo** scheme and your iPhone (not a simulator; it has no camera).
4. Press **Command-R**, and allow camera access.

Build check without a phone:

```sh
xcodebuild -project ItemRecognition/Demo/ItemRecognitionDemo.xcodeproj -scheme ItemRecognitionDemo \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## What the screen shows

| Area | Meaning |
|---|---|
| Arrow over the preview | Which way to step so the item is in the middle: left, right, closer, back, hold steady, turn the label. **Centered – hold still** (green) means an item is in view and no move is needed. |
| Gate bar | Whether recognition is allowed right now, and why not: armed, waiting, suspended, passed. |
| **Title words read** / **Label score** | This frame's evidence for the target, with the threshold it must reach. The black tick is the threshold. |
| **Match confidence** | The same evidence averaged over recent frames. |
| **OCR read quality** | How sure Vision is about the letters. This is read quality, not whether the product is right. |
| **Stopped at** | Where the latest frame stopped: activation, localization, cropping, ocr/classification, matching, confirming, or awaiting shopper, with the reason (for example `cropping · textTooSmall`). |
| **Best match** | The item whose words scored highest on the latest frame. It appears in orange when it's a neighbor rather than your target. |
| **Result** | `candidate`, `noMatch`, `confirmed`, or **category match** when only the kind of produce was recognized. |
| **What it sees** | Produce labels with their scores, or each OCR line with its confidence. |

When the app is confident, it asks. A label match asks **Is this <product>?**. A produce match can only
recognize the kind of produce, so it asks **This looks like onion. Is it <product>?** and reminds you to
check variety and size. Answer **Yes** to finish, or **No** to keep looking.

Frames taken while the camera refocuses are skipped (the capture passes `AVCaptureDevice.isAdjustingFocus`
with each frame), and the arrow says **Hold the phone steady**.

Packaged items only read the label. There is no switch to appearance recognition when no text is found:
a produce classifier cannot tell packages apart. The arrow asks you to turn the label toward the camera instead.

## Baseline trials

Turn on **Record baseline trials** in the item list to measure where recognition fails. Each Start→Stop is
one trial; the camera then waits for **Start** so you can say what is in view first. Trials are appended to a
CSV you can export from the list. The full protocol, trial plan and a summary script are in
[`../Baseline/README.md`](../Baseline/README.md).

## Items

All items come from `Scripts/output/products.json`, and are built into the app.

- **By appearance (Apple Vision):** onion, banana, gala apple, avocado, limes, oranges, carrots.
- **By label (OCR):** milk, eggs, butter, Cheez-It, oatmeal, Corn Pops, plus two lookalike pairs:
  Doritos Nacho Cheese / Cool Ranch and Oreo / Oreo Golden.

Every item is a match candidate. So reading the Cool Ranch bag while targeting Nacho Cheese should
show Cool Ranch as the best match, not confirm the target.

## Calibration

| Setting | Default | Applies |
|---|---|---|
| Metres past landmark | 5 m | next frame |
| Position reliable / Paused / Wrong landmark | on / off / off | next frame |
| Landmark ID | `demo-aisle` | restart |
| Start recognizing at / Stop after | 3 m / 20 m | restart |
| List words read (OCR) | 65% | restart |
| Produce score (Apple Vision) | 30% | restart |

The defaults are the library's own defaults (`RecognitionPolicy.minimumQueryScore`, `VisualRecognitionPolicy.appleVisionProduce`).
Label items are matched against the **Grocery list entry** on the scan screen (prefilled per item, e.g. "2% milk"), not the catalog title. Edit it before Start to try what a shopper would type.
Window and threshold changes need a restart because `ActivationGate` loads the rule once per scan.
The panel turns yellow and shows **Restart to apply** when they differ from the running scan.

**Monkey test** changes the position once a second. The metres take a random walk (−2 to +3 m) or,
one time in ten, jump anywhere in range. Pause, unreliable, and wrong landmark are each on
10% of the time. Each tick is logged on screen and in the Xcode console as
`[ItemRecognition] Monkey: …`.

## Test checklist

1. **Gate:** metres 0 → *Armed*. 5 → *Active*. 21 → *Passed*. Pause → *Suspended*. Wrong landmark → *Waiting*.
2. **Position:** hold an item at the left edge → arrow left. Right edge → right. Very close → back.
   Far away → closer. Middle → green *Centered*.
3. **Produce:** target the onion and frame an onion. Its score should pass 30%, then you're asked.
   Try a potato: onion should stay below the threshold.
4. **Lookalikes:** target Doritos Nacho Cheese and show Cool Ranch. The best match should be the neighbor.
5. **Thresholds:** set the list entry to three words, raise *List words read* to 100% and restart. A label showing two of the words should stop confirming.
6. **Monkey:** run it for a minute while pointing at the target. Recognition must only run while the gate is
   *Active*, and must never confirm while paused or past the window.

Search the Xcode console for `[ItemRecognition]` for one line per change of status, score, or advice.
