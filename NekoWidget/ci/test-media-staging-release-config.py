#!/usr/bin/env python3
"""Static fail-closed checks for the two-device media-staging release mode."""

from __future__ import annotations

import base64
import hashlib
import json
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = ROOT.parent
BASE_CONFIG = ROOT / "Config.xcconfig"
PAIRING_CONFIG = ROOT / "Config.PairingOnly.xcconfig"
MEDIA_CONFIG = ROOT / "Config.MediaStaging.xcconfig"
MEDIA_PRIVACY = ROOT / "ci" / "PrivacyInfo.MediaStaging.xcprivacy"
WORKFLOW = REPOSITORY / ".github/workflows/testflight.yml"
ROLLOUT_POLICY = ROOT / "ci/moderation-client-rollout-policy.json"
METADATA_WRITER = ROOT / "ci/write-moderation-release-metadata.py"

USER_ID = "NSPrivacyCollectedDataTypeUserID"
PHOTOS = "NSPrivacyCollectedDataTypePhotosorVideos"
DEVICE_ID = "NSPrivacyCollectedDataTypeDeviceID"
PRODUCT_INTERACTION = "NSPrivacyCollectedDataTypeProductInteraction"
APP_FUNCTIONALITY = "NSPrivacyCollectedDataTypePurposeAppFunctionality"
MODERATION_PUBLIC_KEY = "hSDwCYkwp1R0i33ctD73Wg2_Og0mOBr066SpjqqbTmo"
MEDIA_ORIGIN = "https://neko-window-sharing-staging.nakanishisoya.workers.dev"
MEDIA_PRIVACY_URL = "https://soso-so-27.github.io/neko-widget/privacy/"
MEDIA_SUPPORT_URL = "https://soso-so-27.github.io/neko-widget/support/"
MEDIA_COMMUNITY_URL = "https://soso-so-27.github.io/neko-widget/community/"
MODERATION_PUBLIC_KEY_SHA256 = hashlib.sha256(
    base64.urlsafe_b64decode(MODERATION_PUBLIC_KEY + "=")
).hexdigest()
REVIEWED_V1_PUBLIC_KEY_SHA256 = (
    "1032525271ff2ef318721e8bab46a3ab4ad503223403273f3baa84d7029e7a1a"
)
SYNTHETIC_V2_PUBLIC_KEY = base64.urlsafe_b64encode(bytes(range(32))).decode("ascii").rstrip("=")
SYNTHETIC_V2_PUBLIC_KEY_SHA256 = hashlib.sha256(bytes(range(32))).hexdigest()
MODE_FLAGS = {
    "disabled": (False, False, False, False, False),
    "review-preview": (False, False, False, False, True),
    "pairing-only": (True, False, False, False, False),
    "media-staging": (True, True, True, False, False),
}
X25519_SMALL_ORDER_PUBLIC_KEYS = (
    bytes.fromhex("00" * 32),
    bytes.fromhex("01" + ("00" * 31)),
    bytes.fromhex("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800"),
    bytes.fromhex("5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157"),
    bytes.fromhex("ec" + ("ff" * 30) + "7f"),
    bytes.fromhex("ed" + ("ff" * 30) + "7f"),
    bytes.fromhex("ee" + ("ff" * 30) + "7f"),
)


