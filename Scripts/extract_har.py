#!/usr/bin/env python3
"""Extract Target (Redsky API) product data from HAR captures into a JSON
file that the SwiftData importer (SwiftData/ProductImporter.swift) can load.

Usage:
    python3 extract_har.py milk.har others.har -o output/products.json

Products are merged by TCIN across every response in every HAR, because
different endpoints carry different fields: recommendations have images and
ratings, product_summary_with_fulfillment has aisle/block and stock info.
Only the Python standard library is used.
"""

import argparse
import base64
import html
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qs, urlparse


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


def search_term_from(entry):
    headers = {h["name"].lower(): h["value"] for h in entry["request"].get("headers", [])}
    referer = headers.get("referer", "")
    terms = parse_qs(urlparse(referer).query).get("searchTerm")
    return terms[0].strip().lower() if terms else None


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


def normalize(tcin, raw, meta):
    item = raw.get("item", {})
    price = raw.get("price", {})
    enrichment = item.get("enrichment", {})
    images = enrichment.get("images", {})
    rating = g(raw, "ratings_and_reviews", "statistics", "rating", default={})
    fulfillment = raw.get("fulfillment", {})
    store_option = (fulfillment.get("store_options") or [{}])[0]

    locations, seen = [], set()
    for pos in meta["positions"]:
        key = (pos.get("aisle"), pos.get("block"), pos.get("floor"))
        if key not in seen:
            seen.add(key)
            locations.append({"aisle": pos.get("aisle"), "block": pos.get("block"), "floor": pos.get("floor")})

    return {
        "tcin": tcin,
        "title": clean(g(item, "product_description", "title")),
        "itemType": g(item, "product_classification", "item_type", "name"),
        "itemTypeId": g(item, "product_classification", "item_type", "type"),
        "departmentId": g(item, "merchandise_classification", "department_id"),
        "classId": g(item, "merchandise_classification", "class_id"),
        "parentTcin": g(raw, "parent", "tcin"),
        "buyURL": enrichment.get("buy_url"),
        "primaryImageURL": images.get("primary_image_url") or g(enrichment, "image_info", "primary_image", "url"),
        "alternateImageURLs": images.get("alternate_image_urls", []),
        "imageAltText": clean(g(enrichment, "image_info", "primary_image", "alt_text")),

        "currentPrice": price.get("current_retail"),
        "regularPrice": price.get("reg_retail"),
        "formattedPrice": price.get("formatted_current_price"),
        "priceType": price.get("formatted_current_price_type"),
        "formattedComparisonPrice": price.get("formatted_comparison_price"),
        "unitPrice": price.get("formatted_unit_price"),
        "unitPriceSuffix": price.get("formatted_unit_price_suffix"),
        "saveDollar": price.get("save_dollar"),
        "savePercent": price.get("save_percent"),

        "ratingAverage": rating.get("average"),
        "ratingCount": rating.get("count"),
        "ratingBreakdown": [
            {"label": r.get("label") or r.get("id"), "value": r.get("value")}
            for r in rating.get("secondary_averages", [])
        ],
        "badges": sorted({c["display"] for c in raw.get("desirability_cues", []) if c.get("display")}),
        "promotions": sorted({clean(p.get("plp_message") or p.get("pdp_message"))
                              for p in raw.get("promotions", []) if p.get("plp_message") or p.get("pdp_message")}),

        "storeId": store_option.get("location_id") or (str(price["location_id"]) if price.get("location_id") else None),
        "storeName": g(store_option, "store", "location_name"),
        "inStoreStatus": g(store_option, "in_store_only", "availability_status"),
        "pickupStatus": g(store_option, "order_pickup", "availability_status"),
        "shippingStatus": g(fulfillment, "shipping_options", "availability_status"),
        "deliveryStatus": g(fulfillment, "scheduled_delivery", "availability_status"),
        "quantityAvailable": store_option.get("location_available_to_promise_quantity"),
        "soldOut": fulfillment.get("sold_out"),

        "locations": locations,
        "searchTerms": sorted(meta["searchTerms"]),
        "categories": sorted(meta["categories"]),
        "sourceFiles": sorted(meta["sourceFiles"]),
        "raw": raw,
    }


def extract(har_paths):
    merged, meta = {}, {}
    for path in har_paths:
        har = json.loads(Path(path).read_text(encoding="utf-8"))
        for entry in har["log"]["entries"]:
            data = response_json(entry)
            if data is None:
                continue
            term = search_term_from(entry)
            # "Deals in Eggs" placements name the Target category for the search.
            description = g(data, "data", "recommended_products", "strategy_description", default="")
            category = description.removeprefix("Deals in ").strip() if description.startswith("Deals in ") else None
            for node in iter_product_nodes(data):
                tcin = str(node["tcin"])
                m = meta.setdefault(tcin, {"positions": [], "searchTerms": set(), "categories": set(), "sourceFiles": set()})
                m["positions"].extend(node.get("store_positions") or [])
                m["sourceFiles"].add(Path(path).name)
                if term:
                    m["searchTerms"].add(term)
                if category:
                    m["categories"].add(category)
                deep_merge(merged.setdefault(tcin, {}), json.loads(json.dumps(node)))

    products = [normalize(tcin, raw, meta[tcin]) for tcin, raw in merged.items()]
    products.sort(key=lambda p: (p["title"] or "").lower())
    return products


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("har", nargs="+", help="HAR files to read")
    parser.add_argument("-o", "--output", default="output/products.json")
    parser.add_argument("--no-raw", action="store_true", help="omit the merged raw API payload per product")
    parser.add_argument("--include-unlocated", action="store_true",
                        help="keep products with no aisle/block (out of stock, discontinued, not sold in store)")
    args = parser.parse_args()

    products = extract(args.har)
    skipped = 0
    if not args.include_unlocated:
        located = [p for p in products if p["locations"]]
        skipped = len(products) - len(located)
        products = located
    if args.no_raw:
        for p in products:
            p.pop("raw")

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
