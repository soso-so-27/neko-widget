"""Explicit app UI selection; shared runtime and release checks are never reduced."""

from __future__ import annotations

import argparse
import difflib
import json
import os
from pathlib import Path
import re


FULL_SCOPE = "full-v1"
PHOTO_SCOPE = "photo-ui-v1"
OFFICIAL_SCOPE = "official-ui-v1"
COMBINED_SCOPE = "photo-official-ui-v1"
SCOPES = (FULL_SCOPE, PHOTO_SCOPE, OFFICIAL_SCOPE, COMBINED_SCOPE)
SHARING_JOB_PREFIX = "Sharing runtime self-test (iOS 18.5 / 26.2)"

# FamilyWindowView contains shared detail/zoom and settings; PairingView and
# SettingsView also own permission/security actions. They intentionally remain
# full. New files, helpers and test/fixture changes need a fresh mapping review.
PHOTO_VIEWS = frozenset("NekoWidget/NekoWidget/Views/" + name for name in (
    "HomeView.swift", "LikedPhotosView.swift", "MonthlyWindowView.swift",
    "PhotoAssetImageView.swift", "CatProfilesView.swift",
    "CatProfilePhotoCurationViews.swift",
))
OFFICIAL_VIEW = "NekoWidget/NekoWidget/Views/OfficialWindowView.swift"
MAPPED_VIEWS = PHOTO_VIEWS | {OFFICIAL_VIEW}

PHOTO_TESTS = (
    "NekoWidgetUITests/MomentDeliveryComposerUITests",
    "NekoWidgetUITests/CatProfilePhotoFlowUITests",
    "NekoWidgetUITests/SoloMemoriesUITests",
)
OFFICIAL_TESTS = ("NekoWidgetUITests/OfficialWindowUITests",)
GALLERY_TEST = (
    "NekoWidgetUITests/WidgetPlacementScreenshotUITests/"
    "testCaptureSharedWidgetAllSupportedSizes"
)


def sharing_job(scope: str) -> str:
    if scope not in SCOPES:
        raise ValueError("Unknown iOS runtime scope")
    return f"{SHARING_JOB_PREFIX} [scope {scope}]"


def native_tests(scope: str) -> tuple[str, ...]:
    if scope == PHOTO_SCOPE:
        return PHOTO_TESTS
    if scope == OFFICIAL_SCOPE:
        return OFFICIAL_TESTS
    if scope == COMBINED_SCOPE:
        return PHOTO_TESTS + OFFICIAL_TESTS
    if scope == FULL_SCOPE:
        return PHOTO_TESTS + OFFICIAL_TESTS + (GALLERY_TEST,)
    raise ValueError("Unknown iOS runtime scope")


def conditional_blocks(source: str) -> tuple[str, ...] | None:
    """Protect complete conditional blocks, including inline DEBUG fixtures.

    Treat every #if, not only DEBUG, as protected. This is a line-level guard,
    not a Swift parser; malformed/nested-unbalanced directives fail closed.
    """
    blocks: list[str] = []
    current: list[str] = []
    depth = 0
    for line in source.splitlines(keepends=True):
        directive = re.match(r"\s*#(if|elseif|else|endif)\b", line)
        word = directive.group(1) if directive else None
        if word == "if":
            depth += 1
        elif word in ("elseif", "else", "endif") and depth == 0:
            return None
        if depth:
            current.append(line)
        if word == "endif":
            depth -= 1
            if depth == 0:
                blocks.append("".join(current))
                current = []
    return tuple(blocks) if depth == 0 else None


SENSITIVE = re.compile(
    r"authorization|permission|entitlement|consent|privacy|"
    r"requestAccess|requestAuthorization|PHPhotoLibrary|"
    r"UNUserNotificationCenter|SensitiveContentAnalysis|"
    r"fixture|--[a-z][a-z-]+",
    re.IGNORECASE,
)


