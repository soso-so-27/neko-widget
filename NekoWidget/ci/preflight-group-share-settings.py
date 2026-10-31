"""Check source plists against resolved build settings before compilation.

This checks configuration, not signing. An unsigned simulator may not resolve
AppIdentifierPrefix; compare its exact source binding before using a labelled
placeholder. The finished-product and signed-entitlement checks remain required.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("sharing_release", ROOT / "ci/validate-sharing-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
import distribution_profile as owner

TARGETS = ("NekoWidget", "NekoWidgetShareExtension", "NekoWidgetWidgetExtension")
SCOPE = "$(AppIdentifierPrefix)$(APP_BUNDLE_IDENTIFIER).group-share"


def expand(value, settings):
    if not isinstance(value, str):
        return value
    for _ in range(20):
        expanded = re.sub(r"\$\(([^)]+)\)|\$\{([^}]+)\}",
                          lambda match: str(settings.get(match[1] or match[2], "")), value)
        if expanded == value:
            return value
        value = expanded
    raise ValueError("Recursive build setting")


def verify(rows, owner_internal=False):
    targets = {row["target"]: row["buildSettings"] for row in rows}
    if not all(target in targets for target in TARGETS):
        raise ValueError("App, Share Extension and Widget build settings are required")
    infos = []
    for target in TARGETS:
        settings = dict(targets[target])
        source = Path(settings["INFOPLIST_FILE"])
        if not source.is_absolute():
            source = ROOT / source
        raw = plistlib.loads(source.read_bytes())
        if target != TARGETS[2] and raw.get("GroupShareKeychainGroup") != SCOPE:
            raise ValueError("Source Keychain group binding changed: " + target)
        settings.setdefault("AppIdentifierPrefix", "UNSIGNED_CONFIGURATION_ONLY.")
        info = {key: expand(value, settings) for key, value in raw.items()
                if key.startswith(("Sharing", "Group", "OwnerInternal"))}
        infos.append(info)
    failures = []
    release.validate_share_extension_boundary(infos[0], infos[1], failures)
    if any(key.startswith("GroupShare") for key in infos[2]):
        failures.append("Widget must have no Group Share configuration")
    if failures:
        raise ValueError("; ".join(failures))
    if owner_internal:
        owner.verify_products(dict(zip(owner.PLISTS, infos)))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("settings", type=Path, nargs="+")
    parser.add_argument("--owner-internal", action="store_true")
    args = parser.parse_args()
    verify([row for path in args.settings for row in json.loads(path.read_text())], args.owner_internal)
    print("PASS source photo/report configuration before compilation (not signing verification)")
