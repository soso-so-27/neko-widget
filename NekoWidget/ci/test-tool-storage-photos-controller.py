#!/usr/bin/env python3
"""Owning boundary cases; actual public-CI original seven-job fixture, no API."""
import base64
import copy
import datetime as dt
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch
import zlib

PATH = Path(__file__).with_name('verify-tool-storage-photos-controller.py')
spec = importlib.util.spec_from_file_location('formal_photos_source_guard', PATH)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
# Compressed exact saved original7 records; no user images, secret or live call.
SAVED_JOBS = json.loads(zlib.decompress(base64.b64decode('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')).decode())
SAVED_FIRST_JOBS = json.loads(zlib.decompress(base64.b64decode('eJztlktP20AQx7+KtecYe/2ObwjUVqoEqNAeqFC0Xq9jN2uvtQ8CrfjuHTsOeQhIGqDqoVZymUxmfzOe2fn/QlpowidUmEaj1BuhHyJTKP3+C1U5SjGOPN+FbzxORkiaZtJZ/SSKIx9HgQvGuZCzgov5pCE1Qyn6IGRNuFUYzq2LUmihrFvCq5zoSjSpVWQhwTllfjSOYtdn/jjwaBxTP/CSmI59PE6SiGUYjVDJSD7JJGloCXFrUjVowWAkB0OpdatSxyFtdTStdGmyIypqR7JWKEcJJWz4eLHTsJmw51U+ZdohtKNQDkRRzloaQ2CiNatbqAMeoUbkrM8WnXyZzOan51fh+d1lkhzDk53any/PpktGVRJwy6MMYzcYM+wlLPPypAjCwA9YTMI8whkLPVIkGfHgX69PoHtLzvrb6Vh0zbdqsxb2DyvSnbB9gNJEG2gOBPFazjTLwUhFQ7lREAR+KEjFjWSdWTICDlBSMHuuF9nYtXF45fqpF6Vhcr2IJ5/ziVMXX/fhh6Oe8cJu5zX03jcmq+LeKqo7li+bTwkjKbNIk1tCVtOqgeYsK6WFvO8RWLto9yHEJdOWaS3Ifq+ElaGUKdUhmDpjsm+dHXl5++TVeT2MHrFOSkZnljDaIm0rxS3kBxxaCs7h0MNIvTciDZ8hLaT4yRoLcHND9YGQ/k7IcC/IeANyo1F2dcj+Tb+EDnZCx3tBJxvQX1suyBLXHgihvIx2JT+wvuFO1OQA1AuhtPXGnTD+G6RvN13YfRfek8H9NTfU7itqf7Ib8OuqN3ndYu5j2P0S2lo6nGSMd1c0MhloFGNz2CtKo5t+ZTdM9ksau/DA+vWDR/NQsI+V/mQy63ix56yVI3r0nEph2j6Mu2V7Mkb/OtbUUeKGrv9fHa2ro7NbPf9H1FH/dt5THS0P2GMUZ1XbLswvqCPQNHi3OsL7qSO8po5e7D2rEHJ5T2sh+LBm1iTSu036soCrSa8JFQqy2BryBsi3xnvDtJrjJ8wr/4ebh98CBxbn')))
SAVED_FIRST_RAW = json.loads(zlib.decompress(base64.b64decode('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')))


