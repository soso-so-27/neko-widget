#!/usr/bin/env python3
"""Fixed Build 309 suspension diagnosis; no raw incident or symbols are uploaded.

Reuse the existing authenticated extraction, bounded DWARF/UUID inspection,
atos invocation, sanitized output and temporary cleanup without weakening 185.
Only the fixed release pins and app-image offsets differ. This module accepts
no caller-selected release, address, UUID or authentication policy.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path


CI = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("fixed_release_symbols", CI / "resolve-build185-symbols.py")
assert spec is not None and spec.loader is not None
diagnostic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostic)

# Configure an isolated imported module, never modify the original script.
diagnostic.RUN_ID = 40617594163
diagnostic.ARTIFACT_ID = 12785689014
diagnostic.SOURCE_COMMIT = "a0f2f20024c04bb0dc5c55e47606293f1110b06b"
diagnostic.APP_UUID = "0d6ef844-390b-3ca3-9653-bacf9d151bce"

# A/B follow the order of the supplied raw reports. The OS marked main as the
# triggered thread for SIGKILL; these cooperative snapshots are not proof of
# which lock was held. Use symbols plus lock ownership analysis to determine it.
# Only offsets and frame indices are retained; no runtime ASLR/device/incident.
diagnostic.CRASH_FRAMES = {
    "A.cooperative": (
        (39, 0x225E30), (40, 0x22E7F4), (41, 0x68B084),
        (42, 0xE5B5A0), (43, 0xE5B620), (44, 0xEF94C4),
        (45, 0x67108C), (46, 0x6F21E1), (47, 0x6F10A5),
        (48, 0x0A7E31), (49, 0x6F3559), (50, 0x0A7E31),
        (51, 0x2FAA7D), (52, 0x0A7E31),
    ),
    "B.cooperative": (
        (5, 0x226364), (6, 0x22AD30), (7, 0x68B148),
        (8, 0xE5B5A0), (9, 0xE5B620), (10, 0xEF94C4),
        (11, 0x673614), (12, 0x6F21E1), (13, 0x6F10A5),
        (14, 0x0A7E31), (15, 0x6F3559), (16, 0x0A7E31),
        (17, 0x2FAA7D), (18, 0x0A7E31),
    ),
    "A.main": (
        (1, 0x1BE334), (2, 0x09FBCC), (3, 0x1C4EF0),
        (4, 0x2C8124), (5, 0x2D052C), (6, 0x2C2B6C),
        (7, 0x2C1C38), (8, 0x2BFEF4), (35, 0x2F9100),
    ),
    "B.main": ((12, 0x2F9100),),
}


def validate_release(metadata: dict) -> None:
    expected = {
        "schema": "jp.nekowidget.moderation-release-metadata.v3",
        "sourceCommit": diagnostic.SOURCE_COMMIT, "buildNumber": "309",
        "githubRunId": str(diagnostic.RUN_ID), "githubRunAttempt": 1,
        "releaseEnvironment": "testflight", "releaseMode": "media-staging",
        "archiveDigestAlgorithm": "sha256-tree-v2",
        "archiveSha256": "e8c96285ebb2a63e056acb44fa994a5cafe28498a50b72bedaa14925ca4ff348",
    }
    diagnostic.require(all(metadata.get(key) == value for key, value in expected.items()),
                       "Authenticated metadata is not the fixed Build 309 release.")


diagnostic.validate_release = validate_release

# atos may succeed with no text for an optimized async continuation. Keep that
# frame explicitly unresolved; do not discard the other exact-address results.
# Nonempty output still uses the existing size and privacy validation.
validated_symbol_lines = diagnostic.symbol_lines


def symbol_lines(output: str) -> list[str]:
    if not output.strip():
        return ["[unresolved optimized frame: atos returned no text]"]
    if len(output.strip().splitlines()) > 64:
        return ["[unresolved frame: atos exceeded the inline-symbol limit]"]
    return validated_symbol_lines(output)


diagnostic.symbol_lines = symbol_lines

if __name__ == "__main__":
    raise SystemExit(diagnostic.main())
