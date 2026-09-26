# HAR → SwiftData product scripts

Extracts Target product data (including **aisle, block and floor**) from HAR captures of
target.com and loads it into SwiftData.

```
./run.sh                    # ../milk.har + ../others.har → output/products.json, then verify
./run.sh some.har other.har # any HAR captures
```

| File | What it does |
|---|---|
| `extract_har.py` | Reads HARs (Python stdlib only), merges every Redsky API response by TCIN, writes `output/products.json`. |
| `SwiftData/Product.swift` | `@Model` `Product` and `StoreLocation` (aisle/block/floor, one-to-many). |
| `SwiftData/ProductDTO.swift` | Codable mirror of `products.json`. |
| `SwiftData/ProductImporter.swift` | Upserts `products.json` into a `ModelContext` (re-import updates, never duplicates). |
| `verify_import.swift` | Imports into an in-memory store and prints samples (needs full Xcode). |
| `verify_decode.swift` | Decodes `products.json` with the DTOs (works with Command Line Tools). |

## Using it in the app

`ShellApp/ShellApp.xcodeproj` (repo root) already uses these files directly: it compiles
`SwiftData/*.swift` and bundles `output/products.json`, and re-imports on every launch, so
running `./run.sh` then rebuilding the app picks up new data. To use them in another project:

1. Drag the three files in `SwiftData/` and `output/products.json` into your Xcode target.
2. Register the models and seed on launch:

```swift
@main
struct ShellApp: App {
    let container = try! ModelContainer(for: Product.self, StoreLocation.self)

    init() {
        try? ProductImporter.seedIfNeeded(into: container.mainContext)
    }

    var body: some Scene {
        WindowGroup { ContentView() }.modelContainer(container)
    }
}
```

3. Query by location:

```swift
@Query(filter: #Predicate<StoreLocation> { $0.block == "G" && $0.aisle == 44 })
var aisle44: [StoreLocation]          // aisle44.map(\.product)

product.locationLabel                 // "G44"
product.locations                     // every spot the item is stocked
```

## What gets stored per product

| Field | Example |
|---|---|
| `tcin` | `13276204` |
| `title` | 2% Reduced Fat Milk - 1gal - Good & Gather™ |
| `parentTitle` | Milk - Good & Gather™ (only for variations, otherwise empty) |
| `itemType` / `itemTypeId` | Milk and Buttermilk / `434372` |
| `buyURL` | target.com product page |
| `primaryImageURL`, `alternateImageURLs` | Target image CDN links |
| `imageAltText` | description of the primary image |
| `formattedPrice`, `currentPrice`, `regularPrice` | `$2.99`, `2.99`, `2.99` (regular > current means on sale) |
| `unitPrice`, `unitPriceSuffix` | `$0.02`, `/fluid ounce` |
| `quantityAvailable`, `soldOut` | stock at the captured store |
| `locations` → `StoreLocation` | block `G`, aisle `44`, floor `01` (each spot once) |

Notes:
- Location and stock data are for the store the HAR was captured against (store 1074, Aventura).
- Products with no aisle/block (out of stock, discontinued, or not sold in store) are left out
  of `products.json`, and the importer deletes any already in the database. Pass
  `--include-unlocated` to `extract_har.py` to keep them in the JSON.
