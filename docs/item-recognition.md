# Item recognition logic

How a spoken list item ("2% milk") becomes a Target product, when the camera starts looking for it, and what counts as "found".

| Code | Job |
|---|---|
| `Scripts/` | Scrapes Target product data into `products.json` and defines the SwiftData catalog |
| `UI/.../Catalog/ProductMatcher.swift` | Picks the catalog product for a list item |
| `UI/.../Recognition/ShoppingCatalog.swift` | Builds what the camera looks for at a stop |
| `UI/.../Recognition/ItemScanner.swift` | Runs the scan and asks "Is this …?" |
| `ItemRecognition/Sources/.../Catalog/`, `Activation/` | Scores what the camera read, and decides when detection is on |

## Stack

SwiftData, Foundation, the `ItemRecognition` package, and Python 3 (standard library) for the scraper.

## 1. The catalog

Product data comes from HAR captures of target.com (Redsky API responses): title, brand, size, price, stock, image, and store location such as block `G`, aisle `44` (`G44`).

`Scripts/output/products.json` is committed, so **you don't need to scrape to run the app**. To refresh it:

1. In your browser's DevTools (Network tab), search target.com with your store selected, then **Save all as HAR**.
2. Put the `.har` files in `product_scraping/`. HARs hold cookies and session headers, so don't commit new ones (`*.har` is git-ignored).
3. Run:
   ```bash
   cd Scripts && ./run.sh ../product_scraping/milk.har ../product_scraping/others.har
   ```
4. Rebuild the app. It re-imports the catalog when the file changes and never touches the lists.

Details: `Scripts/README.md`, `Scripts/INTEGRATION.md`.

## 2. List item → product (`ProductMatcher`)

When an item is added (or when shopping starts), it's linked to one product:

1. The product's own name must contain every word of the item and end with its main word ("bananas" → "Fresh Banana", not "Banana Nut Granola").
2. If the user named a brand, prefer that brand.
3. If the item has a label ("2%", "large brown"), prefer products that mention the most of it.
4. Of what's left, the cheapest. Sold-out products are skipped.

The product's price and location are copied onto the list item. Mira reads back what was added and its price. Items with no match are reported as not in the store.

## 3. When the camera looks

The route stops at each item's location ([navigation.md](navigation.md)). Detection is on only from the stop's first node to the end of its lane + 1.5 m. `ActivationGate` enforces this; no frames are processed on the way there.

At a stop, items are searched one at a time, in list order. Candidates are the item's product plus **every other product at the same spot**, so a lookalike next to it (Doritos Cool Ranch beside Nacho Cheese) isn't mistaken for it.

## 4. What counts as a match

- **Label (OCR):** read words must cover enough of the shopper's list words (not the scraped title), beat every neighbor by a margin, and show no neighbor's distinguishing word. One OCR typo per word is forgiven; numbers must be exact.
- **Produce:** the classifier's class must match. This only proves the category, so the question says so: "This looks like onion. Is it yellow onion?"

Scores are evidence, not probabilities. Thresholds are in `RecognitionPolicy` and `VisualRecognitionPolicy`.

## 5. The shopper decides

A machine match never checks an item off by itself. The phone asks **"Is this Oat milk?"** (with a watch cue):

- **Yes:** tap Yes, or say yes (`check_off_item`). The item is checked off.
- **No:** tap No, or say no (`cancel_current_operation`). It keeps looking.

After one minute on an item, the shopper is told to move on.

## Tests

```bash
cd Scripts && swift test                    # catalog + integration tests (full Xcode)
python3 -m unittest discover Scripts/PythonTests
cd ItemRecognition && swift test
```
