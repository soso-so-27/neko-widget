#!/usr/bin/env python3
"""Validate resolved public build inputs; never deploy or accept staging values."""
import argparse
import base64
import importlib.util
import json
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
FLAGS = {
    "OWNER_INTERNAL_REPORTS_DISABLED": "NO",
    "SHARING_FEATURE_ENABLED": "YES", "SHARING_MEDIA_ENABLED": "YES", "GROUP_WINDOWS_ENABLED": "YES",
    "FAMILY_NOTEBOOK_PRODUCTION_ENABLED": "YES", "GROUP_REPORTING_PRODUCTION_ENABLED": "YES",
    "SHARING_REVIEW_PREVIEW_ENABLED": "NO", "SHARING_SHARE_EXTENSION_SEND_ENABLED": "NO",
    "MANAGED_PRESERVATION_ENABLED": "YES", "PLUS_STOREFRONT_ENABLED": "YES",
    "PLUS_BILLING_CLIENT_ENABLED": "YES", "PLUS_BILLING_RECOVERY_ENABLED": "YES",
    "MEMBERSHIP_ACCESS_ENFORCED": "YES", "PERSONAL_ARCHIVE_READ_ONLY": "YES",
}
URLS = ["SHARING_API_BASE_URL", "PLUS_BILLING_API_BASE_URL", "MANAGED_PRESERVATION_ORIGIN",
        "APP_PRIVACY_URL", "APP_SUPPORT_URL", "SHARING_PRIVACY_URL", "SHARING_SUPPORT_URL",
        "SHARING_COMMUNITY_STANDARDS_URL", "OFFICIAL_WINDOW_FEED_URL"]


def verify(settings, *, allow_unconfigured=False):
    assert settings.get("SHARING_RELEASE_MODE") == "production", "production mode required"
    assert "DEBUG" not in settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split(), "Debug is not a public build"
    assert settings.get("APP_PRIVACY_MANIFEST_PATH") == "Production/PrivacyInfo.xcprivacy", "production privacy manifest required"
    for name, expected in FLAGS.items():
        assert settings.get(name) == expected, name
    for name in URLS:
        value = settings.get(name, "")
        if not value and allow_unconfigured:
            continue
        parsed = urlsplit(value)
        assert parsed.scheme == "https" and parsed.hostname and "." in parsed.hostname, name
        assert not parsed.username and not parsed.password and not parsed.fragment and not parsed.query, name
        assert not any(word in parsed.hostname.lower() for word in ("staging", "localhost", "example", ".invalid")), name
        assert "$(" not in value, name
    assert settings.get("PLUS_BILLING_API_BASE_URL", "").rstrip("/") == settings.get("SHARING_API_BASE_URL", "").rstrip("/"), "billing/group credential origins differ"
    audience = settings.get("MANAGED_PRESERVATION_MEMBERSHIP_AUDIENCE", "")
    assert (allow_unconfigured and not audience) or (8 <= len(audience) <= 128 and "staging" not in audience.lower()), "production audience required"
    key = settings.get("SHARING_MODERATION_PUBLIC_KEY", "")
    if not key and allow_unconfigured:
        return
    assert settings.get("SHARING_MODERATION_KEY_ID") == "moderation-v2", "reviewed key ID required"
    assert key != "T5C7__1xlc4XmIDr6zTJqMtdhBjPnMD10O3vFK_bYWg", "staging evidence recipient rejected"
    raw = base64.urlsafe_b64decode(key + "=" * (-len(key) % 4))
    assert len(raw) == 32 and base64.urlsafe_b64encode(raw).decode().rstrip("=") == key, "canonical recipient key required"
    spec = importlib.util.spec_from_file_location("sharing_release", ROOT / "ci/validate-sharing-release.py")
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    assert not module.is_x25519_small_order_public_key(raw), "invalid recipient key"


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("settings", type=Path, help="xcodebuild -showBuildSettings -json output")
    parser.add_argument("--allow-unconfigured", action="store_true", help="configuration preparation only, not a release approval")
    args = parser.parse_args()
    rows = json.loads(args.settings.read_text(encoding="utf-8"))
    for row in rows:
        verify(row["buildSettings"], allow_unconfigured=args.allow_unconfigured)
    print("PASS production build settings" + (" (unconfigured template; NOT releasable)" if args.allow_unconfigured else ""))
