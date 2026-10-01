from __future__ import annotations

import importlib.util
import plistlib
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("pilot", Path(__file__).with_name("preservation-pilot-release.py"))
pilot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pilot)


class PreservationReleaseTests(unittest.TestCase):
    def privacy(self):
        with Path(__file__).with_name("PrivacyInfo.MediaStaging.xcprivacy").open("rb") as handle:
            return plistlib.load(handle)

    def ready(self):
        values = pilot.settings(True, "media-staging", "YES", "internal")
        info = {pilot.INFO_KEYS[key]: value for key, value in values.items()}
        info["SharingReleaseMode"] = "media-staging"
        info["MembershipAccessEnforced"] = False
        return values, info, pilot.add_privacy(self.privacy())

    def test_ordinary_release_stays_off_even_with_stale_approval(self):
        values = pilot.settings(False, "disabled", "YES", "internal")
        self.assertTrue(all(values[key] == "NO" for key in pilot.FLAGS))
        self.assertEqual(values["MANAGED_PRESERVATION_ORIGIN"], "")
        self.assertEqual(values["PLUS_BILLING_API_BASE_URL"], "")

    def test_other_mode_missing_approval_or_external_scope_cannot_enable(self):
        for mode, approval, scope in [("disabled", "YES", "internal"),
                                      ("media-staging", "", "internal"),
                                      ("media-staging", "YES", "external")]:
            with self.subTest(mode=mode, approval=approval, scope=scope), self.assertRaises(ValueError):
                pilot.settings(True, mode, approval, scope)

    def test_fixed_pilot_accepts_processed_plist_and_privacy(self):
        values, info, privacy = self.ready()
        pilot.verify(info, values, privacy)
        names = [entry["NSPrivacyCollectedDataType"] for entry in privacy["NSPrivacyCollectedDataTypes"]]
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(privacy, pilot.add_privacy(privacy))

    def test_archived_wrong_recipient_audience_or_product_is_rejected(self):
        values, original, privacy = self.ready()
        for key, replacement in [("ManagedPreservationOrigin", "https://other.example"),
                                 ("ManagedPreservationMembershipAudience", "other-owner"),
                                 ("PlusMonthlyProductID", "jp.nekowidget.other"),
                                 ("PlusAnnualProductID", "jp.nekowidget.plus.annual")]:
            info = {**original, key: replacement}
            with self.subTest(key=key), self.assertRaises(ValueError):
                pilot.verify(info, values, privacy)

    def test_collection_omission_or_tracking_is_rejected(self):
        values, info, privacy = self.ready()
        with self.assertRaises(ValueError):
            pilot.verify(info, values, self.privacy())
        extra = next(item for item in privacy["NSPrivacyCollectedDataTypes"]
                     if item["NSPrivacyCollectedDataType"] in pilot.EXTRA_COLLECTIONS)
        extra["NSPrivacyCollectedDataTypeTracking"] = True
        with self.assertRaises(ValueError):
            pilot.verify(info, values, privacy)

    def test_pilot_export_is_internal_only_and_missing_restriction_is_rejected(self):
        values, _, _ = self.ready()
        options = pilot.prepare_export_options({"method": "app-store-connect"}, values)
        self.assertIs(options["testFlightInternalTestingOnly"], True)
        pilot.verify_export_options(plistlib.loads(plistlib.dumps(options)), values)
        for invalid in ({}, {"testFlightInternalTestingOnly": False},
                        {"testFlightInternalTestingOnly": "true"}):
            with self.subTest(options=invalid), self.assertRaises(ValueError):
                pilot.verify_export_options(invalid, values)

    def test_ordinary_export_keeps_original_options(self):
        values = pilot.settings(False, "media-staging", "", "")
        original = {"method": "app-store-connect", "uploadSymbols": True}
        self.assertEqual(pilot.prepare_export_options(original.copy(), values), original)
        pilot.verify_export_options(original, values)
        with self.assertRaises(ValueError):
            pilot.prepare_export_options({"testFlightInternalTestingOnly": True}, values)

    def test_billing_requires_both_pilot_and_separate_internal_approval(self):
        for requested, mode, approval, scope, billing_approval, billing_scope in [
            (False, "media-staging", "YES", "internal", "YES", "internal"),
            (True, "disabled", "YES", "internal", "YES", "internal"),
            (True, "media-staging", "", "internal", "YES", "internal"),
            (True, "media-staging", "YES", "internal", "", "internal"),
            (True, "media-staging", "YES", "internal", "YES", "external"),
        ]:
            with self.subTest(mode=mode, billing_scope=billing_scope), self.assertRaises(ValueError):
                pilot.settings(requested, mode, approval, scope, billing_requested=True,
                               billing_approval=billing_approval, billing_scope=billing_scope)

    def test_billing_uses_fixed_monthly_product_private_backend_and_real_boundaries(self):
        values = pilot.settings(True, "media-staging", "YES", "internal", billing_requested=True,
                                billing_approval="YES", billing_scope="internal")
        self.assertEqual(values["PLUS_MONTHLY_PRODUCT_ID"], "jp.nekowidget.plus.monthly")
        self.assertEqual(values["PLUS_ANNUAL_PRODUCT_ID"], "")
        self.assertEqual(values["PLUS_BILLING_API_BASE_URL"], pilot.BILLING_ORIGIN)
        self.assertEqual(values["PLUS_STOREFRONT_ENABLED"], "YES")
        self.assertEqual(values["PLUS_BILLING_RECOVERY_ENABLED"], "YES")
        info = {pilot.INFO_KEYS[key]: value for key, value in values.items()}
        info.update(SharingReleaseMode="media-staging", MembershipAccessEnforced=True)
        widget = pilot.prepare_membership_info({"MembershipAccessEnforced": False, "Other": "unchanged"}, values)
        self.assertEqual(widget, {"MembershipAccessEnforced": True, "Other": "unchanged"})
        privacy = pilot.add_privacy(self.privacy())
        pilot.verify(info, values, privacy, widget)
        options = pilot.prepare_export_options({"method": "app-store-connect"}, values)
        self.assertIs(options["testFlightInternalTestingOnly"], True)
        for invalid in (None, {"MembershipAccessEnforced": False}, {"MembershipAccessEnforced": "YES"}):
            with self.subTest(widget=invalid), self.assertRaises(ValueError):
                pilot.verify(info, values, privacy, invalid)
        with self.assertRaises(ValueError):
            pilot.verify({**info, "MembershipAccessEnforced": False}, values, privacy, widget)

    def test_stale_billing_approval_does_not_activate_ordinary_or_preservation_only(self):
        for requested in (False, True):
            values = pilot.settings(requested, "media-staging", "YES", "internal",
                                    billing_approval="YES", billing_scope="internal")
            self.assertEqual(values["PLUS_BILLING_CLIENT_ENABLED"], "NO")
            original = {"MembershipAccessEnforced": False}
            self.assertEqual(pilot.prepare_membership_info(original, values), original)
            for bad in ({}, {"MembershipAccessEnforced": True}, {"MembershipAccessEnforced": "NO"}):
                with self.subTest(source=bad), self.assertRaises(ValueError):
                    pilot.prepare_membership_info(bad, values)

    def test_workflow_passes_same_approval_to_prepare_archive_and_export(self):
        source = Path(__file__).resolve().parents[2].joinpath(".github/workflows/testflight.yml").read_text(encoding="utf-8")
        self.assertIn("      billing_sandbox:", source)
        for value in ("BILLING_REQUESTED: ${{ inputs.billing_sandbox }}",
                      "BILLING_APPROVAL: ${{ vars.BILLING_SANDBOX_ENABLED }}",
                      "BILLING_SCOPE: ${{ vars.BILLING_SANDBOX_SCOPE }}",
                      '--billing-requested "${BILLING_REQUESTED:-false}"',
                      '--billing-approval "${BILLING_APPROVAL:-}"',
                      '--billing-scope "${BILLING_SCOPE:-}"'):
            self.assertEqual(source.count(value), 3)
        self.assertIn('--app-source-info-plist "$PROJECT_DIRECTORY/NekoWidget/Info.plist"', source)
        self.assertIn('--widget-source-info-plist "$PROJECT_DIRECTORY/NekoWidgetWidget/Info.plist"', source)
        self.assertIn('--widget-info-plist "$widget_path/Info.plist"', source)


if __name__ == "__main__":
    unittest.main()
