#!/usr/bin/env python3
"""Bind an optional, fixed official preview feed to media-staging archives only.

Raw workflow input is read from env, never interpolated into shell code. No URL
is fetched. The archive pass checks the processed App and Widget Info.plists,
including the empty value required for disabled/App Store candidate builds.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import sys


PREVIEW_FEED_URL = "https://neko-widget-official-cats-preview.nakanishisoya.workers.dev/catalog.json"
RELEASE_MODES = {"disabled", "review-preview", "pairing-only", "media-staging"}


def validated_url(mode: str, url: str) -> str:
    if mode not in RELEASE_MODES:
        raise ValueError("Unknown or missing release mode for official window feed")
    if not isinstance(url, str) or url not in {"", PREVIEW_FEED_URL}:
        raise ValueError("Official window feed must be empty or the exact approved preview URL")
    if url and mode != "media-staging":
        raise ValueError("Official window feed is permitted only in media-staging")
    return url


def validate_archive(app: dict, widget: dict, mode: str, expected_url: str) -> None:
    expected_url = validated_url(mode, expected_url)
    for label, info in (("App", app), ("Widget", widget)):
        if not isinstance(info, dict):
            raise ValueError(f"{label} Info.plist must be a dictionary")
        if info.get("SharingReleaseMode") != mode:
            raise ValueError(f"{label} archive release mode does not match the selected mode")
        # A missing/non-string key or unresolved build-setting placeholder must
        # not silently count as disabled. Both targets must contain the value.
        if info.get("OfficialWindowFeedURL") != expected_url:
            raise ValueError(f"{label} archive official window feed does not match the selected URL")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    subcommands.add_parser("input", help="validate dispatch env and export the fixed build value")
    archive = subcommands.add_parser("archive", help="validate both processed archive plists")
    archive.add_argument("--app-info-plist", required=True, type=Path)
    archive.add_argument("--widget-info-plist", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "input":
            value = validated_url(
                os.environ["SELECTED_RELEASE_MODE"],
                os.environ.get("SELECTED_OFFICIAL_WINDOW_FEED_URL", ""),
            )
            # The allowlist guarantees a single safe assignment, including the
            # explicitly empty override for every non-preview release.
            with Path(os.environ["GITHUB_ENV"]).open("a", encoding="utf-8") as handle:
                handle.write(f"RELEASE_OFFICIAL_WINDOW_FEED_URL={value}\n")
        else:
            mode = os.environ["SHARING_EXPECTED_MODE"]
            expected_url = os.environ["RELEASE_OFFICIAL_WINDOW_FEED_URL"]
            with args.app_info_plist.open("rb") as handle:
                app = plistlib.load(handle)
            with args.widget_info_plist.open("rb") as handle:
                widget = plistlib.load(handle)
            validate_archive(app, widget, mode, expected_url)
    except (KeyError, OSError, ValueError, plistlib.InvalidFileException) as error:
        # Never echo an unapproved raw URL or env payload to workflow logs.
        message = str(error) if isinstance(error, ValueError) and not isinstance(
            error, plistlib.InvalidFileException
        ) else "Required release environment or archive plist is missing/invalid"
        print(f"Official window release validation failed: {message}", file=sys.stderr)
        return 1
    print(f"Official window {args.command} validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
