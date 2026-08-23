#!/usr/bin/env python3
"""Validate Xcode's resolved ordinary Release settings for every shipped target."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


REQUIRED_TARGETS = {
    "NekoWidget": "NekoWidget/Info.plist",
    "NekoWidgetWidgetExtension": "NekoWidgetWidget/Info.plist",
    "NekoWidgetShareExtension": "NekoWidgetShareExtension/Info.Disabled.plist",
}
ALL_OFF_SETTINGS = {
    "SHARING_RELEASE_MODE": "disabled",
    "SHARING_FEATURE_ENABLED": "NO",
    "SHARING_MEDIA_ENABLED": "NO",
    "SHARING_SHARE_EXTENSION_HANDOFF_ENABLED": "NO",
    "SHARING_SHARE_EXTENSION_SEND_ENABLED": "NO",
    "SHARING_REVIEW_PREVIEW_ENABLED": "NO",
}
EMPTY_NETWORK_SETTINGS = (
    "SHARING_API_BASE_URL",
    "SHARING_MODERATION_KEY_ID",
    "SHARING_MODERATION_PUBLIC_KEY",
    "SHARING_PRIVACY_URL",
    "SHARING_SUPPORT_URL",
    "SHARING_COMMUNITY_STANDARDS_URL",
)
APP_POLICY_SETTINGS = {
    "APP_PRIVACY_URL": "https://soso-so-27.github.io/neko-widget/app/privacy/",
    "APP_SUPPORT_URL": "https://soso-so-27.github.io/neko-widget/app/support/",
}
LOCAL_PHOTO_DESCRIPTION_TERMS = ("猫", "端末内", "アルバム", "ウィジェット")
LOCAL_PHOTO_DESCRIPTION_FORBIDDEN_TERMS = (
    "共有",
    "招待",
    "相手",
    "受信",
    "履歴",
    "送信",
    "届け",
    "サーバー",
)


def normalized_path(value: object) -> str:
    return str(value or "").replace("\\", "/").strip('"')


def validate(payload: object) -> list[str]:
    failures: list[str] = []
    if not isinstance(payload, list):
        return ["xcodebuild -showBuildSettings -json did not return an array."]

    by_target: dict[str, dict] = {}
    duplicates: set[str] = set()
    for item in payload:
        if not isinstance(item, dict):
            failures.append("Resolved build-settings array contains a malformed entry.")
            continue
        target = item.get("target")
        settings = item.get("buildSettings")
        if not isinstance(target, str) or not isinstance(settings, dict):
            failures.append("Resolved build-settings entry has no target/settings dictionary.")
            continue
        if target in by_target:
            duplicates.add(target)
        by_target[target] = settings

    for target in sorted(duplicates):
        failures.append(f"Resolved build settings contain duplicate target {target}.")

    for target, expected_info_plist in REQUIRED_TARGETS.items():
        settings = by_target.get(target)
        if settings is None:
            failures.append(f"Resolved Release settings are missing target {target}.")
            continue
        if settings.get("CONFIGURATION") != "Release":
            failures.append(f"{target} did not resolve CONFIGURATION=Release.")
        for key, expected in ALL_OFF_SETTINGS.items():
            if settings.get(key) != expected:
                failures.append(f"{target} must resolve {key}={expected}.")
        for key in EMPTY_NETWORK_SETTINGS:
            if str(settings.get(key, "")).strip():
                failures.append(f"{target} must resolve an empty {key}.")
        for key, expected in APP_POLICY_SETTINGS.items():
            if settings.get(key) != expected:
                failures.append(f"{target} must resolve {key}={expected}.")

        actual_info_plist = normalized_path(settings.get("INFOPLIST_FILE"))
        if actual_info_plist != expected_info_plist:
            failures.append(
                f"{target} must resolve INFOPLIST_FILE={expected_info_plist}, "
                f"got {actual_info_plist or 'empty'}."
            )
        if normalized_path(settings.get("SHARE_EXTENSION_INFOPLIST_FILE")) != (
            "NekoWidgetShareExtension/Info.Disabled.plist"
        ):
            failures.append(
                f"{target} must resolve the disabled Share Extension plist."
            )

        description = settings.get("PHOTO_LIBRARY_USAGE_DESCRIPTION")
        if not isinstance(description, str):
            failures.append(
                f"{target} has no resolved PHOTO_LIBRARY_USAGE_DESCRIPTION."
            )
        else:
            missing = [
                term for term in LOCAL_PHOTO_DESCRIPTION_TERMS if term not in description
            ]
            forbidden = [
                term
                for term in LOCAL_PHOTO_DESCRIPTION_FORBIDDEN_TERMS
                if term in description
            ]
            if missing:
                failures.append(
                    f"{target} local photo purpose is missing: {', '.join(missing)}."
                )
            if forbidden:
                failures.append(
                    f"{target} local photo purpose contains sharing terms: "
                    f"{', '.join(forbidden)}."
                )

    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("settings_json", type=Path, nargs="+")
    args = parser.parse_args()

    payload: list[object] = []
    for path in args.settings_json:
        try:
            resolved = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            print(
                f"disabled Release settings: FAIL: {path.name}: {error}",
                file=sys.stderr,
            )
            return 1
        if not isinstance(resolved, list):
            print(
                "disabled Release settings: FAIL: "
                f"{path.name}: xcodebuild output is not an array.",
                file=sys.stderr,
            )
            return 1
        payload.extend(resolved)

    failures = validate(payload)
    if failures:
        print("disabled Release settings: FAIL", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print("disabled Release settings: PASS (app, Widget, Share Extension all off)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
