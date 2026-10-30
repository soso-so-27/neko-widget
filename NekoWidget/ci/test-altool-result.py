#!/usr/bin/env python3
"""Replay the terminal output of 314/315 and incomplete upload outcomes."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('altool_result', Path(__file__).with_name('altool-result.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
verify = module.verify

# Only result lines from run40879571927; no credentials or upload payload.
RECOVERED_314 = '''2026-10-29 13:27:48.441 ERROR: [ContentDelivery.Uploader.6000011244C0] RETRIEVE UPLOAD OPERATIONS (UPLOADING ASSET DESCRIPTION): received status code 500; internal server error. (JMXK75OVI4MDBDRKZPRSWJEBMA) (500)
UPLOAD SUCCEEDED with no errors
Delivery UUID: 88663a67-9f8e-4c33-86e8-80bd748e0a3a
'''
SUCCESS_315 = '''UPLOAD SUCCEEDED with no errors
Delivery UUID: 63ba151d-48dc-4bcc-9558-cadba19e453e
'''


class AltoolResultTests(unittest.TestCase):
    def test_recovered_314_and_successful_315(self):
        verify('upload', RECOVERED_314)
        verify('upload', SUCCESS_315)
        verify('validate', 'VERIFY SUCCEEDED with no errors\n')

    def test_incomplete_or_failed_upload_remains_failure(self):
        for log in (
            '', RECOVERED_314.split('UPLOAD SUCCEEDED')[0],
            'UPLOAD SUCCEEDED with no errors\n',
            SUCCESS_315.replace('UPLOAD SUCCEEDED with no errors\n', ''),
            SUCCESS_315.replace('63ba151d', 'invalid'),
            SUCCESS_315 + 'ERROR: upload failed\n',
            SUCCESS_315 + 'UPLOAD FAILED\n',
            SUCCESS_315 + 'Delivery UUID: 88663a67-9f8e-4c33-86e8-80bd748e0a3a\n',
            'echo "UPLOAD SUCCEEDED with no errors"\n' + SUCCESS_315.split('\n', 1)[1],
        ):
            with self.subTest(log=log), self.assertRaises(ValueError):
                verify('upload', log)

    def test_validation_stays_strict(self):
        with self.assertRaises(ValueError):
            verify('validate', 'ERROR: invalid bundle\nVERIFY SUCCEEDED with no errors\n')

    def test_exit_and_log_write_failures_still_precede_result_verification(self):
        workflow = Path(__file__).resolve().parents[2].joinpath('.github/workflows/testflight.yml').read_text(encoding='utf-8')
        block = workflow.split('run_altool_stage() {', 1)[1].split('run_altool_stage validate', 1)[0]
        check = block.index('ci/altool-result.py')
        self.assertLess(block.index('exit "${statuses[0]}"'), check)
        self.assertLess(block.index('exit "${statuses[1]}"'), check)


if __name__ == '__main__':
    unittest.main()
