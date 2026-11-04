import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import production_candidate as candidate

spec=importlib.util.spec_from_file_location('owner',Path(__file__).with_name('production-owner-artifact.py'))
owner=importlib.util.module_from_spec(spec);spec.loader.exec_module(owner)

class OwnerArtifactTests(unittest.TestCase):
    def test_workflow_keeps_upload_behind_owner_selection_and_authenticated_recipient_check(self):
        # Cover the job wiring as well as the executable artifact verifier: a
        # valid local proof must not become an alternative upload route.
        workflow=(candidate.ROOT.parent/'.github/workflows/testflight.yml').read_text(encoding='utf-8')
        for title in ('Install App Store Connect API private key', 'Validate and upload IPA to TestFlight'):
            step=workflow.split('      - name: '+title,1)[1].split('      - name:',1)[0]
            self.assertIn("inputs.upload_to_testflight && (inputs.distribution_profile != 'app-store-candidate' || inputs.production_candidate_owner_only)",step)
        upload=workflow.split('      - name: Validate and upload IPA to TestFlight',1)[1].split('      - name:',1)[0]
        self.assertLess(upload.index('--production-owner-artifact'),upload.index('--upload-app'))
        self.assertIn('PRODUCTION_CANDIDATE_OWNER_UPLOAD_APPROVED: ${{ vars.PRODUCTION_CANDIDATE_OWNER_UPLOAD_APPROVED }}',workflow)

    def test_authenticated_candidate_cannot_change_ipa_export_contract_or_run(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);ipa=root/'candidate.ipa'
            with zipfile.ZipFile(ipa,'w') as z:
                for rel,_,_ in candidate.TARGETS.values():
                    z.writestr('Payload/NekoWidget.app/'+(rel+'/' if rel else '')+'Info.plist',plistlib.dumps({'CFBundleVersion':'328'}))
            contract=candidate.fixture();contract['synthetic']=False
            contract['values']={k:v.replace('candidate.test','neko-fixture.net') if isinstance(v,str) else v for k,v in contract['values'].items()}
            contract['values']['SHARING_MODERATION_PUBLIC_KEY']=base64.urlsafe_b64encode(bytes([68])*32).decode().rstrip('=')
            contract['recipientSHA256']=hashlib.sha256(bytes([68])*32).hexdigest()
            (root/'production-candidate.json').write_text(json.dumps(contract))
            options=plistlib.loads((candidate.ROOT/'ci/ExportOptions.plist.template').read_bytes());options['testFlightInternalTestingOnly']=True
            (root/'ExportOptions.plist').write_bytes(plistlib.dumps(options))
            (root/'production-candidate.tar.gz.enc').write_bytes(b'synthetic encrypted artifact')
            env={'PRODUCTION_CANDIDATE_OWNER_ONLY':'true','DISTRIBUTION_PROFILE':candidate.PROFILE,
                 'RELEASE_SOURCE_SHA':'a'*40,'RELEASE_BUILD_NUMBER':'328','GITHUB_RUN_ID':'123','GITHUB_RUN_ATTEMPT':'1',
                 'SIGNED_ARTIFACT_ENCRYPTION_PASSWORD':'synthetic authentication password only'}
            def run(command):
                with patch('sys.argv',['owner',command,'--root',str(root),'--ipa',str(ipa)]):owner.main()
            with patch.dict(os.environ,env,clear=True):
                run('create');run('verify')
                for file in [ipa,root/'ExportOptions.plist',root/'production-candidate.json',root/'production-owner-metadata.json',root/'production-candidate.tar.gz.enc']:
                    original=file.read_bytes();file.write_bytes(original+b' ')
                    with self.assertRaises((ValueError,SystemExit)):run('verify')
                    file.write_bytes(original)
                with patch.dict(os.environ,{'GITHUB_RUN_ID':'124'}),self.assertRaises(ValueError):run('verify')
                with patch.dict(os.environ,{'PRODUCTION_CANDIDATE_OWNER_ONLY':'false'}),self.assertRaises(ValueError):run('verify')

if __name__=='__main__':unittest.main()
