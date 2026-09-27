#!/usr/bin/env python3
"""Extract Target (Redsky API) product data from HAR captures into a JSON
file that the SwiftData importer (SwiftData/ProductImporter.swift) can load.

Products are merged by TCIN across every response in every HAR, because
different endpoints carry different fields: recommendations have images,
product_summary_with_fulfillment has aisle/block and stock info.
"""

import argparse
import base64
import html
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def response_json(entry):
    content = entry.get("response", {}).get("content", {})
    text = content.get("text")
    if not text:
        return None
    if content.get("encoding") == "base64":
        text = base64.b64decode(text).decode("utf-8", errors="replace")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def iter_product_nodes(node):
    """Yield every ProductSummary-like dict anywhere in a response."""
    if isinstance(node, dict):
        if "tcin" in node and any(k in node for k in ("item", "price", "store_positions")):
            yield node
        for value in node.values():
            yield from iter_product_nodes(value)
    elif isinstance(node, list):
        for value in node:
            yield from iter_product_nodes(value)


def deep_merge(dst, src):
    """Merge src into dst; non-empty src values win, dicts merge recursively."""
    for key, value in src.items():
        if isinstance(value, dict) and isinstance(dst.get(key), dict):
            deep_merge(dst[key], value)
        elif value not in (None, "", [], {}) or key not in dst:
            dst[key] = value
    return dst


def clean(text):
    # Titles come double-escaped, e.g. "Good &#38;#38; Gather&#8482;".
    if text is None:
        return None
    previous = None
    while previous != text:
        previous, text = text, html.unescape(text)
    return text.strip()


def g(obj, *path, default=None):
    for key in path:
        if not isinstance(obj, dict):
            return default
        obj = obj.get(key)
    return default if obj is None else obj


def normalize(tcin, raw, positions):
    item = raw.get("item", {})
    enrichment = item.get("enrichment", {})
    images = enrichment.get("images", {})
    price = raw.get("price", {})
    fulfillment = raw.get("fulfillment", {})
    store_option = (fulfillment.get("store_options") or [{}])[0]

    # store_positions repeats the same spot once per response; keep each spot once.
    locations, seen = [], set()
    for pos in positions:
        block = str(pos.get("block") or "").strip()
        number = pos.get("aisle")
        if not block or number is None:
            continue
        aisle = f"{block}{number}"
        key = (aisle, pos.get("floor"))
        if key not in seen:
            seen.add(key)
            locations.append({"aisle": aisle, "floor": pos.get("floor")})

    return {
        "tcin": tcin,
        "title": clean(g(item, "product_description", "title")),
        "parentTitle": clean(g(raw, "parent", "item", "product_description", "title")),
        "itemType": g(item, "product_classification", "item_type", "name"),
        "itemTypeId": g(item, "product_classification", "item_type", "type"),
        "buyURL": enrichment.get("buy_url"),
        "primaryImageURL": images.get("primary_image_url") or g(enrichment, "image_info", "primary_image", "url"),
        "alternateImageURLs": images.get("alternate_image_urls", []),
        "imageAltText": clean(g(enrichment, "image_info", "primary_image", "alt_text")),
        "currentPrice": price.get("current_retail"),
        "regularPrice": price.get("reg_retail"),
        "formattedPrice": price.get("formatted_current_price"),
        "unitPrice": price.get("formatted_unit_price"),
        "unitPriceSuffix": price.get("formatted_unit_price_suffix"),
        "quantityAvailable": store_option.get("location_available_to_promise_quantity"),
        "soldOut": fulfillment.get("sold_out"),
        "locations": locations,
    }


def extract(har_paths):
    merged, positions = {}, {}
    for path in har_paths:
        har = json.loads(Path(path).read_text(encoding="utf-8"))
        for entry in har["log"]["entries"]:
            data = response_json(entry)
            if data is None:
                continue
            for node in iter_product_nodes(data):
                tcin = str(node["tcin"])
                positions.setdefault(tcin, []).extend(node.get("store_positions") or [])
                deep_merge(merged.setdefault(tcin, {}), json.loads(json.dumps(node)))

    products = [normalize(tcin, raw, positions[tcin]) for tcin, raw in merged.items()]
    products.sort(key=lambda p: (p["title"] or "").lower())
    return products


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("har", nargs="+", help="HAR files to read")
    parser.add_argument("-o", "--output", default="output/products.json")
    parser.add_argument("--include-unlocated", action="store_true",
                        help="keep products with no aisle/block (out of stock, discontinued, not sold in store)")
    args = parser.parse_args()

    products = extract(args.har)
    skipped = 0
    if not args.include_unlocated:
        located = [p for p in products if p["locations"]]
        skipped = len(products) - len(located)
        products = located

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({
        "generatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "sources": [Path(p).name for p in args.har],
        "productCount": len(products),
        "products": products,
    }, indent=2, ensure_ascii=False), encoding="utf-8")

    located = sum(1 for p in products if p["locations"])
    print(f"Wrote {len(products)} products ({located} with aisle/block, {skipped} without skipped) to {out}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