def canonical_json(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("ascii")


def rollout_policy(
    trust_manifest: dict[str, object],
    *,
    client_key_id: str,
    client_public_key_sha256: str,
    v2_allowed: bool,
) -> dict[str, object]:
    return {
        "schema": "jp.nekowidget.moderation-client-rollout-policy.v1",
        "environment": "testflight",
        "revision": 1,
        "clientKeyId": client_key_id,
        "clientPublicKeySha256": client_public_key_sha256,
        "trustManifestRevision": trust_manifest["revision"],
        "trustManifestSha256": hashlib.sha256(canonical_json(trust_manifest)).hexdigest(),
        "v2ClientReleaseAllowed": v2_allowed,
    }


def write_archive_info_plists(
    archive_path: Path,
    *,
    mode: str,
    moderation_key_id: str = "",
    moderation_public_key: str = "",
) -> Path:
    app_path = archive_path / "Products/Applications/NekoWidget.app"
    share_path = app_path / "PlugIns/NekoWidgetShareExtension.appex"
    widget_path = app_path / "PlugIns/NekoWidgetWidgetExtension.appex"
    share_path.mkdir(parents=True)
    widget_path.mkdir(parents=True)
    feature, media, handoff, direct, preview = MODE_FLAGS[mode]
    flag_names = (
        "SharingFeatureEnabled",
        "SharingMediaEnabled",
        "SharingShareExtensionHandoffEnabled",
        "SharingShareExtensionSendEnabled",
        "SharingReviewPreviewEnabled",
    )
    app_info: dict[str, object] = {
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "35",
        "SharingReleaseMode": mode,
        **dict(zip(flag_names, (feature, media, handoff, direct, preview), strict=True)),
    }
    if moderation_key_id:
        app_info["SharingModerationKeyID"] = moderation_key_id
    if moderation_public_key:
        app_info["SharingModerationPublicKey"] = moderation_public_key
    share_info = {
        "SharingReleaseMode": mode,
        **dict(zip(flag_names, (feature, media, handoff, direct, False), strict=True)),
    }
    widget_info = {
        "SharingReleaseMode": mode,
        "SharingFeatureEnabled": feature,
        "SharingMediaEnabled": media,
    }
    info_path = app_path / "Info.plist"
    for path, value in (
        (info_path, app_info),
        (share_path / "Info.plist", share_info),
        (widget_path / "Info.plist", widget_info),
    ):
        with path.open("wb") as stream:
            plistlib.dump(value, stream)
    return info_path


def metadata_writer_command(
    *,
    info_path: Path,
    output_path: Path,
    archive_path: Path,
    ipa_path: Path,
    policy_path: Path,
    policy_sha256: str,
    release_mode: str,
    moderation_key_id: str = "",
    moderation_public_key: str = "",
    moderation_public_key_sha256: str = "",
    trust_manifest_revision: str = "",
    trust_manifest_sha256: str = "",
) -> list[str]:
    return [
        sys.executable,
        str(METADATA_WRITER),
        "--info-plist", str(info_path),
        "--output", str(output_path),
        "--archive", str(archive_path),
        "--ipa", str(ipa_path),
        "--rollout-policy", str(policy_path),
        "--release-environment", "testflight",
        "--source-commit", "a" * 40,
        "--release-mode", release_mode,
        "--moderation-key-id", moderation_key_id,
        "--moderation-public-key", moderation_public_key,
        "--moderation-public-key-sha256", moderation_public_key_sha256,
        "--moderation-trust-manifest-revision", trust_manifest_revision,
        "--moderation-trust-manifest-sha256", trust_manifest_sha256,
        "--expected-rollout-policy-revision", "1",
        "--expected-rollout-policy-sha256", policy_sha256,
        "--expected-build-number", "35",
        "--github-run-id", "123456",
        "--github-run-attempt", "2",
    ]


def assignments(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith(("//", "#")):
            continue
        match = re.fullmatch(r"([A-Z0-9_]+)\s*=\s*(.*)", line)
        if match:
            values[match.group(1)] = match.group(2).strip()
    return values


def load_plist(path: Path) -> dict:
    with path.open("rb") as handle:
        value = plistlib.load(handle)
    if not isinstance(value, dict):
        raise AssertionError(f"{path} must contain a dictionary plist")
    return value


class MediaStagingReleaseConfigTests(unittest.TestCase):
    def test_tracked_rollout_policy_locks_the_current_client_to_reviewed_v1(self) -> None:
        policy = json.loads(ROLLOUT_POLICY.read_text(encoding="utf-8"))
        trust_manifest = {
            "schema": "jp.nekowidget.moderation-key-trust.v1",
            "environment": "testflight",
            "revision": 1,
            "keys": {"moderation-v1": REVIEWED_V1_PUBLIC_KEY_SHA256},
        }
        self.assertEqual(
            policy,
            rollout_policy(
                trust_manifest,
                client_key_id="moderation-v1",
                client_public_key_sha256=REVIEWED_V1_PUBLIC_KEY_SHA256,
                v2_allowed=False,
            ),
        )

    def test_existing_shipping_and_pairing_defaults_are_unchanged(self) -> None:
        base = assignments(BASE_CONFIG)
        self.assertEqual(
            (
                base["SHARING_RELEASE_MODE"],
                base["SHARING_FEATURE_ENABLED"],
                base["SHARING_MEDIA_ENABLED"],
                base["SHARING_SHARE_EXTENSION_HANDOFF_ENABLED"],
                base["SHARING_SHARE_EXTENSION_SEND_ENABLED"],
                base["SHARING_REVIEW_PREVIEW_ENABLED"],
            ),
            ("review-preview", "NO", "NO", "NO", "NO", "YES"),
        )
        pairing = assignments(PAIRING_CONFIG)
        self.assertEqual(
            (
                pairing["SHARING_RELEASE_MODE"],
                pairing["SHARING_FEATURE_ENABLED"],
                pairing["SHARING_MEDIA_ENABLED"],
                pairing["SHARING_SHARE_EXTENSION_HANDOFF_ENABLED"],
                pairing["SHARING_SHARE_EXTENSION_SEND_ENABLED"],
                pairing["SHARING_REVIEW_PREVIEW_ENABLED"],
            ),
            ("pairing-only", "YES", "NO", "NO", "NO", "NO"),
        )

    def test_media_overlay_enables_only_installation_bound_media(self) -> None:
        source = MEDIA_CONFIG.read_text(encoding="utf-8")
        self.assertIn('#include "Config.xcconfig"', source)
        values = assignments(MEDIA_CONFIG)
        self.assertEqual(
            (
                values["SHARING_RELEASE_MODE"],
                values["SHARING_FEATURE_ENABLED"],
                values["SHARING_MEDIA_ENABLED"],
                values["SHARING_SHARE_EXTENSION_HANDOFF_ENABLED"],
                values["SHARING_SHARE_EXTENSION_SEND_ENABLED"],
                values["SHARING_REVIEW_PREVIEW_ENABLED"],
            ),
            ("media-staging", "YES", "YES", "YES", "NO", "NO"),
        )
        for key in (
            "SHARING_API_BASE_URL",
            "SHARING_MODERATION_KEY_ID",
            "SHARING_MODERATION_PUBLIC_KEY",
            "SHARING_PRIVACY_URL",
            "SHARING_SUPPORT_URL",
            "SHARING_COMMUNITY_STANDARDS_URL",
        ):
            with self.subTest(key=key):
                self.assertEqual(values[key], "")
        self.assertNotIn("https://", source)
        self.assertNotIn("workers.dev", source)

    def test_media_privacy_manifest_is_exact_and_nontracking(self) -> None:
        manifest = load_plist(MEDIA_PRIVACY)
        self.assertIs(manifest["NSPrivacyTracking"], False)
        self.assertEqual(manifest["NSPrivacyTrackingDomains"], [])
        items = manifest["NSPrivacyCollectedDataTypes"]
        by_type = {item["NSPrivacyCollectedDataType"]: item for item in items}
        self.assertEqual(
            set(by_type),
            {USER_ID, PHOTOS, DEVICE_ID, PRODUCT_INTERACTION},
        )
        self.assertEqual(len(items), 4)
        for data_type, item in by_type.items():
            with self.subTest(data_type=data_type):
                self.assertIs(item["NSPrivacyCollectedDataTypeLinked"], True)
                self.assertIs(item["NSPrivacyCollectedDataTypeTracking"], False)
                self.assertEqual(
                    item["NSPrivacyCollectedDataTypePurposes"],
                    [APP_FUNCTIONALITY],
                )

    def test_workflow_injects_only_protected_media_values_and_verifies_archive(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(
            '届いた写真は、あなたが「思い出に残す」を明示的に選んだ場合だけ、位置情報を除いて写真アプリへ保存します',
            workflow,
        )
        self.assertNotIn(
            '受信した写真を自動的に写真アプリへ追加します',
            workflow,
        )
        variable_names = (
            "SHARING_STAGING_API_ORIGIN",
            "SHARING_STAGING_MODERATION_KEY_ID",
            "SHARING_STAGING_MODERATION_PUBLIC_KEY",
            "SHARING_STAGING_MODERATION_KEY_TRUST_MANIFEST",
            "SHARING_STAGING_PRIVACY_URL",
            "SHARING_STAGING_SUPPORT_URL",
            "SHARING_STAGING_COMMUNITY_STANDARDS_URL",
        )
        self.assertIn("- media-staging", workflow)
        for name in variable_names:
            with self.subTest(name=name):
                self.assertIn(f"${{{{ vars.{name} }}}}", workflow)
                self.assertNotIn(f"${{{{ secrets.{name} }}}}", workflow)

        media_block = workflow.split("media-staging)", 1)[1].split(";;", 1)[0]
        expected_fragments = (
            'release_feature="YES"',
            'release_media="YES"',
            'release_handoff="YES"',
            'release_direct_send="NO"',
            'release_review_preview="NO"',
            'release_photo_usage_description="$media_photo_usage_description"',
            "PrivacyInfo.MediaStaging.xcprivacy",
        )
        for fragment in expected_fragments:
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, media_block)

        archive_and_preflight_fragments = (
            'SHARING_RELEASE_MODE="$RELEASE_SHARING_RELEASE_MODE"',
            'SHARING_MEDIA_ENABLED="$RELEASE_SHARING_MEDIA_ENABLED"',
            'SHARING_SHARE_EXTENSION_HANDOFF_ENABLED="$RELEASE_SHARING_HANDOFF_ENABLED"',
            'SHARING_SHARE_EXTENSION_SEND_ENABLED="$RELEASE_SHARING_DIRECT_SEND_ENABLED"',
            'APP_PRIVACY_URL="$RELEASE_APP_PRIVACY_URL"',
            'APP_SUPPORT_URL="$RELEASE_APP_SUPPORT_URL"',
            'SHARING_PRIVACY_URL="$RELEASE_SHARING_PRIVACY_URL"',
            'PHOTO_LIBRARY_USAGE_DESCRIPTION="$RELEASE_PHOTO_LIBRARY_USAGE_DESCRIPTION"',
            'SHARE_EXTENSION_INFOPLIST_FILE="$RELEASE_SHARE_EXTENSION_INFOPLIST_FILE"',
            '--expected-mode "$SHARING_EXPECTED_MODE"',
            '--expected-photo-library-usage-description "$RELEASE_PHOTO_LIBRARY_USAGE_DESCRIPTION"',
            '--expected-moderation-public-key "$RELEASE_SHARING_MODERATION_PUBLIC_KEY"',
            '--expected-moderation-public-key-sha256 "$RELEASE_SHARING_MODERATION_PUBLIC_KEY_SHA256"',
            '--expected-moderation-trust-manifest-revision "$RELEASE_SHARING_MODERATION_TRUST_REVISION"',
            '--expected-release-environment "$RELEASE_ENVIRONMENT"',
            '--expected-build-number "$RELEASE_BUILD_NUMBER"',
            'moderation-client-rollout-policy.json',
            'RELEASE_SHARING_MODERATION_TRUST_MANIFEST_SHA256',
            'RELEASE_SHARING_MODERATION_ROLLOUT_POLICY_REVISION',
            'RELEASE_SHARING_MODERATION_ROLLOUT_POLICY_SHA256',
            'write-moderation-release-metadata.py',
            '--moderation-trust-manifest-sha256',
            '--expected-rollout-policy-revision',
            '--expected-rollout-policy-sha256',
            '--github-run-id "$GITHUB_RUN_ID"',
            '--github-run-attempt "$GITHUB_RUN_ATTEMPT"',
            'signed-artifact-authentication.py" create',
            'signed-artifact-authentication.py" verify',
            'moderation-release-metadata.json',
            '--expected-app-privacy-url "$RELEASE_APP_PRIVACY_URL"',
            '--expected-app-support-url "$RELEASE_APP_SUPPORT_URL"',
            '--expected-privacy-url "$RELEASE_SHARING_PRIVACY_URL"',
            '--expected-support-url "$RELEASE_SHARING_SUPPORT_URL"',
            '--expected-community-standards-url "$RELEASE_SHARING_COMMUNITY_STANDARDS_URL"',
            'push_environment != "production"',
            'requires_push=True',
            'app_push_environment',
            '[[ "$app_push_environment" == "production" ]]',
            '[[ -z "$widget_push_environment" ]]',
            '[[ -z "$share_push_environment" ]]',
        )
        for fragment in archive_and_preflight_fragments:
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, workflow)
        authentication_verify = workflow.index(
            'signed-artifact-authentication.py" verify'
        )
        decrypt_check = workflow.index("openssl enc \\\n            -d", authentication_verify)
        self.assertLess(
            authentication_verify,
            decrypt_check,
            "encrypted artifacts must be authenticated before any test decryption",
        )

    def test_release_selector_bash_and_embedded_python_are_valid(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        step = workflow.split("- name: Select fail-closed release mode", 1)[1]
        step = step.split("\n      - name:", 1)[0]
        shell_source = textwrap.dedent(step.split("run: |", 1)[1]).lstrip()
        bash_check = subprocess.run(
            ["bash", "-n"],
            input=shell_source.replace("\r", "").encode("utf-8"),
            capture_output=True,
            check=False,
        )
        self.assertEqual(
            bash_check.returncode,
            0,
            bash_check.stderr.decode("utf-8", errors="replace"),
        )

        marker = '"$PROJECT_DIRECTORY/ci/moderation-client-rollout-policy.json" <<\'PY\'\n'
        embedded = workflow.split(marker, 1)[1].split("\n          PY", 1)[0]
        embedded = textwrap.dedent(embedded)
        compile(embedded, "testflight-release-selector", "exec")

        public_dns_stub = (
            "import socket\n"
            "socket.getaddrinfo = lambda *args, **kwargs: "
            "[(socket.AF_INET, socket.SOCK_STREAM, 6, '', ('93.184.216.34', 443))]\n"
        )
        trust_manifest_value = {
            "schema": "jp.nekowidget.moderation-key-trust.v1",
            "environment": "testflight",
            "revision": 1,
            "keys": {"moderation-v1": MODERATION_PUBLIC_KEY_SHA256},
        }
        trust_manifest = canonical_json(trust_manifest_value).decode("ascii")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            policy_path = root / "policy.json"
            policy_value = rollout_policy(
                trust_manifest_value,
                client_key_id="moderation-v1",
                client_public_key_sha256=MODERATION_PUBLIC_KEY_SHA256,
                v2_allowed=False,
            )
            policy_path.write_bytes(canonical_json(policy_value))
            policy_hash = hashlib.sha256(canonical_json(policy_value)).hexdigest()
            manifest_hash = hashlib.sha256(canonical_json(trust_manifest_value)).hexdigest()
            valid_arguments = [
                "media-staging",
                MEDIA_ORIGIN,
                MEDIA_PRIVACY_URL,
                MEDIA_SUPPORT_URL,
                "moderation-v1",
                MODERATION_PUBLIC_KEY,
                MEDIA_PRIVACY_URL,
                MEDIA_SUPPORT_URL,
                MEDIA_COMMUNITY_URL,
                trust_manifest,
                str(policy_path),
            ]
            valid = subprocess.run(
                [sys.executable, "-c", public_dns_stub + embedded, *valid_arguments],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(valid.returncode, 0, valid.stderr)
            self.assertEqual(
                valid.stdout,
                f"1:{policy_hash}:{MODERATION_PUBLIC_KEY_SHA256}:1:{manifest_hash}\n",
            )

            missing_privacy = list(valid_arguments)
            missing_privacy[2] = ""
            missing_privacy[6] = ""
            invalid = subprocess.run(
                [sys.executable, "-c", public_dns_stub + embedded, *missing_privacy],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn("SHARING_STAGING_PRIVACY_URL", invalid.stderr)

            small_order_key = list(valid_arguments)
            small_order_key[5] = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            invalid = subprocess.run(
                [sys.executable, "-c", public_dns_stub + embedded, *small_order_key],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn("small-order X25519 point", invalid.stderr)

            malformed_cases = []
            unsupported_key_id = list(valid_arguments)
            unsupported_key_id[4] = "moderation-v3"
            malformed_cases.append((unsupported_key_id, "not explicitly supported"))
            whitespace_key_id = list(valid_arguments)
            whitespace_key_id[4] = " moderation-v1"
            malformed_cases.append((whitespace_key_id, "surrounding whitespace"))
            absent_v2 = list(valid_arguments)
            absent_v2[4] = "moderation-v2"
            malformed_cases.append((absent_v2, "absent from the reviewed trust manifest"))
            mismatched_fingerprint = list(valid_arguments)
            mismatched_manifest = json.loads(trust_manifest)
            mismatched_manifest["keys"]["moderation-v1"] = "0" * 64
            mismatched_fingerprint[9] = json.dumps(mismatched_manifest)
            malformed_cases.append((mismatched_fingerprint, "does not match"))
            changed_canonical_manifest = list(valid_arguments)
            changed_manifest = json.loads(trust_manifest)
            changed_manifest["keys"]["moderation-v2"] = SYNTHETIC_V2_PUBLIC_KEY_SHA256
            changed_canonical_manifest[9] = json.dumps(changed_manifest)
            malformed_cases.append((
                changed_canonical_manifest,
                "Canonical moderation trust manifest does not match",
            ))
            uppercase_fingerprint = list(valid_arguments)
            uppercase_manifest = json.loads(trust_manifest)
            uppercase_manifest["keys"]["moderation-v1"] = MODERATION_PUBLIC_KEY_SHA256.upper()
            uppercase_fingerprint[9] = json.dumps(uppercase_manifest)
            malformed_cases.append((uppercase_fingerprint, "64 lowercase hexadecimal"))
            missing_v1 = list(valid_arguments)
            missing_v1[9] = json.dumps({
                "schema": "jp.nekowidget.moderation-key-trust.v1",
                "environment": "testflight",
                "revision": 1,
                "keys": {},
            })
            malformed_cases.append((missing_v1, "must retain moderation-v1"))
            duplicate_manifest_key = list(valid_arguments)
            duplicate_manifest_key[9] = (
                '{"schema":"jp.nekowidget.moderation-key-trust.v1",'
                '"environment":"testflight","revision":1,"revision":2,'
                f'"keys":{{"moderation-v1":"{MODERATION_PUBLIC_KEY_SHA256}"}}}}'
            )
            malformed_cases.append((duplicate_manifest_key, "strict JSON"))

            for arguments, message in malformed_cases:
                with self.subTest(message=message):
                    invalid = subprocess.run(
                        [sys.executable, "-c", public_dns_stub + embedded, *arguments],
                        text=True,
                        capture_output=True,
                        check=False,
                    )
                    self.assertNotEqual(invalid.returncode, 0)
                    self.assertIn(message, invalid.stderr)

    def test_synthetic_v2_is_rejected_until_machine_verifiable_readiness_exists(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        marker = '"$PROJECT_DIRECTORY/ci/moderation-client-rollout-policy.json" <<\'PY\'\n'
        embedded = textwrap.dedent(
            workflow.split(marker, 1)[1].split("\n          PY", 1)[0]
        )
        public_dns_stub = (
            "import socket\n"
            "socket.getaddrinfo = lambda *args, **kwargs: "
            "[(socket.AF_INET, socket.SOCK_STREAM, 6, '', ('93.184.216.34', 443))]\n"
        )
        trust_manifest_value = {
            "schema": "jp.nekowidget.moderation-key-trust.v1",
            "environment": "testflight",
            "revision": 2,
            "keys": {
                "moderation-v1": REVIEWED_V1_PUBLIC_KEY_SHA256,
                "moderation-v2": SYNTHETIC_V2_PUBLIC_KEY_SHA256,
            },
        }
        trust_manifest = canonical_json(trust_manifest_value).decode("ascii")

        def arguments(policy_path: Path) -> list[str]:
            return [
                "media-staging",
                MEDIA_ORIGIN,
                MEDIA_PRIVACY_URL,
                MEDIA_SUPPORT_URL,
                "moderation-v2",
                SYNTHETIC_V2_PUBLIC_KEY,
                MEDIA_PRIVACY_URL,
                MEDIA_SUPPORT_URL,
                MEDIA_COMMUNITY_URL,
                trust_manifest,
                str(policy_path),
            ]

        with tempfile.TemporaryDirectory() as directory:
            policy_path = Path(directory) / "v2-policy.json"
            policy_value = rollout_policy(
                trust_manifest_value,
                client_key_id="moderation-v2",
                client_public_key_sha256=SYNTHETIC_V2_PUBLIC_KEY_SHA256,
                v2_allowed=True,
            )
            policy_path.write_bytes(canonical_json(policy_value))
            result = subprocess.run(
                [sys.executable, "-c", public_dns_stub + embedded, *arguments(policy_path)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "machine-verifiable server and drill readiness evidence is not implemented",
                result.stderr,
            )

        blocked = subprocess.run(
            [sys.executable, "-c", public_dns_stub + embedded, *arguments(ROLLOUT_POLICY)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(blocked.returncode, 0)
        self.assertIn(
            "machine-verifiable server and drill readiness evidence is not implemented",
            blocked.stderr,
        )

    def test_release_metadata_binds_the_archive_key_and_build(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_path = root / "NekoWidget.xcarchive"
            ipa_path = root / "NekoWidget.ipa"
            ipa_path.write_bytes(b"synthetic IPA bytes")
            output_path = root / "moderation-release-metadata.json"
            info_path = write_archive_info_plists(
                archive_path,
                mode="media-staging",
                moderation_key_id="moderation-v1",
                moderation_public_key=MODERATION_PUBLIC_KEY,
            )
            trust_manifest = {
                "schema": "jp.nekowidget.moderation-key-trust.v1",
                "environment": "testflight",
                "revision": 1,
                "keys": {"moderation-v1": MODERATION_PUBLIC_KEY_SHA256},
            }
            policy_value = rollout_policy(
                trust_manifest,
                client_key_id="moderation-v1",
                client_public_key_sha256=MODERATION_PUBLIC_KEY_SHA256,
                v2_allowed=False,
            )
            policy_path = root / "rollout-policy.json"
            policy_path.write_bytes(canonical_json(policy_value))
            policy_sha256 = hashlib.sha256(canonical_json(policy_value)).hexdigest()
            trust_manifest_sha256 = hashlib.sha256(
                canonical_json(trust_manifest)
            ).hexdigest()

            def arguments(
                output: Path,
                fingerprint: str,
                expected_policy_sha256: str = policy_sha256,
            ) -> list[str]:
                return metadata_writer_command(
                    info_path=info_path,
                    output_path=output,
                    archive_path=archive_path,
                    ipa_path=ipa_path,
                    policy_path=policy_path,
                    policy_sha256=expected_policy_sha256,
                    release_mode="media-staging",
                    moderation_key_id="moderation-v1",
                    moderation_public_key=MODERATION_PUBLIC_KEY,
                    moderation_public_key_sha256=fingerprint,
                    trust_manifest_revision="1",
                    trust_manifest_sha256=trust_manifest_sha256,
                )

            result = subprocess.run(
                arguments(output_path, MODERATION_PUBLIC_KEY_SHA256),
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            metadata = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(metadata, {
                "schema": "jp.nekowidget.moderation-release-metadata.v2",
                "releaseEnvironment": "testflight",
                "sourceCommit": "a" * 40,
                "releaseMode": "media-staging",
                "version": "1.0",
                "buildNumber": "35",
                "moderationKeyId": "moderation-v1",
                "moderationPublicKey": MODERATION_PUBLIC_KEY,
                "moderationPublicKeySha256": MODERATION_PUBLIC_KEY_SHA256,
                "moderationTrustManifestRevision": 1,
                "moderationTrustManifestSha256": trust_manifest_sha256,
                "moderationRolloutPolicyRevision": 1,
                "moderationRolloutPolicySha256": policy_sha256,
                "githubRunId": "123456",
                "githubRunAttempt": 2,
                "archiveDigestAlgorithm": "sha256-tree-v2",
                "archiveSha256": metadata["archiveSha256"],
                "ipaSha256": hashlib.sha256(ipa_path.read_bytes()).hexdigest(),
            })
            self.assertRegex(metadata["archiveSha256"], r"^[0-9a-f]{64}$")

            mismatch_output = root / "mismatch.json"
            mismatch = subprocess.run(
                arguments(mismatch_output, "0" * 64),
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(mismatch.returncode, 0)
            self.assertIn("fingerprint mismatch", mismatch.stderr)
            self.assertFalse(mismatch_output.exists())

            policy_mismatch_output = root / "policy-mismatch.json"
            policy_mismatch = subprocess.run(
                arguments(
                    policy_mismatch_output,
                    MODERATION_PUBLIC_KEY_SHA256,
                    "0" * 64,
                ),
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(policy_mismatch.returncode, 0)
            self.assertIn("rollout policy SHA-256 mismatch", policy_mismatch.stderr)
            self.assertFalse(policy_mismatch_output.exists())

    def test_release_metadata_rejects_archive_mode_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_path = root / "NekoWidget.xcarchive"
            info_path = write_archive_info_plists(
                archive_path,
                mode="media-staging",
                moderation_key_id="moderation-v1",
                moderation_public_key=MODERATION_PUBLIC_KEY,
            )
            ipa_path = root / "NekoWidget.ipa"
            ipa_path.write_bytes(b"synthetic IPA bytes")
            trust_manifest = {
                "schema": "jp.nekowidget.moderation-key-trust.v1",
                "environment": "testflight",
                "revision": 1,
                "keys": {"moderation-v1": MODERATION_PUBLIC_KEY_SHA256},
            }
            policy = rollout_policy(
                trust_manifest,
                client_key_id="moderation-v1",
                client_public_key_sha256=MODERATION_PUBLIC_KEY_SHA256,
                v2_allowed=False,
            )
            policy_path = root / "rollout-policy.json"
            policy_path.write_bytes(canonical_json(policy))
            output_path = root / "moderation-release-metadata.json"
            result = subprocess.run(
                metadata_writer_command(
                    info_path=info_path,
                    output_path=output_path,
                    archive_path=archive_path,
                    ipa_path=ipa_path,
                    policy_path=policy_path,
                    policy_sha256=hashlib.sha256(canonical_json(policy)).hexdigest(),
                    release_mode="pairing-only",
                ),
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("SharingReleaseMode does not match", result.stderr)
            self.assertFalse(output_path.exists())

    def test_release_metadata_rejects_non_media_archive_key_residue(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_path = root / "NekoWidget.xcarchive"
            info_path = write_archive_info_plists(
                archive_path,
                mode="pairing-only",
                moderation_key_id="moderation-v1",
                moderation_public_key=MODERATION_PUBLIC_KEY,
            )
            ipa_path = root / "NekoWidget.ipa"
            ipa_path.write_bytes(b"synthetic IPA bytes")
            trust_manifest = {
                "schema": "jp.nekowidget.moderation-key-trust.v1",
                "environment": "testflight",
                "revision": 1,
                "keys": {"moderation-v1": MODERATION_PUBLIC_KEY_SHA256},
            }
            policy = rollout_policy(
                trust_manifest,
                client_key_id="moderation-v1",
                client_public_key_sha256=MODERATION_PUBLIC_KEY_SHA256,
                v2_allowed=False,
            )
            policy_path = root / "rollout-policy.json"
            policy_path.write_bytes(canonical_json(policy))
            output_path = root / "moderation-release-metadata.json"
            result = subprocess.run(
                metadata_writer_command(
                    info_path=info_path,
                    output_path=output_path,
                    archive_path=archive_path,
                    ipa_path=ipa_path,
                    policy_path=policy_path,
                    policy_sha256=hashlib.sha256(canonical_json(policy)).hexdigest(),
                    release_mode="pairing-only",
                ),
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "Archive app SharingModerationKeyID does not match",
                result.stderr,
            )
            self.assertFalse(output_path.exists())

    def test_release_metadata_rejects_all_known_small_order_x25519_points(self) -> None:
        for index, weak_key in enumerate(X25519_SMALL_ORDER_PUBLIC_KEYS):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                public_key = base64.urlsafe_b64encode(weak_key).decode("ascii").rstrip("=")
                fingerprint = hashlib.sha256(weak_key).hexdigest()
                archive_path = root / "NekoWidget.xcarchive"
                info_path = write_archive_info_plists(
                    archive_path,
                    mode="media-staging",
                    moderation_key_id="moderation-v1",
                    moderation_public_key=public_key,
                )
                ipa_path = root / "NekoWidget.ipa"
                ipa_path.write_bytes(b"synthetic IPA bytes")
                trust_manifest = {
                    "schema": "jp.nekowidget.moderation-key-trust.v1",
                    "environment": "testflight",
                    "revision": 1,
                    "keys": {"moderation-v1": fingerprint},
                }
                policy = rollout_policy(
                    trust_manifest,
                    client_key_id="moderation-v1",
                    client_public_key_sha256=fingerprint,
                    v2_allowed=False,
                )
                policy_path = root / "rollout-policy.json"
                policy_path.write_bytes(canonical_json(policy))
                trust_manifest_sha256 = hashlib.sha256(
                    canonical_json(trust_manifest)
                ).hexdigest()
                output_path = root / "moderation-release-metadata.json"
                result = subprocess.run(
                    metadata_writer_command(
                        info_path=info_path,
                        output_path=output_path,
                        archive_path=archive_path,
                        ipa_path=ipa_path,
                        policy_path=policy_path,
                        policy_sha256=hashlib.sha256(canonical_json(policy)).hexdigest(),
                        release_mode="media-staging",
                        moderation_key_id="moderation-v1",
                        moderation_public_key=public_key,
                        moderation_public_key_sha256=fingerprint,
                        trust_manifest_revision="1",
                        trust_manifest_sha256=trust_manifest_sha256,
                    ),
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("small-order X25519 point", result.stderr)
                self.assertFalse(output_path.exists())

    def test_release_metadata_rejects_v2_flag_and_selection_independently(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_path = root / "NekoWidget.xcarchive"
            info_path = write_archive_info_plists(
                archive_path,
                mode="pairing-only",
            )
            ipa_path = root / "NekoWidget.ipa"
            ipa_path.write_bytes(b"synthetic IPA bytes")
            v1_manifest = {
                "schema": "jp.nekowidget.moderation-key-trust.v1",
                "environment": "testflight",
                "revision": 1,
                "keys": {"moderation-v1": MODERATION_PUBLIC_KEY_SHA256},
            }
            dual_manifest = {
                **v1_manifest,
                "keys": {
                    "moderation-v1": MODERATION_PUBLIC_KEY_SHA256,
                    "moderation-v2": SYNTHETIC_V2_PUBLIC_KEY_SHA256,
                },
            }
            cases = (
                (
                    rollout_policy(
                        v1_manifest,
                        client_key_id="moderation-v1",
                        client_public_key_sha256=MODERATION_PUBLIC_KEY_SHA256,
                        v2_allowed=True,
                    ),
                    "cannot allow v2",
                ),
                (
                    rollout_policy(
                        dual_manifest,
                        client_key_id="moderation-v2",
                        client_public_key_sha256=SYNTHETIC_V2_PUBLIC_KEY_SHA256,
                        v2_allowed=False,
                    ),
                    "cannot select v2",
                ),
            )
            for index, (policy, expected_message) in enumerate(cases):
                with self.subTest(index=index):
                    policy_path = root / f"rollout-policy-{index}.json"
                    policy_path.write_bytes(canonical_json(policy))
                    output_path = root / f"moderation-release-metadata-{index}.json"
                    result = subprocess.run(
                        metadata_writer_command(
                            info_path=info_path,
                            output_path=output_path,
                            archive_path=archive_path,
                            ipa_path=ipa_path,
                            policy_path=policy_path,
                            policy_sha256=hashlib.sha256(
                                canonical_json(policy)
                            ).hexdigest(),
                            release_mode="pairing-only",
                        ),
                        text=True,
                        capture_output=True,
                        check=False,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(expected_message, result.stderr)
                    self.assertIn(
                        "machine-verifiable server and drill readiness evidence "
                        "is not implemented",
                        result.stderr,
                    )
                    self.assertFalse(output_path.exists())

    def test_archive_digest_detects_permission_only_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_path = root / "NekoWidget.xcarchive"
            info_path = write_archive_info_plists(
                archive_path,
                mode="media-staging",
                moderation_key_id="moderation-v1",
                moderation_public_key=MODERATION_PUBLIC_KEY,
            )
            mode_sensitive_file = archive_path / "mode-sensitive.bin"
            mode_sensitive_file.write_bytes(b"unchanged bytes")
            ipa_path = root / "NekoWidget.ipa"
            ipa_path.write_bytes(b"synthetic IPA bytes")
            trust_manifest = {
                "schema": "jp.nekowidget.moderation-key-trust.v1",
                "environment": "testflight",
                "revision": 1,
                "keys": {"moderation-v1": MODERATION_PUBLIC_KEY_SHA256},
            }
            policy = rollout_policy(
                trust_manifest,
                client_key_id="moderation-v1",
                client_public_key_sha256=MODERATION_PUBLIC_KEY_SHA256,
                v2_allowed=False,
            )
            policy_path = root / "rollout-policy.json"
            policy_path.write_bytes(canonical_json(policy))
            policy_sha256 = hashlib.sha256(canonical_json(policy)).hexdigest()
            trust_manifest_sha256 = hashlib.sha256(
                canonical_json(trust_manifest)
            ).hexdigest()

            def run_writer(output_path: Path) -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    metadata_writer_command(
                        info_path=info_path,
                        output_path=output_path,
                        archive_path=archive_path,
                        ipa_path=ipa_path,
                        policy_path=policy_path,
                        policy_sha256=policy_sha256,
                        release_mode="media-staging",
                        moderation_key_id="moderation-v1",
                        moderation_public_key=MODERATION_PUBLIC_KEY,
                        moderation_public_key_sha256=MODERATION_PUBLIC_KEY_SHA256,
                        trust_manifest_revision="1",
                        trust_manifest_sha256=trust_manifest_sha256,
                    ),
                    text=True,
                    capture_output=True,
                    check=False,
                )

            first_output = root / "metadata-before-mode-change.json"
            second_output = root / "metadata-after-mode-change.json"
            try:
                mode_sensitive_file.chmod(0o600)
                first_mode = stat.S_IMODE(mode_sensitive_file.stat().st_mode)
                first = run_writer(first_output)
                self.assertEqual(first.returncode, 0, first.stderr)

                mode_sensitive_file.chmod(0o400)
                second_mode = stat.S_IMODE(mode_sensitive_file.stat().st_mode)
                self.assertNotEqual(first_mode, second_mode)
                second = run_writer(second_output)
                self.assertEqual(second.returncode, 0, second.stderr)
            finally:
                mode_sensitive_file.chmod(0o600)

            first_metadata = json.loads(first_output.read_text(encoding="utf-8"))
            second_metadata = json.loads(second_output.read_text(encoding="utf-8"))
            self.assertEqual(first_metadata["archiveDigestAlgorithm"], "sha256-tree-v2")
            self.assertNotEqual(
                first_metadata["archiveSha256"],
                second_metadata["archiveSha256"],
            )

    def test_privacy_policy_is_a_required_runtime_gate_and_visible_before_consent(self) -> None:
        info = (ROOT / "NekoWidget/Info.plist").read_text(encoding="utf-8")
        configuration = (
            ROOT / "Shared/Sharing/SharingAPIConfiguration.swift"
        ).read_text(encoding="utf-8")
        pairing = (ROOT / "NekoWidget/Views/PairingView.swift").read_text(
            encoding="utf-8"
        )
        family = (ROOT / "NekoWidget/Views/FamilyWindowView.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn("<key>SharingPrivacyURL</key>", info)
        self.assertIn("<string>$(SHARING_PRIVACY_URL)</string>", info)
        self.assertIn('info["SharingPrivacyURL"]', configuration)
        self.assertIn("&& privacyURL != nil", configuration)
        self.assertIn("hasSmallOrderX25519PublicKey", configuration)
        self.assertEqual(pairing.count('Link("プライバシーポリシーを確認"'), 2)
        self.assertEqual(pairing.count('Link("コミュニティ基準を確認"'), 2)
        self.assertIn('Link("プライバシーポリシー"', family)


if __name__ == "__main__":
    unittest.main()
