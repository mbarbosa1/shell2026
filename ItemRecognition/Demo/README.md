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
| **Best match** | The item the matcher picked. It appears in orange when it's a neighbor rather than your target. |
| **What it sees** | Produce labels with their scores, or each OCR line with its confidence. |

When the app is confident, it asks **Is this …?**. Answer **Yes** to finish, or **No** to keep looking.

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
| Match coverage (OCR) | 40% | restart |
| Produce score (Apple Vision) | 30% | restart |

The defaults are the library's own defaults (`RecognitionPolicy`, `VisualRecognitionPolicy.appleVisionProduce`).
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
5. **Thresholds:** raise match coverage to 80% and restart. The same label should stop confirming.
6. **Monkey:** run it for a minute while pointing at the target. Recognition must only run while the gate is
   *Active*, and must never confirm while paused or past the window.

Search the Xcode console for `[ItemRecognition]` for one line per change of status, score, or advice.
