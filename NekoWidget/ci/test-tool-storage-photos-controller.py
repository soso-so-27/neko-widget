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
    def test_controller_single_actual_in_progress_dispatch_not_another_run(self):
        identity={'state':'active','path':guard.WORKFLOW,'id':99}
        run={'id':123,'head_sha':'a'*40,'head_branch':'main','event':'workflow_dispatch',
            'path':guard.WORKFLOW,'workflow_id':99,'run_attempt':1,'status':'in_progress','conclusion':None,
            'repository':{'full_name':guard.REPOSITORY,'id':1335079243},
            'head_repository':{'full_name':guard.REPOSITORY,'id':1335079243}}
        index={'total_count':1,'workflow_runs':[run]}
        guard.validate_controller(identity,run,index,'a'*40,123)
        for key,value in [('event','push'),('head_sha','b'*40),('head_branch','codex/other'),
            ('run_attempt',2),('conclusion','success'),('status','queued')]:
            with self.subTest(key=key),patch.dict(run,{key:value}),self.assertRaises(ValueError):guard.validate_controller(identity,run,index,'a'*40,123)
        index['workflow_runs'].append(copy.deepcopy(run));index['total_count']=2
        with self.assertRaises(ValueError):guard.validate_controller(identity,run,index,'a'*40,123)
    def test_global_dispatch_index_exposes_extra_different_controller_head(self):
        self.assertEqual(guard.controller_index_path(), 'repos/' + guard.REPOSITORY
            + '/actions/workflows/tool-storage-photos-validation.yml/runs?event=workflow_dispatch&per_page=100')
        self.assertNotIn('head_sha', guard.controller_index_path())
        identity={'state':'active','path':guard.WORKFLOW,'id':99}
        run={'id':123,'head_sha':'a'*40,'head_branch':'main','event':'workflow_dispatch',
            'path':guard.WORKFLOW,'workflow_id':99,'run_attempt':1,'status':'in_progress','conclusion':None,
            'repository':{'full_name':guard.REPOSITORY,'id':1335079243},
            'head_repository':{'full_name':guard.REPOSITORY,'id':1335079243}}
        other=copy.deepcopy(run);other.update(id=456,head_sha='b'*40)
        index={'total_count':2,'workflow_runs':[run,other]}
        with self.assertRaises(ValueError):guard.validate_controller(identity,run,index,'a'*40,123)
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
                original=values[key];values[key]='unknown'
                with self.subTest(key=key),self.assertRaises(ValueError):guard.verify_local(controller,product,self.env)
                values[key]=original
        with patch.object(guard,'git',side_effect=fakegit),patch.object(Path,'read_bytes',return_value=b'changed'):
            with self.assertRaises(ValueError):guard.verify_local(controller,product,self.env)


if __name__ == '__main__':
    unittest.main()