class SourceGuardTests(unittest.TestCase):
    def setUp(self):
        self.current = copy.deepcopy(guard.QUEUED)
        self.original = copy.deepcopy(guard.ORIGINAL)
        self.jobs = copy.deepcopy(SAVED_JOBS)
        self.now = dt.datetime(2026, 10, 15, 3, 0, tzinfo=dt.timezone.utc)
        self.env = {'GITHUB_EVENT_NAME':'workflow_dispatch', 'GITHUB_REF':'refs/heads/main',
            'GITHUB_REPOSITORY':guard.REPOSITORY, 'GITHUB_RUN_ATTEMPT':'1',
            'GITHUB_RUN_ID':'123', 'GITHUB_SHA':'a'*40,
            'NEKO_FORMAL_PHOTOS_CONTROLLER_REF':'a'*40, 'NEKO_FORMAL_PHOTOS_SOURCE_REF':guard.SOURCE}
    def check(self):
        guard.validate_history(self.current, self.original, self.jobs, self.now)
    def test_exact_saved_failure_and_current_queued_original_seven_accept(self):
        self.check()
        self.assertEqual(self.original['conclusion'], 'failure')
        self.assertEqual(self.current['status'], 'queued')
        self.assertEqual(guard.digest(self.jobs['jobs']), guard.ORIGINAL_JOBS_SHA256)
    def test_new_attempt_job_active_or_queue_metadata_change_rejects(self):
        for key,value in [('run_attempt',2),('status','in_progress'),('status','requested'),
            ('status','completed'),('conclusion','success'),('updated_at','2026-10-15T03:00:00Z')]:
            with self.subTest(key=key,value=value),patch.dict(self.current,{key:value}),self.assertRaises(ValueError):self.check()
        self.jobs['jobs'].append(copy.deepcopy(self.jobs['jobs'][0]));self.jobs['total_count']=8
        with self.assertRaises(ValueError):self.check()
    def test_immutable_failure_source_tree_repo_attempt_or_time_drift_rejects(self):
        for key,value in [('head_sha','b'*40),('conclusion','success'),('run_attempt',True),
            ('created_at','2026-10-15T03:00:00Z'),('head_branch','codex/other')]:
            with self.subTest(key=key),patch.dict(self.original,{key:value}),self.assertRaises(ValueError):self.check()
        for key in ('repository','head_repository','head_commit'):
            with self.subTest(key=key),patch.dict(self.original,{key:{}}),self.assertRaises(ValueError):self.check()
    def test_original_full_job_record_missing_reordered_or_extra_field_rejects(self):
        for kind in ('changed','missing','reordered','extra'):
            payload=copy.deepcopy(SAVED_JOBS)
            if kind=='changed':payload['jobs'][0]['conclusion']='skipped'
            elif kind=='missing':payload['jobs'].pop();payload['total_count']=6
            elif kind=='reordered':payload['jobs'].reverse()
            else:payload['jobs'][0]['unexpected']='unknown'
            with self.subTest(kind=kind),self.assertRaises(ValueError):guard.validate_history(self.current,self.original,payload,self.now)
    def test_stale_history_and_boolean_count_rejects(self):
        with self.assertRaises(ValueError):guard.validate_history(self.current,self.original,self.jobs,self.now+dt.timedelta(days=2))
        self.jobs['total_count']=True
        with self.assertRaises(ValueError):self.check()
    def test_dispatch_main_exact_source_controller_and_attempt_only(self):
        self.assertEqual(guard.validate_environment(self.env),('a'*40,123))
        for key,value in [('GITHUB_EVENT_NAME','push'),('GITHUB_REF','refs/heads/diagnostic/other'),
            ('GITHUB_RUN_ATTEMPT','2'),('GITHUB_REPOSITORY','other/repo'),
            ('NEKO_FORMAL_PHOTOS_SOURCE_REF','b'*40),('NEKO_FORMAL_PHOTOS_CONTROLLER_REF','b'*40),
            ('GITHUB_RUN_ID','1;echo'),('GITHUB_SHA','not-a-sha')]:
            with self.subTest(key=key),patch.dict(self.env,{key:value}),self.assertRaises(ValueError):guard.validate_environment(self.env)
    def controller_fixture(self):
        identity={'state':'active','path':guard.WORKFLOW,'id':guard.FIRST_CONTROLLER['workflow_id']}
        run=copy.deepcopy(guard.FIRST_CONTROLLER)
        run.update(id=123,head_sha='a'*40,run_number=2,status='in_progress',conclusion=None)
        run['head_commit']={'id':'a'*40,'tree_id':'b'*40}
        index={'total_count':2,'workflow_runs':[run,copy.deepcopy(guard.FIRST_CONTROLLER)]}
        return identity,run,index
    def controller_check(self, identity, run, index):
        guard.validate_controller(identity,run,index,'a'*40,123,
            guard.FIRST_CONTROLLER,SAVED_FIRST_JOBS,SAVED_FIRST_RAW)
    def test_only_exact_first_failure_and_one_corrected_current_dispatch(self):
        identity,run,index=self.controller_fixture()
        self.controller_check(identity,run,index)
        for key,value in [('event','push'),('head_sha','b'*40),('head_branch','codex/other'),
            ('run_attempt',2),('run_attempt',True),('conclusion','success'),('status','queued')]:
            with self.subTest(key=key),patch.dict(run,{key:value}),self.assertRaises(ValueError):self.controller_check(identity,run,index)
        index['workflow_runs'].append(copy.deepcopy(run));index['total_count']=3
        with self.assertRaises(ValueError):self.controller_check(identity,run,index)
    def test_global_dispatch_index_rejects_unknown_different_head_missing_or_drift(self):
        self.assertEqual(guard.controller_index_path(), 'repos/' + guard.REPOSITORY
            + '/actions/workflows/tool-storage-photos-validation.yml/runs?event=workflow_dispatch&per_page=100')
        self.assertNotIn('head_sha', guard.controller_index_path())
        for kind in ('unknown','missing','oldattempt','oldstatus','oldextra'):
            identity,run,index=self.controller_fixture()
            if kind=='unknown':index['workflow_runs'][1].update(id=456,head_sha='b'*40)
            elif kind=='missing':index['workflow_runs'].pop();index['total_count']=1
            elif kind=='oldattempt':index['workflow_runs'][1]['run_attempt']=2
            elif kind=='oldstatus':index['workflow_runs'][1]['conclusion']='success'
            else:index['workflow_runs'].append(copy.deepcopy(run));index['total_count']=3
            with self.subTest(kind=kind),self.assertRaises(ValueError):self.controller_check(identity,run,index)
    def test_actual_saved_first_failure_before_mac_and_complete_records_are_pinned(self):
        guard.validate_first_controller(guard.FIRST_CONTROLLER,SAVED_FIRST_JOBS,SAVED_FIRST_RAW)
        with self.assertRaises(ValueError):
            guard.validate_first_controller(guard.FIRST_CONTROLLER,SAVED_FIRST_JOBS,SAVED_FIRST_RAW.removeprefix('\ufeff'))
        self.assertEqual(SAVED_FIRST_JOBS['jobs'][1]['steps'],[])
        for kind in ('run','missing','attempt','step','newjob','raw'):
            run=copy.deepcopy(guard.FIRST_CONTROLLER);jobs=copy.deepcopy(SAVED_FIRST_JOBS);raw=SAVED_FIRST_RAW
            if kind=='run':run['conclusion']='success'
            elif kind=='missing':jobs['jobs'].pop();jobs['total_count']=1
            elif kind=='attempt':jobs['jobs'][0]['run_attempt']=2
            elif kind=='step':jobs['jobs'][0]['steps'][3]['conclusion']='skipped'
            elif kind=='newjob':jobs['jobs'].append(copy.deepcopy(jobs['jobs'][0]));jobs['total_count']=3
            else:raw+='changed'
            with self.subTest(kind=kind),self.assertRaises(ValueError):guard.validate_first_controller(run,jobs,raw)
    def test_product_checkouts_depth_two_only_and_unchanged_full_harness(self):
        workflow=PATH.parents[2]/'.github/workflows/tool-storage-photos-validation.yml'
        text=workflow.read_text(encoding='utf-8')
        blocks=text.split('      - name: Check out frozen product\n')[1:]
        self.assertEqual(len(blocks),2)
        for block in blocks:
            block=block.split('      - name:',1)[0]
            self.assertIn('          fetch-depth: 2\n',block)
            self.assertIn('          ref: '+guard.SOURCE+'\n',block)
            self.assertIn('          path: product\n',block)
        self.assertEqual(text.count('fetch-depth:'),2)
        self.assertEqual(text.count('run: bash ci/run-simulator-smoke.sh'),1)

    def test_source_checkout_tree_parents_dirty_or_harness_change_rejects(self):
        controller=Path('controller');product=Path('product')
        values={('controller',('rev-parse','HEAD')):'a'*40,
            ('controller',('status','--porcelain=v1','--untracked-files=all')):'',
            ('product',('rev-parse','HEAD')):guard.SOURCE,
            ('product',('rev-parse','HEAD^{tree}')):guard.TREE,
            ('product',('show','-s','--format=%P','HEAD')):' '.join(guard.PARENTS),
            ('product',('status','--porcelain=v1','--untracked-files=all')):''}
        def fakegit(root,*args):return values[(str(root),args)]
        # Hash mock isolates the source identity boundary, not a live harness pass.
        class Hash:
            def hexdigest(self):return guard.HARNESS_SHA256
        with patch.object(guard,'git',side_effect=fakegit),patch.object(Path,'read_bytes',return_value=b'fixture'),patch.object(guard.hashlib,'sha256',return_value=Hash()):
            guard.verify_local(controller,product,self.env)
            for key in list(values):
                original=values[key];values[key]='' if key[1]==('show','-s','--format=%P','HEAD') else 'unknown'
                with self.subTest(key=key),self.assertRaises(ValueError):guard.verify_local(controller,product,self.env)
                values[key]=original
        with patch.object(guard,'git',side_effect=fakegit),patch.object(Path,'read_bytes',return_value=b'changed'):
            with self.assertRaises(ValueError):guard.verify_local(controller,product,self.env)


if __name__ == '__main__':
    unittest.main()