NUMBER = r"(?:0|[1-9]\d*)(?:\.\d+)?"
WEIGHT = r"\.(?:ultraLight|thin|light|regular|medium|semibold|bold|heavy|black)"
FONT = r"\.(?:largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption2?)"
ALIGNMENT = r"\.(?:leading|center|trailing|top|bottom|topLeading|topTrailing|bottomLeading|bottomTrailing)"
COLOR = r"(?:Color)?\.(?:primary|secondary|tertiary|tint|accentColor|red|orange|green|blue|white|black|clear)"
FRAME_ARGUMENT = rf"(?:(?:width|height|minWidth|minHeight|idealWidth|idealHeight|maxWidth|maxHeight):\s*(?:{NUMBER}|\.infinity)|alignment:\s*{ALIGNMENT})"
PURE_MODIFIERS = (
    rf"\.font\({FONT}(?:\.(?:bold\(\)|italic\(\)|weight\({WEIGHT}\)))?\)",
    rf"\.font\(\.system\(size:\s*{NUMBER}(?:,\s*weight:\s*{WEIGHT})?(?:,\s*design:\s*\.(?:default|rounded|serif|monospaced))?\)\)",
    rf"\.fontWeight\({WEIGHT}\)",
    rf"\.padding\((?:{NUMBER}|\.(?:all|horizontal|vertical|top|bottom|leading|trailing)(?:,\s*{NUMBER})?)?\)",
    rf"\.frame\({FRAME_ARGUMENT}(?:,\s*{FRAME_ARGUMENT})*\)",
    rf"\.(?:foregroundStyle|foregroundColor)\({COLOR}\)",
    rf"\.(?:lineSpacing|kerning|tracking)\({NUMBER}\)",
    r"\.multilineTextAlignment\(\.(?:leading|center|trailing)\)",
)
MODIFIER = "(?:" + "|".join(PURE_MODIFIERS) + ")"
# No interpolation, raw/multiline literal or arbitrary expression. Modifiers
# may be chained to Text or placed on their own line in an existing chain.
TEXT = r'Text\("(?:[^"\\]|\\["\\nrt0])*"\)'
PURE_PRESENTATION_LINE = re.compile(rf"(?:{TEXT}(?:\s*{MODIFIER})*|{MODIFIER}(?:\s*{MODIFIER})*)")


def pure_presentation_line(line: str) -> bool:
    return not line.strip() or PURE_PRESENTATION_LINE.fullmatch(line.strip()) is not None


def select_scope(changes: dict[str, tuple[str, str]] | None) -> str:
    # Callers must first prove existing regular files, modification-only and
    # unchanged modes. No docs/unknown path exception is applied to UI scope.
    if not changes or not set(changes) <= MAPPED_VIEWS:
        return FULL_SCOPE
    for before, after in changes.values():
        # This first tier does not parse Swift. Ambiguous string contexts are
        # full, as are structures, control flow, actions, helper calls, state,
        # accessibility identifiers and every other unlisted changed line.
        if any('"""' in text or re.search(r'#+"', text) for text in (before, after)):
            return FULL_SCOPE
        protected = conditional_blocks(before)
        if protected is None or protected != conditional_blocks(after):
            return FULL_SCOPE
        old, new = before.splitlines(), after.splitlines()
        for kind, i, j, x, y in difflib.SequenceMatcher(None, old, new, autojunk=False).get_opcodes():
            if kind != "equal":
                lines = old[i:j] + new[x:y]
                if any(SENSITIVE.search(line) or not pure_presentation_line(line) for line in lines):
                    return FULL_SCOPE
    has_photo = bool(set(changes) & PHOTO_VIEWS)
    has_official = OFFICIAL_VIEW in changes
    if has_photo and has_official:
        return COMBINED_SCOPE
    return PHOTO_SCOPE if has_photo else OFFICIAL_SCOPE


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scope", choices=SCOPES, required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--tests", type=Path, required=True)
    args = parser.parse_args()
    tests = native_tests(args.scope)
    args.metadata.write_text(json.dumps({
        "schemaVersion": 1,
        "scope": args.scope,
        "commit": os.environ.get("GITHUB_SHA"),
        "sharingRuntime": ["ios-18-5", "ios-26-2"],
        "nativeTests": tests,
        "widgetGallery": args.scope == FULL_SCOPE,
    }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    args.tests.write_text("".join(f"-only-testing:{test}\n" for test in tests), encoding="utf-8")


if __name__ == "__main__":
    main()
