"""No credentials, signing, or network. Exercise the unsigned/signed boundary."""
import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import distribution_profile as profile
import moderation_readiness
from internal_report_release import metadata_settings, verify_ipa

ROOT = Path(__file__).resolve().parents[1]


def app_info(extension=False):
    info = {profile.OFF_KEY: "YES", "SharingInternalEncryptedReportEnabled": False,
            "SharingInternalEncryptedReportScope": "", "SharingReleaseMode": "media-staging"}
    if not extension:
        info.update(SharingAPIBaseURL=profile.ORIGIN, SharingModerationKeyID="moderation-v2",
                    SharingModerationPublicKey=profile.RECIPIENT, GroupReportingProductionEnabled="NO",
                    SharingReviewPreviewEnabled="NO", SharingShareExtensionSendEnabled="NO")
    return info


class DistributionProfileTests(unittest.TestCase):
    def test_explicit_profile_and_contradictions(self):
        for value in (None, "", "select-required", "external", "owner-internal "):
            with self.assertRaises(ValueError):
                profile.validate(value, "media-staging", False)
        for mode, reports in (("production", False), ("disabled", False), ("media-staging", True)):
            with self.assertRaises(ValueError):
                profile.validate(profile.OWNER, mode, reports)
        profile.validate(profile.REVIEWED, "media-staging", True)
        profile.validate(profile.OWNER, "media-staging", False)

    def test_absent_and_invalid_record_pass_owner_but_block_reviewed(self):
        policy = json.loads((ROOT / "ci/moderation-client-rollout-policy.json").read_text())
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "moderation_readiness.py"
            # The actual verifier reads this directory; owner never opens it.
            with patch.object(moderation_readiness, "__file__", str(script)):
                for contents in (None, '{"payload":{},"signatures":[]}', 'not json'):
                    record = Path(directory) / "moderation-v2-readiness.json"
                    if contents is not None:
                        record.write_text(contents)
                    profile.verify_readiness(policy, profile=profile.OWNER, mode="media-staging", internal_reports=False)
                    with self.assertRaises(SystemExit):
                        profile.verify_readiness(policy, profile=profile.REVIEWED, mode="media-staging", internal_reports=False)
        # Expired existing record fails before code-hash/signature checks.
        expired = json.loads((ROOT / "ci/moderation-v2-readiness.json").read_text())
        expired['payload']['expiresAtMs'] = 1
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'moderation-v2-readiness.json').write_text(json.dumps(expired))
            # Actual verifier, retaining its real code path resolution.
            target = (ROOT / 'ci/verify-moderation-readiness.mjs').as_uri()
            (root / 'verify-moderation-readiness.mjs').write_text(
                f"import {{verifyReadiness}} from '{target}'; let s=''; for await(const c of process.stdin)s+=c; "
                "const x=JSON.parse(s); try { await verifyReadiness(x.evidence,x.policy); } catch(e) { console.error(e.message); process.exitCode=1; }")
            with patch.object(moderation_readiness, "__file__", str(root / 'moderation_readiness.py')):
                profile.verify_readiness(policy, profile=profile.OWNER, mode='media-staging', internal_reports=False)
                with self.assertRaisesRegex(SystemExit, 'stale_readiness'):
                    profile.verify_readiness(policy, profile=profile.REVIEWED, mode='media-staging', internal_reports=False)

    def test_each_finished_product_rejects_reports_or_missing_marker(self):
        expected = {"SharingInternalEncryptedReportEnabled": False, "SharingInternalEncryptedReportScope": "", profile.OFF_KEY: True}
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "test.ipa"
            def write(changed=None, key=None, value=None):
                with zipfile.ZipFile(ipa, "w") as archive:
                    for relative in profile.PLISTS:
                        info = app_info(relative != "Info.plist")
                        if relative == changed:
                            if value is None: info.pop(key, None)
                            else: info[key] = value
                        archive.writestr("Payload/NekoWidget.app/" + relative, plistlib.dumps(info))
            write(); profile.verify_ipa(ipa); verify_ipa(ipa, expected)
            for relative in profile.PLISTS:
                for key, value in ((profile.OFF_KEY, None), (profile.OFF_KEY, "NO"),
                                   ("SharingInternalEncryptedReportEnabled", True),
                                   ("GroupReportingProductionEnabled", "YES"),
                                   ("SharingInternalEncryptedReportScope", "internal-owner-first-connection")):
                    write(relative, key, value)
                    with self.assertRaises(ValueError): verify_ipa(ipa, expected)
            for key, value in (("SharingAPIBaseURL", "https://wrong.example"),
                               ("SharingModerationPublicKey", "wrong")):
                write("Info.plist", key, value)
                with self.assertRaises(ValueError): profile.verify_ipa(ipa)

    def test_owner_metadata_cannot_be_relabelled_or_enable_reports(self):
        metadata = dict(schema=profile.OWNER_SCHEMA, distributionProfile=profile.OWNER,
                        releaseMode="media-staging", internalEncryptedReportEnabled=False,
                        internalEncryptedReportScope="", testFlightInternalTestingOnly=True,
                        moderationKeyId="moderation-v2", moderationPublicKey=profile.RECIPIENT)
        self.assertTrue(metadata_settings(metadata)[profile.OFF_KEY])
        for key, value in (("distributionProfile", profile.REVIEWED), ("releaseMode", "production"),
                           ("internalEncryptedReportEnabled", True), ("testFlightInternalTestingOnly", False)):
            with self.assertRaises(ValueError): metadata_settings({**metadata, key: value})

    def test_internal_only_is_forced_without_any_other_pilot(self):
        with tempfile.TemporaryDirectory() as directory:
            options = Path(directory) / 'export.plist'; options.write_bytes(plistlib.dumps({'method': 'app-store-connect'}))
            command = [sys.executable, str(ROOT / 'ci/distribution_profile.py'), '--profile', profile.OWNER,
                       '--mode', 'media-staging', '--internal-reports', 'false']
            result = subprocess.run(command + ['--prepare-export', str(options), '--verify-export', str(options)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIs(plistlib.loads(options.read_bytes())['testFlightInternalTestingOnly'], True)

    def test_owner_metadata_writer_and_upload_validate_the_same_ipa(self):
        spec = importlib.util.spec_from_file_location('media_fixture', ROOT / 'ci/test-media-staging-release-config.py')
        fixture = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixture)
        policy_path = ROOT / 'ci/moderation-client-rollout-policy.json'
        policy = json.loads(policy_path.read_text(encoding='utf-8'))
        import hashlib
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); archive = root / 'NekoWidget.xcarchive'
            info = fixture.write_archive_info_plists(archive, mode='media-staging',
                moderation_key_id='moderation-v2', moderation_public_key=profile.RECIPIENT)
            ipa = root / 'NekoWidget.ipa'; output = root / 'moderation-release-metadata.json'
            with zipfile.ZipFile(ipa, 'w') as bundle:
                for relative in profile.PLISTS:
                    p = info.parent / relative
                    data = plistlib.loads(p.read_bytes()); data.update(app_info(relative != 'Info.plist'))
                    p.write_bytes(plistlib.dumps(data))
                    bundle.writestr('Payload/NekoWidget.app/' + relative, p.read_bytes())
            options = root / 'export.plist'; options.write_bytes(plistlib.dumps({'testFlightInternalTestingOnly': True}))
            command = fixture.metadata_writer_command(info_path=info, output_path=output, archive_path=archive,
                ipa_path=ipa, policy_path=policy_path, policy_sha256=hashlib.sha256(fixture.canonical_json(policy)).hexdigest(),
                release_mode='media-staging', moderation_key_id='moderation-v2', moderation_public_key=profile.RECIPIENT,
                moderation_public_key_sha256=policy['clientPublicKeySha256'],
                trust_manifest_revision=str(policy['trustManifestRevision']), trust_manifest_sha256=policy['trustManifestSha256'])
            command[command.index('--expected-rollout-policy-revision') + 1] = str(policy['revision'])
            command += ['--distribution-profile', profile.OWNER, '--export-options-plist', str(options)]
            result = subprocess.run(command, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(output.read_text())['schema'], profile.OWNER_SCHEMA)
            upload = [sys.executable, str(ROOT / 'ci/verify-moderation-upload-payload.py'),
                '--metadata', str(output), '--ipa', str(ipa), '--expected-source-commit', 'a' * 40,
                '--expected-build-number', '35', '--expected-github-run-id', '123456', '--expected-github-run-attempt', '2',
                '--expected-release-mode', 'media-staging', '--expected-distribution-profile', profile.OWNER]
            result = subprocess.run(upload, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            upload[-1] = profile.REVIEWED
            self.assertNotEqual(subprocess.run(upload, capture_output=True).returncode, 0)

    def test_existing_pending_data_guards_remain_before_reads(self):
        source = (ROOT / 'NekoWidget/Services/GroupReportingProvider.swift').read_text(encoding='utf-8')
        self.assertIn('guard selected || config.isOwnerInternalReportsDisabled else { return GroupReportingPrototype() }', source)
        source = (ROOT / 'NekoWidget/Services/ProductionGroupReporting.swift').read_text(encoding='utf-8')
        self.assertIn('self.reportsDisabled = reportsDisabled || configuration.isOwnerInternalReportsDisabled', source)
        submission = source[source.index('func submitReport(draftID:'):source.index('func reconcile(', source.index('func submitReport(draftID:'))]
        self.assertLess(submission.index('guard !reportsDisabled'), submission.index('try owned(draftID)'))


if __name__ == '__main__':
    unittest.main()
