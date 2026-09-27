#!/usr/bin/env python3
"""Summarize baseline-trials.csv exported from the ItemRecognition demo. Standard library only."""
import csv
import sys
from collections import Counter, defaultdict
from statistics import median


def rate(hits, total):
    return f"{hits}/{total} ({100 * hits / total:.0f}%)" if total else "0/0"


def main(path):
    with open(path, newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        print("No trials.")
        return
    targets = [r for r in rows if r["kind"] == "target"]
    others = [r for r in rows if r["kind"] != "target"]

    setups = Counter((r["device"], r["path"], r["coverage_threshold"], r["produce_threshold"]) for r in rows)
    print(f"{len(rows)} trials from {path}")
    for (device, route, coverage, produce), count in sorted(setups.items()):
        print(f"  {count} on {device} · {route} · coverage {coverage} · produce {produce}")

    print("\nCorrect by kind")
    for kind in ("target", "lookalike", "negative"):
        group = [r for r in rows if r["kind"] == kind]
        print(f"  {kind:<10} {rate(sum(r['correct'] == 'yes' for r in group), len(group))}")

    print("\nTarget trials by item")
    by_item = defaultdict(list)
    for r in targets:
        by_item[r["target_title"]].append(r)
    for title, group in sorted(by_item.items()):
        waits = [float(r["seconds_to_first_ask"]) for r in group if r["seconds_to_first_ask"]]
        failed = [r["blocker"] for r in group if r["correct"] != "yes" and r["blocker"]]
        blocker = Counter(failed).most_common(1)[0][0] if failed else "-"
        wait = f"{median(waits):.1f}s" if waits else "-"
        print(f"  {title[:48]:<48} {rate(sum(r['correct'] == 'yes' for r in group), len(group)):<12}"
              f" ask {wait:<6} failures stop at: {blocker}")

    print("\nFalse asks (lookalike/negative trials that were asked)")
    asked = [r for r in others if r["asks"] not in ("", "0")]
    for r in asked:
        print(f"  target {r['target_title'][:32]:<32} shown {r['shown'][:28]:<28} level {r['asked_level'] or '-'}")
    if not asked:
        print("  none")

    print("\nWhere failed target trials stopped")
    failed = [r for r in targets if r["correct"] != "yes"]
    for stage, count in Counter(r["blocker"] or "-" for r in failed).most_common():
        print(f"  {stage:<20} {count}")
    reasons = Counter()
    for r in failed:
        for part in filter(None, (p.strip() for p in r["top_reasons"].split(";"))):
            reason, _, frames = part.rpartition(" ")
            reasons[reason] += int(frames) if frames.isdigit() else 0
    for reason, frames in reasons.most_common(8):
        print(f"    {reason:<36} {frames} frames")
    neighbors = Counter(r["leading_neighbor"] for r in failed if r["leading_neighbor"])
    for name, count in neighbors.most_common(5):
        print(f"    neighbor led: {name[:44]} ({count} trials)")

    print("\nTarget success by condition")
    for column in ("place", "light", "distance", "motion"):
        groups = defaultdict(list)
        for r in targets:
            groups[r[column]].append(r["correct"] == "yes")
        cells = ", ".join(f"{value} {rate(sum(hits), len(hits))}" for value, hits in sorted(groups.items()))
        print(f"  {column:<9} {cells}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: summarize.py <baseline-trials.csv>")
    main(sys.argv[1])
