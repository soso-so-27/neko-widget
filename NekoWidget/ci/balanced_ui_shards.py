"""Explicit UI partitions; class selectors also cover newly added test methods."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from ios_ci_scope import GALLERY_TEST, SCOPES, native_tests

TARGET = "NekoWidgetUITests/"
COMPOSER = TARGET + "MomentDeliveryComposerUITests"
SOLO = TARGET + "SoloMemoriesUITests"
CAT = TARGET + "CatProfilePhotoFlowUITests"
OFFICIAL = TARGET + "OfficialWindowUITests"
APP_CLASSES = frozenset((COMPOSER, SOLO, CAT, OFFICIAL))


def partition(selected: tuple[str, ...]) -> dict[str, list[str]]:
    if not selected or len(selected) != len(set(selected)):
        raise ValueError("Empty or duplicate native UI selection")
    if not set(selected) <= APP_CLASSES | {GALLERY_TEST}:
        raise ValueError("A new UI class requires an explicit shard assignment")
    shards: dict[str, list[str]] = {"a": [], "b": []}
    for test in selected:
        if test == GALLERY_TEST:
            continue  # The three Gallery variants run serially on fresh UDIDs.
        # Balance whole suites by observed duration, not test count. Avoid
        # mixing class-level -only-testing with method-level -skip-testing:
        # Xcode's precedence would make disjoint selection version-dependent.
        shard = "a" if test in (SOLO, OFFICIAL) else "b"
        shards[shard].append("-only-testing:" + test)
    if not any(shards.values()):
        raise ValueError("No app UI tests selected")
    return shards


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scope", required=True, choices=SCOPES)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    selected = native_tests(args.scope)
    shards = partition(selected)
    args.output.mkdir(parents=True, exist_ok=True)
    for shard, arguments in shards.items():
        (args.output / f"shard-{shard}.txt").write_text(
            "".join(argument + "\n" for argument in arguments), encoding="utf-8")
    (args.output / "partition.json").write_text(json.dumps({
        "schemaVersion": 1, "scope": args.scope, "shards": shards,
        "gallerySeparated": GALLERY_TEST in selected,
    }, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
