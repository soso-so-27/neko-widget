#!/usr/bin/env python3
"""Behavioral coverage for selecting and reusing iOS checks (no network)."""

import copy
import contextlib
import datetime as dt
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

import ios_ci_scope as scope


spec = importlib.util.spec_from_file_location("planner", Path(__file__).with_name("plan-ios-ci.py"))
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)


class BoundedBillingReactivationTests(unittest.TestCase):
    def setUp(self):
        self.products = dict(planner.BILLING_REACTIVATION_BLOBS)
        self.paths = list(self.products)
        self.rows = '100644 blob ' + 'c'*40 + '\tNekoWidget/NekoWidget/App/Unchanged.swift\0'
        self.closure = hashlib.sha256(self.rows.encode()).hexdigest()
        self.registration = 'BILLING_REACTIVATION_VERSION = "bounded-existing-owner-window-v1"'
        self.bad = None

    def git(self, *args):
        if args[0] == 'merge-base': return 'approved'
        if args[0] == 'show': return '' if self.bad == 'unapproved' else self.registration
        if args[:3] == ('ls-tree', '-r', '-z'):
            return self.rows + ('100644 blob ' + 'd'*40 + '\tunknown.txt\0' if self.bad == 'closure' else '')
        if args[0] == 'ls-tree':
            blob = ('b' if self.bad == 'control' and args[1] == 'head' else 'a') * 40
            return f'100644 blob {blob}\t{args[-1]}'
        if args[0] == 'diff':
            records = []
            for path, pair in self.products.items():
                fields = [':100644', '100644', *pair, 'M']
                if self.bad == 'mode': fields[1] = '100755'
                if self.bad == 'blob': fields[3] = 'e'*40
                if self.bad == 'delete': fields[1] = '000000'; fields[4] = 'D'
                records.extend([' '.join(fields), path])
            if 'handoffs/bounded-test.md' in self.paths:
                records.extend([':000000 100644 ' + '0'*40 + ' ' + 'f'*40 + ' A', 'handoffs/bounded-test.md'])
            return '\0'.join(records) + '\0'
        raise AssertionError(args)

    def qualifies(self, paths=None):
        with patch.object(planner, 'git', side_effect=self.git), \
                patch.object(planner, 'BILLING_REACTIVATION_CLOSURE_SHA256', self.closure):
            return planner.billing_backend_only(self.paths if paths is None else paths, 'base', 'head')

    def test_exact_two_products_require_fresh_backend_jobs(self):
        self.assertTrue(self.qualifies())
        self.assertEqual(planner.required_jobs(self.paths, planner.BILLING_SCOPE),
                         (planner.BILLING_CALLER_JOB, planner.PRESERVATION_JOB))
        self.paths.append('handoffs/bounded-test.md')
        self.assertTrue(self.qualifies())

    def test_unapproved_controls_modes_unknown_inputs_and_product_tampering_fail(self):
        for bad in ('unapproved', 'control', 'mode', 'blob', 'delete', 'closure'):
            with self.subTest(bad=bad):
                self.bad = bad
                self.assertFalse(self.qualifies())
        self.bad = None
        for extra in ('NekoWidget/NekoWidget/App/Changed.swift', '.github/workflows/sharing-service.yml',
                      'NekoWidget/SharingService/package-lock.json', 'NekoWidget/ci/plan-ios-ci.py'):
            with self.subTest(extra=extra):
                with patch.object(planner, 'git', side_effect=self.git):
                    self.assertFalse(planner.billing_reactivation_backend_only(self.paths + [extra], 'base', 'head'))
        self.assertFalse(self.qualifies(self.paths + [self.paths[0]]))
        with patch.object(planner, 'git', side_effect=self.git):
            self.assertFalse(planner.billing_reactivation_backend_only(self.paths[:1], 'base', 'head'))

    def test_invalid_registration_and_closure_are_rejected(self):
        with patch.object(planner, 'BILLING_REACTIVATION_CONTROLS', frozenset()):
            self.assertFalse(self.qualifies())
        with patch.object(planner, 'git', side_effect=self.git), \
                patch.object(planner, 'BILLING_REACTIVATION_CLOSURE_SHA256', 'invalid'):
            self.assertFalse(planner.billing_reactivation_backend_only(self.paths, 'base', 'head'))
        for pair in (['0'*40, 'b'*40], ['a'*40, 'a'*40], ['invalid', 'b'*40]):
            changed = dict(self.products); changed[self.paths[0]] = pair
            with patch.object(planner, 'BILLING_REACTIVATION_BLOBS', changed):
                self.assertFalse(self.qualifies())


class OwnerCloudCorrectionTests(unittest.TestCase):
    def setUp(self):
        self.now=dt.datetime(2026,10,11,8,tzinfo=dt.timezone.utc)
        self.head="a"*40; self.sha=planner.OWNER_CLOUD_CORRECTION_SOURCE
        self.branch=planner.OWNER_CLOUD_CORRECTION_BRANCH; self.repo="soso-so-27/neko-widget"
        self.required=planner.required_jobs_from_scope(scope.OWNER_CLOUD_SCOPE)
        self.run={"id":planner.OWNER_CLOUD_CORRECTION_RUN,"head_sha":self.sha,"head_branch":self.branch,
            "workflow_id":335014238,"path":".github/workflows/ios-build.yml","event":"push","run_attempt":1,
            "status":"completed","conclusion":"failure","updated_at":self.now.isoformat(),
            "repository":{"full_name":self.repo},"head_repository":{"full_name":self.repo}}
        def job(name,identifier,conclusion="success",steps=()):
            return {"name":name,"id":identifier,"run_id":self.run["id"],"head_sha":self.sha,"run_attempt":1,
                "status":"completed","conclusion":conclusion,"completed_at":self.now.isoformat(),
                "steps":[{"name":n,"status":"completed","conclusion":"success"} for n in steps]}
        self.native=[job(planner.PLAN_JOB,1,steps=("Select checks",)),
            job(planner.BUILD,planner.OWNER_CLOUD_CORRECTION_BUILD_JOB,"failure",("Verify sharing release privacy gates",)),
            job(self.required[1],planner.OWNER_CLOUD_CORRECTION_RUNTIME_JOB,steps=planner.OWNER_CLOUD_RUNTIME_STEPS)]
        self.native[1]["steps"][0]["conclusion"]="failure"
        self.backend=dict(self.run,id=planner.OWNER_CLOUD_CORRECTION_BACKEND_RUN,path=".github/workflows/sharing-service.yml")
        self.backend_jobs=[job(n,10+i) for i,n in enumerate(planner.PRESERVATION_EXPORT_BACKEND_JOBS["sharing-service.yml"])]
        for j in self.backend_jobs:j["run_id"]=self.backend["id"]
        worker=next(j for j in self.backend_jobs if j["name"]=="Typecheck, test, and bundle Worker")
        worker.update(id=planner.OWNER_CLOUD_CORRECTION_WORKER_JOB,conclusion="failure",
                      steps=[{"name":"Run Worker, D1, staging, moderation, and key ceremony tests","status":"completed","conclusion":"failure"}])
        self.backend_jobs.append(dict(job("Validate private billing caller",114415116222,"skipped"),run_id=self.backend["id"]))
        self.plan={"schema_version":1,"repository":self.repo,"head_sha":self.sha,"scope":scope.OWNER_CLOUD_SCOPE,
            "required_jobs":list(self.required),"required_backend_runs":planner.moderation_resolution_requirements(self.sha),
            "evidence_run_id":None,"evidence_sha":None,"test_correction_evidence":None}

    def proof(self):
        def api(path):
            if path.endswith('/runs/'+str(self.backend['id'])):return self.backend
            if path.endswith('/jobs/1/logs'):return 'IOS_CI_PLAN_JSON='+json.dumps(self.plan)
            return 'fixture owning log'
        with patch.object(planner,"owner_cloud_correction_inputs",return_value=True), \
             patch.object(planner,"executed_jobs",side_effect=lambda r,*a:self.native if r['id']==self.run['id'] else self.backend_jobs), \
             patch.object(planner,"owner_cloud_failure_log",return_value=True):
            return planner.owner_cloud_correction_source(self.run,self.head,self.branch,self.repo,335014238,self.required,api,self.now)

    def test_original_runtime_stays_on_original_sha_and_pending_wrong_attempt_stale_or_extra_failure_rejected(self):
        p=self.proof(); self.assertEqual(p['sha'],self.sha)
        self.assertEqual(p['jobs'],[{'name':self.required[1],'job_id':planner.OWNER_CLOUD_CORRECTION_RUNTIME_JOB}])
        self.assertEqual(p['owning_jobs_to_execute'],[planner.BUILD])
        for key,value in [('status','in_progress'),('run_attempt',2),('head_sha',self.head),('head_branch','codex/other'),('updated_at',(self.now-dt.timedelta(hours=25)).isoformat())]:
            old=self.run[key];self.run[key]=value
            with self.subTest(key=key):self.assertIsNone(self.proof())
            self.run[key]=old
        for key,value in [('conclusion','skipped'),('head_sha',self.head),('id',123),('run_attempt',2)]:
            old=self.native[2][key];self.native[2][key]=value
            with self.subTest(runtime=key):self.assertIsNone(self.proof())
            self.native[2][key]=old
        self.native[2]['steps'][1]['conclusion']='skipped';self.assertIsNone(self.proof())
        self.native[2]['steps'][1]['conclusion']='success'
        self.native[1]['steps'].append({'name':'unrelated failure','status':'completed','conclusion':'failure'})
        self.assertIsNone(self.proof())

    def test_source_backend_accepts_only_exact_five_job_inventory_and_fixed_empty_skip(self):
        self.assertEqual(len(self.backend_jobs),5)
        self.assertIsNotNone(self.proof())
        original=copy.deepcopy(self.backend_jobs)
        for key,value in [('id',114415116223),('name','Other skipped job'),
                          ('run_id',38120852417),('head_sha',self.head),('run_attempt',2),
                          ('status','in_progress'),('conclusion','success'),
                          ('steps',[{'name':'unexpected','status':'completed','conclusion':'skipped'}])]:
            self.backend_jobs=copy.deepcopy(original);self.backend_jobs[-1][key]=value
            with self.subTest(placeholder=key):self.assertIsNone(self.proof())
        for inventory in [original[:-1],original+[dict(original[-1],id=123)],
                          original[:-1]+[copy.deepcopy(original[0])]]:
            self.backend_jobs=copy.deepcopy(inventory)
            with self.subTest(inventory=len(inventory)):self.assertIsNone(self.proof())
        for index in range(4):
            self.backend_jobs=copy.deepcopy(original)
            self.backend_jobs[index].update(conclusion='skipped',steps=[])
            with self.subTest(executed=index):self.assertIsNone(self.proof())
        self.backend_jobs=original

    def test_fixed_input_closure_requires_exact_repair_and_main_approval(self):
        rows={p:[':000000' if b=='0'*40 else ':100644','100644',b,a,'A' if b=='0'*40 else 'M'] for p,(b,a) in scope.OWNER_CLOUD_CORRECTION_BLOBS.items()}
        def accepts(changed,approved=True):
            def git(*args):
                if args[0]=='merge-base':return 'approved'
                if args[0]=='show':return 'OWNER_CLOUD_CORRECTION_SOURCE = "'+self.sha+'"' if approved else ''
                if args[0]=='diff':return ''.join(' '.join(v)+'\0'+p+'\0' for p,v in changed.items())
                if args[0]=='ls-tree':return '100644 blob '+'c'*40+'\t'+args[-1]
                raise AssertionError(args)
            with patch.object(planner,'git',side_effect=git):return planner.owner_cloud_correction_inputs(self.head)
        self.assertTrue(accepts(rows));self.assertFalse(accepts(rows,False))
        partial=copy.deepcopy(rows);partial.pop(next(iter(rows)));self.assertFalse(accepts(partial))
        unknown=copy.deepcopy(rows);unknown['NekoWidget/SharingService/src/other.ts']=[':100644','100644','c'*40,'d'*40,'M'];self.assertFalse(accepts(unknown))
        for i,v in [(0,':100755'),(1,'120000'),(3,'f'*40),(4,'D')]:
            changed=copy.deepcopy(rows);changed[next(iter(rows))][i]=v;self.assertFalse(accepts(changed))

    def test_failure_diagnosis_requires_reviewed_normalized_bytes(self):
        text='FAIL: test_testflight_checks_the_exact_policy_profile_before_signing (__main__.PublicPolicySiteTests.test_testflight_checks_the_exact_policy_profile_before_signing)\nAssertionError: 4014 not less than 3835\nFAILED (failures=1)\n##[error]Process completed with exit code 1.'
        digest=planner.hashlib.sha256(text.encode()).hexdigest()
        with patch.object(planner,'OWNER_CLOUD_CORRECTION_BUILD_LOG_SHA256',digest):
            self.assertTrue(planner.owner_cloud_failure_log(text))
            stamped='\n'.join('2026-10-11T07:18:37.123Z '+line for line in text.splitlines())
            self.assertTrue(planner.owner_cloud_failure_log(stamped))
            self.assertFalse(planner.owner_cloud_failure_log(text+'\nother failure'))
        self.assertFalse(planner.owner_cloud_failure_log(text))

    def test_fresh_graph_requires_full_build_and_new_sha_backends(self):
        proof=self.proof();run=dict(self.run,id=99,head_sha=self.head,conclusion='success')
        jobs=copy.deepcopy(self.native[:2])
        for j in jobs:j.update(head_sha=self.head,run_id=99,conclusion='success')
        jobs[1]['steps']=[{'name':n,'status':'completed','conclusion':'success'} for n in planner.moderation_build_steps()]
        plan=dict(self.plan,head_sha=self.head,required_backend_runs=planner.moderation_resolution_requirements(self.head),test_correction_evidence=proof)
        api=lambda path:'IOS_CI_PLAN_JSON='+json.dumps(plan) if path.endswith('/logs') else self.run
        with patch.object(planner,'owner_cloud_correction_inputs',return_value=True),patch.object(planner,'owner_cloud_correction_source',return_value=proof),patch.object(planner,'moderation_resolution_backend_evidence',return_value={'fresh':True}) as backend:
            got=planner.owner_cloud_correction_graph(run,self.head,self.required,api,self.now,jobs)
            self.assertEqual(got['runtime_evidence']['sha'],self.sha);self.assertEqual(backend.call_args.args[0],self.head)
            jobs[1]['steps'][2]['conclusion']='skipped'
            self.assertIsNone(planner.owner_cloud_correction_graph(run,self.head,self.required,api,self.now,jobs))
            jobs[1]['steps'][2]['conclusion']='success'
            with patch.object(planner,'moderation_resolution_backend_evidence',side_effect=ValueError('wrong SHA')):
                with self.assertRaises(ValueError):planner.owner_cloud_correction_graph(run,self.head,self.required,api,self.now,jobs)

    def test_correction_immutable_tree_pins_actual_base_and_original_source(self):
        for ref in ('3b8dfc68cf1fc66b20f55172f0c9879c4ebd02e4',self.sha):
            records=[r for r in planner.git('ls-tree','-r','-z',ref).split('\0') if r]
            immutable=[r for r in records if not planner.is_handoff(r.split('\t')[1]) and r.split('\t')[1] not in scope.OWNER_CLOUD_CORRECTED_PATHS | scope.OWNER_CLOUD_CONTROLS]
            self.assertEqual(len(immutable),1103)
            self.assertEqual(planner.hashlib.sha256(('\0'.join(immutable)+'\0').encode()).hexdigest(),scope.OWNER_CLOUD_CORRECTION_TREE_SHA256)

    def test_corrected_full_batch_uses_original_base_and_final_after_for_shared_paths(self):
        products=dict(scope.OWNER_CLOUD_BLOBS)
        for path,(before,after) in scope.OWNER_CLOUD_CORRECTION_BLOBS.items():
            products[path]=(scope.OWNER_CLOUD_BLOBS[path][0] if path in scope.OWNER_CLOUD_BLOBS else before,after)
        rows={p:[':000000' if b=='0'*40 else ':100644','100644',b,a,'A' if b=='0'*40 else 'M'] for p,(b,a) in products.items()}
        tree='100644 blob '+'c'*40+'\tNekoWidget/Shared/Unchanged.swift\0'
        def git(*args):
            if args[0]=='diff':return ''.join(' '.join(v)+'\0'+p+'\0' for p,v in rows.items())
            if args[:3]==('ls-tree','-r','-z'):return tree
            raise AssertionError(args)
        with patch.object(planner,'git',side_effect=git),patch.object(planner,'owner_cloud_control_approved',return_value=True),patch.object(planner,'owner_cloud_correction_inputs',return_value=True),patch.object(planner,'OWNER_CLOUD_CORRECTION_TREE_SHA256',planner.hashlib.sha256(tree.encode()).hexdigest()):
            self.assertTrue(planner.owner_cloud_only(list(rows),'base',self.head))
            self.assertTrue(scope.accepts_paths(scope.OWNER_CLOUD_SCOPE,list(rows)))
            path='NekoWidget/ci/moderation-v2-readiness.json'
            rows[path][2]=scope.OWNER_CLOUD_CORRECTION_BLOBS[path][0]
            self.assertFalse(planner.owner_cloud_only(list(rows),'base',self.head))


class OwnerCloudScopeTests(unittest.TestCase):
    def test_frozen_actual_base_tree_digest_matches_declared_pin(self):
        records = [r for r in planner.git("ls-tree", "-r", "-z", "3b8dfc68cf1fc66b20f55172f0c9879c4ebd02e4").split("\0") if r]
        immutable = [r for r in records if not planner.is_handoff(r.split("\t", 1)[1])
                     and r.split("\t", 1)[1] not in planner.OWNER_CLOUD_PATHS | planner.OWNER_CLOUD_CONTROLS]
        self.assertEqual(len(immutable), 1107)
        self.assertEqual(planner.hashlib.sha256(("\0".join(immutable)+"\0").encode()).hexdigest(),
                         planner.OWNER_CLOUD_IMMUTABLE_TREE_SHA256)

    def rows(self):
        return {p: [":000000" if b == "0" * 40 else ":100644", "100644", b, a,
                    "A" if b == "0" * 40 else "M"] for p, (b, a) in planner.OWNER_CLOUD_BLOBS.items()}

    def accepts(self, rows=None, *, approved=True, mutate_tree=False):
        rows = self.rows() if rows is None else rows
        tree = "100644 blob " + "c" * 40 + "\tNekoWidget/Shared/Unchanged.swift\0"
        digest = planner.hashlib.sha256(tree.encode()).hexdigest()
        def git(*args):
            if args[0] == "diff":
                return "".join(" ".join(f) + "\0" + p + "\0" for p, f in rows.items())
            if args[:3] == ("ls-tree", "-r", "-z"):
                return tree.replace("c" * 40, "d" * 40) if mutate_tree and args[3] == "head" else tree
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git), patch.object(planner, "owner_cloud_control_approved", return_value=approved), patch.object(planner, "OWNER_CLOUD_IMMUTABLE_TREE_SHA256", digest):
            return planner.owner_cloud_only(list(rows), "base", "head")

    def test_closed_batch_keeps_full_build_runtime_without_ui(self):
        self.assertTrue(self.accepts())
        self.assertEqual(scope.lanes(scope.OWNER_CLOUD_SCOPE), ("runtime",))
        self.assertEqual(scope.lane_tests(scope.OWNER_CLOUD_SCOPE, "runtime"), ())
        self.assertEqual(planner.required_jobs(list(self.rows()), scope.OWNER_CLOUD_SCOPE),
                         (planner.BUILD, scope.lane_job(scope.OWNER_CLOUD_SCOPE, "runtime")))

    def test_partial_unknown_mode_delete_content_control_and_immutable_change_fail_closed(self):
        rows = self.rows(); first = next(iter(rows))
        mutations=[]
        partial=copy.deepcopy(rows); del partial[first]; mutations.append(partial)
        unknown=copy.deepcopy(rows); unknown["NekoWidget/Views/New.swift"]=[":000000","100644","0"*40,"f"*40,"A"]; mutations.append(unknown)
        for index,value in ((0,":100755"),(1,"120000"),(3,"f"*40),(4,"D")):
            changed=copy.deepcopy(rows); changed[first][index]=value; mutations.append(changed)
        for changed in mutations:
            with self.subTest(changed=changed[first] if first in changed else "partial"):
                self.assertFalse(self.accepts(changed))
        self.assertFalse(self.accepts(approved=False))
        self.assertFalse(self.accepts(mutate_tree=True))

    def test_controls_must_match_main_approved_tree_in_both_revisions(self):
        def git(*args):
            if args[0] == "merge-base": return "approved"
            return "100644 blob " + ("d" if args[1] == "head" else "c") * 40 + "\t" + args[-1]
        with patch.object(planner,"git",side_effect=git):
            self.assertFalse(planner.owner_cloud_control_approved("base","head"))

    def test_native_steps_cannot_be_skipped_or_replaced_by_build_only(self):
        sha="a"*40; now=dt.datetime.now(dt.timezone.utc)
        required=planner.required_jobs_from_scope(scope.OWNER_CLOUD_SCOPE)
        build_steps=planner.moderation_build_steps()
        jobs=[{"name":name,"id":i+1,"head_sha":sha,"status":"completed","conclusion":"success","completed_at":now.isoformat(),
               "steps":[{"name":n,"status":"completed","conclusion":"success"} for n in
                        (build_steps if name==planner.BUILD else ("Check out repository","Run sharing runtime matrix","Upload sharing runtime matrix artifacts"))]}
              for i,name in enumerate(required)]
        self.assertTrue(planner.owner_cloud_native_evidence(jobs,sha,now))
        with self.assertRaises(ValueError): planner.owner_cloud_native_evidence(jobs[:1],sha,now)
        jobs[0]["steps"][3]["conclusion"]="skipped"
        with self.assertRaises(ValueError): planner.owner_cloud_native_evidence(jobs,sha,now)


class ModerationBuildCorrectionTests(unittest.TestCase):
    def setUp(self):
        self.source, self.head = planner.MODERATION_BUILD_CORRECTION_SOURCE, planner.MODERATION_BUILD_CORRECTION_PRODUCT
        self.now = dt.datetime(2026, 10, 9, 16, tzinfo=dt.timezone.utc)
        self.repo = "soso-so-27/neko-widget"
        self.required = planner.required_jobs_from_scope(planner.MODERATION_RESOLUTION_SCOPE)
        self.run = {"id": planner.MODERATION_BUILD_CORRECTION_RUN, "head_sha": self.source,
            "head_branch": planner.MODERATION_BUILD_CORRECTION_BRANCH, "workflow_id": 335014238,
            "path": ".github/workflows/ios-build.yml", "event": "push", "run_attempt": 1,
            "repository": {"full_name": self.repo}, "head_repository": {"full_name": self.repo},
            "status": "completed", "conclusion": "failure", "updated_at": self.now.isoformat()}
        self.build_steps = ("Check out repository", "Verify Xcode installation", "Verify sharing release privacy gates",
                            planner.MODERATION_BUILD_FAILED_STEP, "Verify Swift pairing protocol vectors",
                            "Build disabled app and extensions for iOS Simulator")
        self.jobs = []
        for name, job_id in planner.MODERATION_BUILD_SOURCE_JOBS.items():
            names = self.build_steps if name == planner.BUILD else ("Select checks",) if name == planner.PLAN_JOB else ("Run Simulator smoke test",) if name == planner.BOOTSTRAP_SMOKE else ("Run sharing runtime matrix",)
            steps = [{"name": step, "status": "completed", "conclusion": "success"} for step in names]
            if name == planner.BUILD:
                for n in range(3, len(steps)): steps[n]["conclusion"] = "failure" if n == 3 else "skipped"
            self.jobs.append({"id": job_id, "name": name, "head_sha": self.source,
                "run_id": self.run["id"], "run_attempt": 1, "status": "completed",
                "conclusion": "failure" if name == planner.BUILD else "success",
                "completed_at": self.now.isoformat(), "steps": steps})
        self.record = {"repository": self.repo, "schema_version": 1, "head_sha": self.source,
            "scope": planner.MODERATION_RESOLUTION_SCOPE, "required_jobs": list(self.required),
            "required_backend_runs": planner.moderation_resolution_requirements(self.source),
            "evidence_run_id": None, "evidence_sha": None, "test_correction_evidence": None}
        self.failure = ("FAIL: test_source_does_not_advance_expiry_boundary (__main__.WindowPresentation.test_source_does_not_advance_expiry_boundary)\n"
            "AssertionError: 'func isVisible(at now: Date) -> Bool { now < displayUntil }' not found\nRan 9 tests in 4.217s\nFAILED (failures=1)")
        self.backends = {name: {"run_id": identifier, "sha": self.source} for name, identifier in
            (("sharing-service.yml", 37944559756), ("preservation-service.yml", 37944559715))}

    def api(self, path):
        if path.endswith(f"/{self.run['id']}"): return self.run
        if "/jobs?" in path: return {"total_count": len(self.jobs), "jobs": self.jobs}
        if path.endswith(f"/{planner.MODERATION_BUILD_SOURCE_JOBS[planner.PLAN_JOB]}/logs"):
            return "IOS_CI_PLAN_JSON=" + json.dumps(self.record)
        if path.endswith(f"/{planner.MODERATION_BUILD_SOURCE_JOBS[planner.BUILD]}/logs"): return self.failure
        raise AssertionError(path)

    def verify(self, run=None):
        with patch.object(planner, "moderation_build_correction_inputs", return_value=True), \
                patch.object(planner, "moderation_build_steps", return_value=self.build_steps), \
                patch.object(planner, "moderation_resolution_backend_evidence", return_value=self.backends), \
                patch.object(planner, "moderation_build_candidate_backend_gate"):
            return planner.moderation_build_correction_source(run or self.run, self.head, self.run["head_branch"],
                self.repo, 335014238, self.required, self.api, self.now)

    def test_source_requires_actual_three_native_successes_and_only_known_build_failure(self):
        proof = self.verify()
        self.assertEqual(len(proof["jobs"]), 3)
        self.assertEqual(proof["owning_jobs_to_execute"], [planner.BUILD])
        self.assertEqual(planner.correction_owning_jobs(planner.MODERATION_RESOLUTION_SCOPE, self.source), (planner.BUILD,))
        for field, value in (("status", "in_progress"), ("conclusion", "success"), ("event", "workflow_dispatch"),
                ("head_sha", "f" * 40), ("run_attempt", 2), ("head_branch", "main"), ("workflow_id", 2),
                ("updated_at", "2020-01-01T00:00:00Z"), ("head_repository", {"full_name": "other/repo"})):
            with self.subTest(field=field): self.assertIsNone(self.verify(self.run | {field: value}))
        original = copy.deepcopy(self.jobs)
        for index, job in enumerate(original):
            for field, value in (("status", "in_progress"), ("conclusion", "skipped"), ("head_sha", "e" * 40),
                                 ("run_attempt", 2), ("id", 2), ("completed_at", "2020-01-01T00:00:00Z")):
                if job["name"] == planner.BUILD and field == "completed_at": continue
                self.jobs = copy.deepcopy(original); self.jobs[index][field] = value
                with self.subTest(job=job["name"], field=field): self.assertIsNone(self.verify())
            self.jobs = copy.deepcopy(original); self.jobs[index]["steps"] = []
            self.assertIsNone(self.verify())
        self.jobs = original + [copy.deepcopy(original[0])]; self.assertIsNone(self.verify())
        self.jobs = original
        failure = self.failure
        for invalid in (failure + "\nERROR: another", failure.replace("failures=1", "failures=2"), "", failure.replace("test_source_does_not", "test_other")):
            self.failure = invalid; self.assertIsNone(self.verify())
        self.failure = failure
        self.record["test_correction_evidence"] = {"run_id": 1}; self.assertIsNone(self.verify())

    def test_input_closure_fixed_pair_approved_controls_and_normal_handoffs_only(self):
        before, after = planner.MODERATION_BUILD_CORRECTION_BLOBS
        row = f":100644 100644 {before} {after} M\0{planner.MODERATION_RESOLUTION_BUILD_TEST}\0"
        def check(raw=row, *, unapproved=None, registered=True, ancestor=True):
            def git(*args):
                if args[0] == "diff": return raw
                if args[:2] == ("merge-base", "--is-ancestor") and not ancestor: raise subprocess.CalledProcessError(1, "git")
                if args[0] == "merge-base": return "a" * 40
                if args[0] == "show": return f'MODERATION_BUILD_CORRECTION_SOURCE = "{self.source}"' if registered else "old"
                if args[0] == "ls-tree":
                    return f"100644 blob {'d' * 40 if args[1] == self.head and args[3] == unapproved else 'c' * 40}\t{args[3]}"
                raise AssertionError(args)
            with patch.object(planner, "git", side_effect=git): return planner.moderation_build_correction_inputs(self.source, self.head)
        self.assertTrue(check())
        for path in planner.MODERATION_BUILD_CORRECTION_CONTROLS:
            self.assertTrue(check(row + f":100644 100644 {'b' * 40} {'c' * 40} M\0{path}\0"))
            self.assertFalse(check(unapproved=path))
        self.assertTrue(check(row + f":000000 100644 {'0' * 40} {'c' * 40} A\0handoffs/review.md\0"))
        for invalid in ("", row + row, row.replace(before, "d" * 40), row.replace(after, "c" * 40),
                row.replace("100644", "100755"), row.replace("100644", "120000"), row.replace(" M\0", " D\0"),
                row + f":100644 100644 {'b' * 40} {'c' * 40} M\0.gitattributes\0",
                row + f":100644 100644 {'b' * 40} {'c' * 40} M\0.github/workflows/ios-build.yml\0"):
            self.assertFalse(check(invalid), invalid)
        self.assertFalse(check(registered=False)); self.assertFalse(check(ancestor=False))

    def test_candidate_backend_absence_allowed_failure_active_and_wrong_identity_block(self):
        identity = {"id": 8, "state": "active", "path": ".github/workflows/sharing-service.yml"}
        candidate = self.run | {"id": 88, "head_sha": self.head, "conclusion": "success", "workflow_id": 8, "path": identity["path"]}
        def check(rows, count=None):
            def api(path):
                workflow = path.split("/workflows/", 1)[1].split("/", 1)[0]
                if "/runs?" not in path: return identity | {"path": ".github/workflows/" + workflow}
                return {"total_count": len(rows) if count is None else count,
                        "workflow_runs": [run | {"path": ".github/workflows/" + workflow} for run in rows]}
            return planner.moderation_build_candidate_backend_gate(self.head, self.repo, api, self.now)
        check([]); check([candidate])
        for field, value in (("status", "in_progress"), ("conclusion", "failure"), ("head_sha", self.source),
                             ("head_branch", "codex/other"), ("run_attempt", 2), ("workflow_id", 9)):
            with self.subTest(field=field), self.assertRaises(ValueError): check([candidate | {field: value}])
        with self.assertRaises(ValueError): check([], 1)
        with self.assertRaises(ValueError): check([candidate, candidate])

    def test_corrected_graph_requires_complete_new_build_and_revalidates_source(self):
        proof = self.verify()
        candidate = self.run | {"id": 123, "head_sha": self.head, "conclusion": "success"}
        jobs = [copy.deepcopy(job) for job in self.jobs if job["name"] in {planner.PLAN_JOB, planner.BUILD}]
        for job in jobs:
            job.update(id=job["id"] + 1000, head_sha=self.head, run_id=123, conclusion="success")
            for step in job["steps"]: step["conclusion"] = "success"
        record = self.record | {"head_sha": self.head, "test_correction_evidence": proof}
        def check(values=jobs, verified=proof):
            with patch.object(planner, "moderation_build_correction_inputs", return_value=True), \
                    patch.object(planner, "moderation_build_steps", return_value=self.build_steps), \
                    patch.object(planner, "moderation_build_correction_source", return_value=verified):
                return planner.covers_moderation_build_correction(candidate, self.head, self.required,
                    lambda path: "IOS_CI_PLAN_JSON=" + json.dumps(record) if path.endswith("/logs") else self.run, self.now, values)
        self.assertTrue(check())
        self.assertFalse(check(verified=None))
        for index, job in enumerate(jobs):
            for field, value in (("conclusion", "skipped"), ("steps", []), ("run_attempt", 2), ("head_sha", self.source)):
                invalid = copy.deepcopy(jobs); invalid[index][field] = value
                self.assertFalse(check(invalid))
            for n in range(len(job["steps"])):
                invalid = copy.deepcopy(jobs); invalid[index]["steps"][n]["conclusion"] = "skipped"
                self.assertFalse(check(invalid))
        self.assertFalse(check(jobs + [copy.deepcopy(jobs[0])]))
        skipped = jobs[0] | {"id": 1, "name": planner.UNEXPANDED_SHARING_JOB, "conclusion": "skipped", "steps": []}
        self.assertTrue(check(jobs + [skipped, skipped | {"id": 2}]))
        self.assertFalse(check(jobs + [skipped | {"conclusion": "failure"}]))

    def test_planner_runs_full_build_only_and_declares_original_backend_sha(self):
        proof = self.verify()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "event").write_text("{}")
            env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/" + self.run["head_branch"],
                "GITHUB_SHA": self.head, "GITHUB_REPOSITORY": self.repo, "GITHUB_RUN_ID": "123",
                "GITHUB_WORKFLOW": "iOS build check", "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_EVENT_PATH": str(root / "event"), "GITHUB_OUTPUT": str(root / "output"), "GITHUB_STEP_SUMMARY": str(root / "summary")}
            output = io.StringIO()
            with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                    patch.object(planner, "changed_paths", return_value=list(scope.MODERATION_RESOLUTION_PATHS | {scope.MODERATION_RESOLUTION_BUILD_TEST})), \
                    patch.object(planner, "runtime_scope", return_value=scope.MODERATION_RESOLUTION_SCOPE), \
                    patch.object(planner, "find_evidence", return_value=None), \
                    patch.object(planner, "find_test_correction_evidence", return_value=proof), \
                    patch.object(planner, "moderation_build_correction_inputs", return_value=True):
                planner.main()
            flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            self.assertEqual([flags[key] for key in ("build", "smoke", "sharing", "app_ui")], ["true", "false", "false", "false"])
            self.assertEqual(planner.moderation_build_plan(output.getvalue(), self.head, self.required)["test_correction_evidence"], proof)


class ModerationProductionUIRecoveryTests(unittest.TestCase):
    # Bounded lines from run37944559850, job113867584091: the earlier nine-test
    # success is real. Omit unrelated successful output and the huge Swift dump
    # after the exact AssertionError prefix; preserve the owning group/command.
    build_failure_slice = """2026-10-09T14:30:40.4139140Z Ran 9 tests in 0.037s
2026-10-09T14:30:40.4140680Z OK
2026-10-09T14:30:57.7451720Z ##[group]Run set -euo pipefail
2026-10-09T14:30:57.7452090Z \x1b[36;1mset -euo pipefail\x1b[0m
2026-10-09T14:30:57.7453130Z \x1b[36;1mcommand -v swift > /dev/null\x1b[0m
2026-10-09T14:30:57.7453580Z \x1b[36;1mpython3 ci/test-window-entry-and-cover-presentation.py\x1b[0m
2026-10-09T14:30:57.7567620Z shell: /bin/bash --noprofile --norc -e -o pipefail {0}
2026-10-09T14:30:57.7568270Z env:
2026-10-09T14:30:57.7568980Z   DEVELOPER_DIR: /Applications/Xcode_26.3.app/Contents/Developer
2026-10-09T14:30:57.7569480Z ##[endgroup]
2026-10-09T14:31:02.0904120Z FAIL: test_source_does_not_advance_expiry_boundary (__main__.WindowPresentation.test_source_does_not_advance_expiry_boundary)
2026-10-09T14:31:02.0960050Z AssertionError: 'func isVisible(at now: Date) -> Bool { now < displayUntil }' not found
2026-10-09T14:31:02.1001590Z Ran 9 tests in 4.217s
2026-10-09T14:31:02.1002360Z FAILED (failures=1)
2026-10-09T14:31:02.1102050Z ##[error]Process completed with exit code 1.
2026-10-09T14:31:02.1526510Z ##[group]Run actions/upload-artifact@b7c566a772e6b6bfb58ed0dc250532a479d7789f
"""

    def setUp(self):
        ModerationBuildCorrectionTests.setUp(self)
        self.failure = self.build_failure_slice
        self.head = planner.MODERATION_UI_RECOVERY_PRODUCT
        self.ui_name = planner.lane_job(planner.MODERATION_RESOLUTION_SCOPE, "app-ui")
        for job in self.jobs:
            if job["name"] == self.ui_name:
                job["conclusion"] = "failure"; job["steps"][0]["conclusion"] = "failure"
        self.jobs += [self.jobs[0] | {"id": job_id, "name": planner.UNEXPANDED_SHARING_JOB,
            "conclusion": "skipped", "steps": []} for job_id in planner.MODERATION_UI_SOURCE_SKIPS]
        self.ui_log = self.transcript({planner.MODERATION_UI_RECOVERY_CASE}) + '\n"header.closeButton" Button\nXCTAssertTrue failed'
        self.candidate_index = {"total_count": 0, "workflow_runs": []}

    def transcript(self, failures=frozenset()):
        lines = []
        for case in planner.MODERATION_RESOLUTION_TESTS:
            name = case.removeprefix("NekoWidgetUITests/"); label = "NekoWidgetUITests." + name.replace("/", " ")
            lines += [f"Test Case '-[{label}]' started.", f"Test Case '-[{label}]' {'failed' if name in failures else 'passed'} (1 seconds)."]
        return "\n".join(lines)

    def api(self, path):
        if path.endswith("/workflows/ios-build.yml"):
            return {"id": 335014238, "path": ".github/workflows/ios-build.yml", "state": "active"}
        if "/runs?head_sha=" + self.head in path: return self.candidate_index
        if path.endswith(f"/{planner.MODERATION_BUILD_SOURCE_JOBS[self.ui_name]}/logs"): return self.ui_log
        return ModerationBuildCorrectionTests.api(self, path)

    def prove(self):
        with patch.object(planner, "moderation_ui_recovery_inputs", return_value=True), \
                patch.object(planner, "moderation_build_steps", return_value=self.build_steps), \
                patch.object(planner, "moderation_resolution_backend_evidence", return_value=self.backends):
            return planner.moderation_ui_recovery_evidence(self.head, self.repo, self.api, self.now)

    def test_shipping_recovery_never_reuses_native_and_requires_both_specific_failures(self):
        proof = self.prove()
        self.assertFalse(proof["native_success_reused"])
        self.assertEqual(proof["required_native_jobs"], list(self.required))
        self.assertEqual(len(proof["historical_native_success_job_ids"]), 2)
        self.assertEqual(json.loads(json.dumps(proof)), proof)
        original = copy.deepcopy(self.jobs)
        for n, job in enumerate(original):
            for field, value in (("conclusion", "cancelled"), ("status", "in_progress"), ("head_sha", "f" * 40),
                    ("run_attempt", 2), ("id", 1), ("steps", [])):
                if field == "steps" and job["id"] in planner.MODERATION_UI_SOURCE_SKIPS: continue
                self.jobs = copy.deepcopy(original); self.jobs[n][field] = value
                with self.subTest(job=job["name"], field=field), self.assertRaises(ValueError): self.prove()
        self.jobs = original
        self.ui_log = self.transcript()
        with self.assertRaises(ValueError): self.prove()
        self.ui_log = self.transcript({planner.MODERATION_UI_RECOVERY_CASE, "OfficialWindowUITests/testWidgetURLsColdOpenPhotoBeforeSourceResolvesAndCloseOnce"})
        with self.assertRaises(ValueError): self.prove()

    def test_no_candidate_backend_push_may_be_hidden_even_success_or_incomplete_index(self):
        self.prove()
        for index in ({"total_count": 1, "workflow_runs": []}, {"total_count": 0, "workflow_runs": [{}]},
                {"total_count": 1, "workflow_runs": [{"conclusion": "success"}]},
                {"total_count": 1, "workflow_runs": [{"status": "in_progress"}]},
                {"total_count": 1, "workflow_runs": [{"conclusion": "failure"}]}):
            self.candidate_index = index
            with self.assertRaises(ValueError): self.prove()

    def test_build_failure_is_bounded_to_owning_command_and_rejects_unknown_or_ambiguous_output(self):
        log = self.build_failure_slice
        self.assertTrue(planner.moderation_ui_build_failure(log))
        self.assertEqual(len(re.findall(r"Ran 9 tests in", log)), 2)
        mutants = [log + "FAIL: another_failure\n", log + "ERROR: another_error\n",
            log + "FAILED (failures=2)\n", log + "##[error]Another error\n",
            log.replace("Ran 9 tests in 4.217s", "Ran 8 tests in 4.217s"),
            log.replace("Ran 9 tests in 4.217s", "Ran 9 tests in 4.217s\nRan 9 tests in 0.1s"),
            log.replace("##[group]Run set -euo pipefail", "Run set -euo pipefail"),
            log.replace("##[endgroup]", ""),
            log.replace("python3 ci/test-window-entry-and-cover-presentation.py", "python3 ci/another.py"),
            log.replace("python3 ci/test-window-entry-and-cover-presentation.py", "python3 ci/test-window-entry-and-cover-presentation.py\npython3 ci/another.py"),
            log.replace("##[group]Run actions/upload-artifact", "Run actions/upload-artifact"),
            log.replace("FAIL: test_source", "FAIL: unknown_source"),
            log.replace("FAILED (failures=1)", "OK"),
            log.replace("Ran 9 tests in 4.217s", "##[group]other\nRan 9 tests in 4.217s"),
            log + log]
        for invalid in mutants:
            with self.subTest(log=invalid[-150:]): self.assertFalse(planner.moderation_ui_build_failure(invalid))
        self.failure = mutants[4]
        with self.assertRaises(ValueError): self.prove()

    def test_exact_two_product_pairs_controls_modes_handoffs_and_registration(self):
        rows = {path: [":100644", "100644", *pair, "M"] for path, pair in planner.MODERATION_UI_RECOVERY_BLOBS.items()}
        def check(values=rows, *, unapproved=False, registered=True, ancestor=True):
            def git(*args):
                if args[0] == "diff": return "".join(" ".join(value) + "\0" + path + "\0" for path, value in values.items())
                if args[:2] == ("merge-base", "--is-ancestor") and not ancestor: raise subprocess.CalledProcessError(1, "git")
                if args[0] == "merge-base": return "a" * 40
                if args[0] == "show": return f'MODERATION_UI_RECOVERY_PRODUCT = "{self.head}"' if registered else "old"
                if args[0] == "ls-tree": return f"100644 blob {'c' * 40 if unapproved and args[1] == self.head else 'b' * 40}\t{args[3]}"
                raise AssertionError(args)
            with patch.object(planner, "git", side_effect=git): return planner.moderation_ui_recovery_inputs(self.head)
        self.assertTrue(check()); self.assertFalse(check(unapproved=True)); self.assertFalse(check(registered=False)); self.assertFalse(check(ancestor=False))
        for path in rows:
            self.assertFalse(check({k: v for k, v in rows.items() if k != path}))
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D")):
                invalid = copy.deepcopy(rows); invalid[path][index] = value; self.assertFalse(check(invalid))
        self.assertTrue(check(rows | {"handoffs/review.md": [":000000", "100644", "0" * 40, "b" * 40, "A"]}))
        self.assertFalse(check(rows | {"NekoWidget/Shared/Sharing/MomentSharingCore.swift": [":100644", "100644", "a" * 40, "b" * 40, "M"]}))

    def test_all_new_native_jobs_steps_and_all_eleven_ui_must_execute(self):
        proof = self.prove()
        run = self.run | {"id": 700, "head_sha": self.head, "conclusion": "success"}
        jobs = copy.deepcopy(self.jobs)
        for job in jobs:
            job.update(id=job["id"] + 1000, head_sha=self.head, run_id=700)
            if job["name"] != planner.UNEXPANDED_SHARING_JOB:
                job["conclusion"] = "success"
                for step in job["steps"]: step["conclusion"] = "success"
        record = self.record | {"head_sha": self.head, "production_ui_recovery": proof}
        def check(values=jobs, ui_log=None):
            def api(path):
                if path.endswith(f"/{planner.MODERATION_BUILD_SOURCE_JOBS[planner.PLAN_JOB] + 1000}/logs"):
                    return "IOS_CI_PLAN_JSON=" + json.dumps(record)
                return self.transcript() if ui_log is None else ui_log
            with patch.object(planner, "moderation_ui_recovery_inputs", return_value=True), \
                    patch.object(planner, "moderation_build_steps", return_value=self.build_steps), \
                    patch.object(planner, "moderation_ui_recovery_evidence", return_value=proof):
                return planner.covers_moderation_ui_recovery(run, self.head, self.required, api, self.now, values)
        self.assertTrue(check())
        for n, job in enumerate(jobs):
            if job["name"] == planner.UNEXPANDED_SHARING_JOB: continue
            for field, value in (("conclusion", "skipped"), ("steps", []), ("run_attempt", 2)):
                invalid = copy.deepcopy(jobs); invalid[n][field] = value; self.assertFalse(check(invalid))
            for step in range(len(job["steps"])):
                invalid = copy.deepcopy(jobs); invalid[n]["steps"][step]["conclusion"] = "skipped"; self.assertFalse(check(invalid))
        self.assertFalse(check(jobs + [jobs[0]])); self.assertFalse(check(ui_log=self.transcript({planner.MODERATION_UI_RECOVERY_CASE})))
        self.assertFalse(check(ui_log=self.transcript().replace(" passed ", " skipped ", 1)))

    def test_main_planner_runs_four_native_and_is_not_test_only_correction(self):
        proof = self.prove()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "event").write_text("{}")
            env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/" + self.run["head_branch"],
                "GITHUB_SHA": self.head, "GITHUB_REPOSITORY": self.repo, "GITHUB_RUN_ID": "123",
                "GITHUB_WORKFLOW": "iOS build check", "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_EVENT_PATH": str(root / "event"), "GITHUB_OUTPUT": str(root / "output"), "GITHUB_STEP_SUMMARY": str(root / "summary")}
            output = io.StringIO()
            with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                    patch.object(planner, "changed_paths", return_value=list(scope.MODERATION_RESOLUTION_PATHS | set(planner.MODERATION_UI_RECOVERY_BLOBS))), \
                    patch.object(planner, "runtime_scope", return_value=scope.MODERATION_RESOLUTION_SCOPE), \
                    patch.object(planner, "find_evidence", return_value=None), \
                    patch.object(planner, "find_test_correction_evidence", side_effect=AssertionError("shipping change cannot use test-only route")), \
                    patch.object(planner, "moderation_ui_recovery_inputs", return_value=True), \
                    patch.object(planner, "moderation_ui_recovery_evidence", return_value=proof): planner.main()
            flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            self.assertEqual([flags[key] for key in ("build", "smoke", "sharing", "app_ui")], ["true"] * 4)
            record = planner.moderation_build_plan(output.getvalue(), self.head, self.required)
            self.assertIsNone(record["test_correction_evidence"]); self.assertEqual(record["production_ui_recovery"], proof)


class ModerationChainedBuildRecoveryTests(unittest.TestCase):
    # Actual owning step from 37954929706/113903266969, including its prior
    # successful suites. No external artifact or network is needed for tests.
    failure_slice = '2026-10-09T15:55:12.0350720Z ##[group]Run set -euo pipefail\n2026-10-09T15:55:12.0351150Z \x1b[36;1mset -euo pipefail\x1b[0m\n2026-10-09T15:55:12.0351420Z \x1b[36;1mxcrun --sdk macosx swiftc \\\x1b[0m\n2026-10-09T15:55:12.0351780Z \x1b[36;1m  -parse-as-library \\\x1b[0m\n2026-10-09T15:55:12.0352120Z \x1b[36;1m  Shared/Routing/DeepLink.swift \\\x1b[0m\n2026-10-09T15:55:12.0352470Z \x1b[36;1m  NekoWidget/Views/MomentSharingPresentation.swift \\\x1b[0m\n2026-10-09T15:55:12.0352930Z \x1b[36;1m  ci/verify-moment-sharing-presentation.swift \\\x1b[0m\n2026-10-09T15:55:12.0353510Z \x1b[36;1m  -o "$RUNNER_TEMP/verify-moment-sharing-presentation"\x1b[0m\n2026-10-09T15:55:12.0354030Z \x1b[36;1m"$RUNNER_TEMP/verify-moment-sharing-presentation"\x1b[0m\n2026-10-09T15:55:12.0354630Z \x1b[36;1mxcrun --sdk macosx swiftc \\\x1b[0m\n2026-10-09T15:55:12.0355020Z \x1b[36;1m  -parse-as-library \\\x1b[0m\n2026-10-09T15:55:12.0355350Z \x1b[36;1m  Shared/Sharing/PairingCore.swift \\\x1b[0m\n2026-10-09T15:55:12.0355690Z \x1b[36;1m  NekoWidget/Views/PairingPresentation.swift \\\x1b[0m\n2026-10-09T15:55:12.0356240Z \x1b[36;1m  ci/verify-pairing-presentation.swift \\\x1b[0m\n2026-10-09T15:55:12.0356700Z \x1b[36;1m  -o "$RUNNER_TEMP/verify-pairing-presentation"\x1b[0m\n2026-10-09T15:55:12.0357140Z \x1b[36;1m"$RUNNER_TEMP/verify-pairing-presentation"\x1b[0m\n2026-10-09T15:55:12.0357470Z \x1b[36;1mxcrun --sdk macosx swiftc \\\x1b[0m\n2026-10-09T15:55:12.0357810Z \x1b[36;1m  -parse-as-library \\\x1b[0m\n2026-10-09T15:55:12.0358090Z \x1b[36;1m  Shared/Models/WidgetManifest.swift \\\x1b[0m\n2026-10-09T15:55:12.0358470Z \x1b[36;1m  Shared/Models/WidgetRenderPlan.swift \\\x1b[0m\n2026-10-09T15:55:12.0358910Z \x1b[36;1m  ci/verify-private-window-display-name.swift \\\x1b[0m\n2026-10-09T15:55:12.0359300Z \x1b[36;1m  -o "$RUNNER_TEMP/verify-private-window-display-name"\x1b[0m\n2026-10-09T15:55:12.0359800Z \x1b[36;1m"$RUNNER_TEMP/verify-private-window-display-name"\x1b[0m\n2026-10-09T15:55:12.0360220Z \x1b[36;1mpython3 ci/test-inactive-window-name-sync.py\x1b[0m\n2026-10-09T15:55:12.0360680Z \x1b[36;1mpython3 ci/test-family-window-widget-boundaries.py\x1b[0m\n2026-10-09T15:55:12.0361040Z \x1b[36;1mpython3 ci/test-private-window-cover.py\x1b[0m\n2026-10-09T15:55:12.0361490Z \x1b[36;1mgrep -Fq \'MomentSharingPresentation.swift in Sources\' \\\x1b[0m\n2026-10-09T15:55:12.0361860Z \x1b[36;1m  NekoWidget.xcodeproj/project.pbxproj\x1b[0m\n2026-10-09T15:55:12.0410260Z shell: /bin/bash --noprofile --norc -e -o pipefail {0}\n2026-10-09T15:55:12.0410660Z env:\n2026-10-09T15:55:12.0411220Z   DEVELOPER_DIR: /Applications/Xcode_26.3.app/Contents/Developer\n2026-10-09T15:55:12.0411680Z ##[endgroup]\n2026-10-09T15:55:14.9341660Z Moment sharing presentation verifier passed\n2026-10-09T15:55:19.7006860Z Private window display name verifier passed\n2026-10-09T15:55:19.7628310Z .......\n2026-10-09T15:55:19.7628920Z ----------------------------------------------------------------------\n2026-10-09T15:55:19.7629340Z Ran 7 tests in 0.004s\n2026-10-09T15:55:19.7629540Z \n2026-10-09T15:55:19.7630220Z OK\n2026-10-09T15:55:20.4475140Z ...............................................................\n2026-10-09T15:55:20.4479100Z ----------------------------------------------------------------------\n2026-10-09T15:55:20.4481110Z Ran 63 tests in 0.606s\n2026-10-09T15:55:20.4481430Z \n2026-10-09T15:55:20.4481560Z OK\n2026-10-09T15:55:20.4489770Z sent-thumbnail-private-alias: legacy-comparisons-reproduced, creation-readable, symlinks-rejected\n2026-10-09T15:57:20.6471780Z ..E\n2026-10-09T15:57:20.6480670Z ======================================================================\n2026-10-09T15:57:20.6482910Z ERROR: test_shipping_reader_with_two_window_histories (__main__.PrivateWindowCoverTests.test_shipping_reader_with_two_window_histories)\n2026-10-09T15:57:20.6500840Z ----------------------------------------------------------------------\n2026-10-09T15:57:20.6502040Z Traceback (most recent call last):\n2026-10-09T15:57:20.6503770Z   File "/Users/runner/work/neko-widget/neko-widget/NekoWidget/ci/test-private-window-cover.py", line 274, in test_shipping_reader_with_two_window_histories\n2026-10-09T15:57:20.6505700Z     subprocess.run(["swiftc", str(script), "-o", str(executable)], check=True, timeout=120)\n2026-10-09T15:57:20.6512330Z     ~~~~~~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^\n2026-10-09T15:57:20.6514240Z   File "/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/lib/python3.14/subprocess.py", line 557, in run\n2026-10-09T15:57:20.6515840Z     stdout, stderr = process.communicate(input, timeout=timeout)\n2026-10-09T15:57:20.6516930Z                      ~~~~~~~~~~~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^\n2026-10-09T15:57:20.6518450Z   File "/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/lib/python3.14/subprocess.py", line 1221, in communicate\n2026-10-09T15:57:20.6520370Z     stdout, stderr = self._communicate(input, endtime, timeout)\n2026-10-09T15:57:20.6521320Z                      ~~~~~~~~~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^\n2026-10-09T15:57:20.6522760Z   File "/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/lib/python3.14/subprocess.py", line 2179, in _communicate\n2026-10-09T15:57:20.6524340Z     self.wait(timeout=self._remaining_time(endtime))\n2026-10-09T15:57:20.6525120Z     ~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^\n2026-10-09T15:57:20.6526600Z   File "/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/lib/python3.14/subprocess.py", line 1279, in wait\n2026-10-09T15:57:20.6527970Z     return self._wait(timeout=timeout)\n2026-10-09T15:57:20.6528710Z            ~~~~~~~~~~^^^^^^^^^^^^^^^^^\n2026-10-09T15:57:20.6530150Z   File "/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/lib/python3.14/subprocess.py", line 2076, in _wait\n2026-10-09T15:57:20.6531580Z     raise TimeoutExpired(self.args, timeout)\n2026-10-09T15:57:20.6534200Z subprocess.TimeoutExpired: Command \'[\'swiftc\', \'/var/folders/nj/vtw8zd2j31d1gdrtntc5y4600000gn/T/private-window-cover-_9h6_49m/main.swift\', \'-o\', \'/var/folders/nj/vtw8zd2j31d1gdrtntc5y4600000gn/T/private-window-cover-_9h6_49m/verify-cover\']\' timed out after 120 seconds\n2026-10-09T15:57:20.6541550Z \n2026-10-09T15:57:20.6541720Z ----------------------------------------------------------------------\n2026-10-09T15:57:20.6542150Z Ran 3 tests in 120.125s\n2026-10-09T15:57:20.6542340Z \n2026-10-09T15:57:20.6542400Z FAILED (errors=1)\n2026-10-09T15:57:20.6742840Z ##[error]Process completed with exit code 1.\n2026-10-09T15:57:20.7234630Z ##[group]Run actions/upload-artifact@b7c566a772e6b6bfb58ed0dc250532a479d7789f\n'

    def setUp(self):
        old = ModerationProductionUIRecoveryTests(); old.setUp()
        self.previous = old.prove() | {"candidate_sha": planner.MODERATION_CHAIN_SOURCE}
        self.source, self.head = planner.MODERATION_CHAIN_SOURCE, planner.MODERATION_CHAIN_PRODUCT
        self.repo, self.now, self.required = old.repo, old.now, old.required
        self.run = old.run | {"id": planner.MODERATION_CHAIN_RUN, "head_sha": self.source}
        self.build_steps = planner.moderation_build_steps()
        self.workflow = planner.git("show", f"{self.source}:.github/workflows/ios-build.yml")
        self.jobs = []
        for name, job_id in planner.MODERATION_CHAIN_JOBS.items():
            names = self.build_steps if name == planner.BUILD else ("Check out repository", "Test CI selection and evidence boundaries", "Select checks") if name == planner.PLAN_JOB else ("Check out repository", "Run Simulator smoke test", "Upload Simulator smoke-test artifacts") if name == planner.BOOTSTRAP_SMOKE else ("Check out repository", "Run sharing runtime matrix", "Upload sharing runtime matrix artifacts")
            steps = [{"name": step, "number": i+2, "status": "completed", "conclusion": "success"} for i, step in enumerate(names)]
            if name == planner.BUILD:
                failure = names.index(planner.MODERATION_CHAIN_FAILED_STEP)
                for i in range(failure, len(steps)): steps[i]["conclusion"] = "failure" if i == failure else "skipped"
                steps[failure]["number"] = 13
            self.jobs.append({"id": job_id, "name": name, "head_sha": self.source, "run_id": self.run["id"],
                "run_attempt": 1, "status": "completed", "conclusion": "failure" if name == planner.BUILD else "success",
                "completed_at": self.now.isoformat(), "steps": steps})
        self.record = old.record | {"head_sha": self.source, "production_ui_recovery": self.previous}
        self.failure = self.failure_slice; self.ui_log = old.transcript()
        self.photos_failure = "fixed synthetic Photos snapshot failure\n"
        self.photos_digest = planner.hashlib.sha256(self.photos_failure.strip("\n").encode()).hexdigest()
        self.photos_success = ("Test Case '-[NekoWidgetUITests.PhotoPermissionUITests testGrantFullPhotoLibraryAccess]' started.\n"
            "Test Case '-[NekoWidgetUITests.PhotoPermissionUITests testGrantFullPhotoLibraryAccess]' passed (22.857 seconds).\n"
            "Test Case '-[NekoWidgetUITests.PhotoPermissionUITests testMainlineAcceptanceScreensWithAuthorizedLibrary]' started.\n"
            "Test Case '-[NekoWidgetUITests.PhotoPermissionUITests testMainlineAcceptanceScreensWithAuthorizedLibrary]' passed (109.435 seconds).\n"
            "Simulator smoke test passed at 2026-10-09T16:00:00Z")
        photo = next(job for job in self.jobs if job["name"] == planner.BOOTSTRAP_SMOKE)
        photo["conclusion"] = "failure"; photo["steps"][1].update(conclusion="failure", number=3)
        self.jobs += [self.jobs[0] | {"id": identifier, "name": planner.UNEXPANDED_SHARING_JOB,
            "conclusion": "skipped", "steps": []} for identifier in planner.MODERATION_CHAIN_SKIPS]
        self.index = {"total_count": 0, "workflow_runs": []}

    def api(self, path):
        if path.endswith(f"/runs/{self.run['id']}"): return self.run
        if "/jobs?" in path: return {"total_count": len(self.jobs), "jobs": self.jobs}
        if path.endswith(f"/{planner.MODERATION_CHAIN_JOBS[planner.PLAN_JOB]}/logs"): return "IOS_CI_PLAN_JSON=" + json.dumps(self.record)
        if path.endswith(f"/{planner.MODERATION_CHAIN_JOBS[planner.BUILD]}/logs"): return self.failure
        if path.endswith(f"/{planner.MODERATION_CHAIN_JOBS[planner.BOOTSTRAP_SMOKE]}/logs"): return self.photos_failure
        if path.endswith(f"/{planner.MODERATION_CHAIN_JOBS[planner.lane_job(planner.MODERATION_RESOLUTION_SCOPE, 'app-ui')]}/logs"): return self.ui_log
        if "/runs?head_sha=" + self.head in path: return self.index
        raise AssertionError(path)

    def prove(self):
        with patch.object(planner, "moderation_chained_inputs", return_value=True), \
                patch.object(planner, "moderation_ui_recovery_evidence", return_value=self.previous) as old, \
                patch.object(planner, "moderation_build_steps", return_value=self.build_steps), \
                patch.object(planner, "git", return_value=self.workflow), \
                patch.object(planner, "MODERATION_CHAIN_PHOTOS_LOG_SHA256", self.photos_digest):
            result = planner.moderation_chained_evidence(self.head, self.repo, self.api, self.now)
            old.assert_called_once_with(self.source, self.repo, self.api, self.now)
            return result

    def test_source_identity_pending_failure_skip_step_and_all_eleven_cases_are_strict(self):
        proof = self.prove()
        self.assertEqual(len(proof["native_jobs_reused"]), 2)
        self.assertEqual(proof["owning_jobs_to_execute"], list(planner.MODERATION_CHAIN_OWNING))
        self.assertEqual(proof["backend_evidence"], self.previous["backend_evidence"])
        run = self.run.copy()
        for field, value in (("status", "in_progress"), ("conclusion", "success"), ("head_sha", "a"*40),
                ("event", "workflow_dispatch"), ("head_branch", "main"), ("run_attempt", 2), ("workflow_id", 7),
                ("repository", {"full_name": "other/repo"}), ("head_repository", {"full_name": "other/repo"}),
                ("updated_at", "2026-10-08T15:00:00Z")):
            self.run = run | {field: value}
            with self.subTest(field=field), self.assertRaises(ValueError): self.prove()
        self.run = run; original = copy.deepcopy(self.jobs)
        for n, job in enumerate(original):
            for field, value in (("conclusion", "skipped"), ("status", "in_progress"), ("head_sha", "a"*40),
                    ("run_attempt", 2), ("id", 1), ("steps", []), ("run_id", 2)):
                if job["id"] in planner.MODERATION_CHAIN_SKIPS and (field, value) in (("conclusion", "skipped"), ("steps", [])): continue
                self.jobs = copy.deepcopy(original); self.jobs[n][field] = value
                with self.subTest(job=job["name"], field=field), self.assertRaises(ValueError): self.prove()
            if job["name"] not in {planner.BUILD, planner.UNEXPANDED_SHARING_JOB}:
                for step in range(len(job["steps"])):
                    self.jobs = copy.deepcopy(original); self.jobs[n]["steps"][step]["conclusion"] = "skipped"
                    with self.assertRaises(ValueError): self.prove()
        self.jobs = original
        for bad in (self.ui_log.replace("passed", "failed", 1), self.ui_log.replace("passed", "skipped", 1), self.ui_log.splitlines()[0], self.ui_log+self.ui_log):
            saved = self.ui_log; self.ui_log = bad
            with self.assertRaises(ValueError): self.prove()
            self.ui_log = saved
        self.jobs += [copy.deepcopy(original[0])]
        with self.assertRaises(ValueError): self.prove()

    def test_timeout_parser_requires_owning_command_and_only_actual_failure(self):
        with patch.object(planner, "git", return_value=self.workflow):
            self.assertTrue(planner.moderation_chained_build_failure(self.failure))
            mutants = [self.failure.replace("120 seconds", "121 seconds"), self.failure.replace("Ran 3 tests", "Ran 4 tests"),
                self.failure.replace("errors=1", "errors=2"), self.failure.replace("'swiftc'", "'swift'"),
                self.failure.replace("python3 ci/test-private-window-cover.py", "python3 ci/other.py"),
                self.failure.replace("##[group]Run set -euo pipefail", "Run set -euo pipefail"),
                self.failure+self.failure, self.failure+"\nFAIL: extra", self.failure+"\nERROR: extra",
                self.failure+"\nFAILED (failures=1)", self.failure+"\n##[error]another failure",
                self.failure.replace("Process completed with exit code 1.", "Process completed with exit code 2."),
                self.failure.replace("main.swift", "unrelated.swift")]
            for bad in mutants:
                self.assertFalse(planner.moderation_chained_build_failure(bad))

    def test_photos_failure_is_an_exact_transcript_and_new_success_includes_permission_and_scan(self):
        with patch.object(planner, "MODERATION_CHAIN_PHOTOS_LOG_SHA256", self.photos_digest):
            self.assertTrue(planner.moderation_chained_photos_failure(self.photos_failure))
            self.assertTrue(planner.moderation_chained_photos_failure(self.photos_failure.replace("\n", "\r\n")))
            for changed in (self.photos_failure+"extra", "", self.photos_failure.replace("failure", "pass")):
                self.assertFalse(planner.moderation_chained_photos_failure(changed))
        self.assertTrue(planner.moderation_chained_photos_success(self.photos_success))
        for changed in (self.photos_success.replace("passed (", "failed ("), self.photos_success.replace("passed at", "unfinished at"),
                        self.photos_success+self.photos_success, self.photos_success+"\n##[error]extra", self.photos_success.replace("testGrantFullPhotoLibraryAccess", "testOther")):
            self.assertFalse(planner.moderation_chained_photos_success(changed))

    def test_photos_success_requires_both_ordered_cases_and_rejects_any_extra_or_incomplete_event(self):
        lines = self.photos_success.splitlines()
        for index in range(4):
            with self.subTest(missing=index):
                self.assertFalse(planner.moderation_chained_photos_success("\n".join(lines[:index]+lines[index+1:])))
            with self.subTest(duplicate=index):
                self.assertFalse(planner.moderation_chained_photos_success("\n".join(lines[:index]+[lines[index]]+lines[index:])))
        for order in ((2,3,0,1,4),(0,2,1,3,4),(1,0,2,3,4),(0,1,3,2,4),(4,0,1,2,3)):
            self.assertFalse(planner.moderation_chained_photos_success("\n".join(lines[i] for i in order)))
        for method in ("testGrantFullPhotoLibraryAccess", "testMainlineAcceptanceScreensWithAuthorizedLibrary"):
            for status in ("failed", "skipped", "aborted"):
                text=self.photos_success.replace(f"{method}]' passed",f"{method}]' {status}")
                self.assertFalse(planner.moderation_chained_photos_success(text))
        for extra in ("Test Case '-[NekoWidgetUITests.OtherTests testUnknown]' started.",
                      "Test Case '-[NekoWidgetUITests.PhotoPermissionUITests unknownMethod]' passed.",
                      "Test Case '-[malformed", "ERROR: extra", "FAIL: extra", ": error: extra", "** TEST FAILED **"):
            self.assertFalse(planner.moderation_chained_photos_success(self.photos_success+"\n"+extra))
        self.assertFalse(planner.moderation_chained_photos_success("\n".join(lines[:2]+lines[-1:])))

    def test_candidate_backend_presence_and_old_proof_failure_cannot_be_hidden(self):
        for bad in ({"total_count": 1, "workflow_runs": []}, {"total_count": False, "workflow_runs": []},
                {"total_count": 0, "workflow_runs": [{}]}, {"total_count": 1, "workflow_runs": [{"conclusion": "success"}]},
                {"total_count": 1, "workflow_runs": [{"conclusion": "failure"}]}, {"total_count": 1, "workflow_runs": [{"status": "in_progress"}]}):
            self.index = bad
            with self.assertRaises(ValueError): self.prove()
        with patch.object(planner, "moderation_chained_inputs", return_value=True), \
                patch.object(planner, "moderation_ui_recovery_evidence", side_effect=ValueError("old source incomplete")), self.assertRaises(ValueError):
            planner.moderation_chained_evidence(self.head, self.repo, self.api, self.now)

    def test_three_fixed_pairs_all_tracked_closure_modes_approval_and_missing_are_strict(self):
        rows = [f":100644 100644 {a} {b} M\0{path}\0" for path,(a,b) in planner.MODERATION_CHAIN_BLOBS.items()]
        raw = "".join(rows)
        def check(value=raw, registered=True, mismatch=None):
            def git(*args):
                if args[0] == "diff": return value
                if args[0] == "merge-base": return "a"*40
                if args[0] == "show": return f'MODERATION_CHAIN_PRODUCT = "{self.head}"' if registered else "old"
                if args[0] == "ls-tree": return f"100644 blob {'d'*40 if args[1] == self.head and args[3] == mismatch else 'c'*40}\t{args[3]}"
                raise AssertionError(args)
            with patch.object(planner, "git", side_effect=git): return planner.moderation_chained_inputs(self.head)
        self.assertTrue(check())
        self.assertTrue(check(raw+f":000000 100644 {'0'*40} {'c'*40} A\0handoffs/fixed.md\0"))
        for path in planner.MODERATION_BUILD_CORRECTION_CONTROLS: self.assertFalse(check(mismatch=path))
        for bad in ("", raw+rows[0], raw.replace("100644", "100755"), raw.replace("100644", "120000"), raw.replace(" M\0", " D\0"),
                raw.replace(planner.MODERATION_CHAIN_BLOBS[scope.MODERATION_RESOLUTION_PRIVATE_COVER_TEST][1], "b"*40),
                *(raw.replace(row, "") for row in rows),
                *(raw+f":100644 100644 {'b'*40} {'c'*40} M\0{path}\0" for path in (".gitattributes", ".github/workflows/ios-build.yml", "NekoWidget/Shared/Sharing/MomentSharingCore.swift"))):
            self.assertFalse(check(bad))
        self.assertFalse(check(registered=False))
        self.assertTrue(scope.accepts_paths(scope.MODERATION_RESOLUTION_SCOPE, scope.MODERATION_RESOLUTION_PATHS | set(planner.MODERATION_CHAIN_BLOBS)))
        self.assertFalse(scope.accepts_paths(scope.MODERATION_RESOLUTION_SCOPE, scope.MODERATION_RESOLUTION_PATHS | {scope.MODERATION_RESOLUTION_PRIVATE_COVER_TEST}))

    def test_final_full_build_and_main_reuse_revalidate_the_same_chain(self):
        proof = self.prove(); run = self.run | {"id": 123, "head_sha": self.head, "conclusion": "success"}
        jobs = [copy.deepcopy(j) for j in self.jobs if j["name"] in {planner.BUILD, planner.BOOTSTRAP_SMOKE, planner.PLAN_JOB}]
        for job in jobs:
            job.update(id=job["id"]+100, head_sha=self.head, run_id=123, conclusion="success")
            for step in job["steps"]: step["conclusion"] = "success"
        record = self.record | {"head_sha": self.head, "production_ui_recovery": None, "chained_build_recovery": proof}
        def check(values=jobs, proof_value=proof, main=False):
            with patch.object(planner, "moderation_chained_inputs", return_value=True), \
                    patch.object(planner, "moderation_build_steps", return_value=self.build_steps), \
                    patch.object(planner, "moderation_chained_evidence", return_value=proof_value) as verify:
                fn = planner.covers_corrected_full_graph if main else planner.covers_moderation_chained_recovery
                def api(path):
                    if path.endswith(f"/{planner.MODERATION_CHAIN_JOBS[planner.BOOTSTRAP_SMOKE]+100}/logs"): return self.photos_success
                    return "IOS_CI_PLAN_JSON="+json.dumps(record)
                result = fn(run, "f"*40, self.required, api, self.now, values)
                if result: verify.assert_called_once_with(self.head, self.repo, unittest.mock.ANY, self.now)
                return result
        self.assertTrue(check()); self.assertTrue(check(main=True)); self.assertFalse(check(proof_value={}))
        for index, job in enumerate(jobs):
            for n in range(len(job["steps"])):
                bad=copy.deepcopy(jobs); bad[index]["steps"][n]["conclusion"]="skipped"; self.assertFalse(check(bad))
            for field,value in (("steps",[]),("run_attempt",2),("head_sha",self.source),("conclusion","failure")):
                bad=copy.deepcopy(jobs);bad[index][field]=value;self.assertFalse(check(bad))
        self.assertFalse(check(jobs+[jobs[0]]))
        skipped=jobs[0]|{"id":1,"name":planner.UNEXPANDED_SHARING_JOB,"conclusion":"skipped","steps":[]}
        self.assertTrue(check(jobs+[skipped]));self.assertFalse(check(jobs+[skipped|{"conclusion":"failure"}]))
        record["production_ui_recovery"]={};self.assertFalse(check())

    def test_planner_executes_build_and_photos_without_test_only_or_all_native_fallback(self):
        proof=self.prove()
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/"event").write_text("{}")
            env={"GITHUB_EVENT_NAME":"push","GITHUB_REF":"refs/heads/"+self.run["head_branch"],"GITHUB_SHA":self.head,
                "GITHUB_REPOSITORY":self.repo,"GITHUB_RUN_ID":"123","GITHUB_WORKFLOW":"iOS build check","GITHUB_SERVER_URL":"https://github.com",
                "GITHUB_EVENT_PATH":str(root/"event"),"GITHUB_OUTPUT":str(root/"output"),"GITHUB_STEP_SUMMARY":str(root/"summary")}
            output=io.StringIO()
            with patch.dict(os.environ,env),contextlib.redirect_stdout(output), \
                    patch.object(planner,"changed_paths",return_value=list(scope.MODERATION_RESOLUTION_PATHS|set(planner.MODERATION_CHAIN_BLOBS))), \
                    patch.object(planner,"runtime_scope",return_value=scope.MODERATION_RESOLUTION_SCOPE), \
                    patch.object(planner,"find_evidence",return_value=None),patch.object(planner,"moderation_chained_inputs",return_value=True), \
                    patch.object(planner,"moderation_chained_evidence",return_value=proof), \
                    patch.object(planner,"find_test_correction_evidence",side_effect=AssertionError("old route")), \
                    patch.object(planner,"moderation_ui_recovery_evidence",side_effect=AssertionError("all-native route")):
                planner.main()
            flags=dict(line.split("=",1) for line in (root/"output").read_text().splitlines())
            self.assertEqual([flags[k] for k in ("build","smoke","sharing","app_ui")],["true","true","false","false"])
            record=planner.moderation_build_plan(output.getvalue(),self.head,self.required)
            self.assertEqual(record["chained_build_recovery"],proof);self.assertIsNone(record["test_correction_evidence"])
            self.assertEqual(record["required_backend_runs"],planner.moderation_resolution_requirements(planner.MODERATION_BUILD_CORRECTION_SOURCE))


class ModerationResolutionScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644", before, after,
                       "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_RESOLUTION_BLOBS.items()}

    def test_fixed_build_test_correction_variant_requires_approved_complete_inputs(self):
        rows = self.rows()
        before, after = planner.MODERATION_BUILD_CORRECTION_BLOBS
        rows[planner.MODERATION_RESOLUTION_BUILD_TEST] = [":100644", "100644", before, after, "M"]
        with patch.object(planner, "moderation_build_correction_inputs", return_value=True):
            self.assertEqual(self.select(rows), planner.MODERATION_RESOLUTION_SCOPE)
            for n, value in ((0, ":100755"), (1, "120000"), (2, "d" * 40), (3, "e" * 40), (4, "D")):
                invalid = copy.deepcopy(rows); invalid[planner.MODERATION_RESOLUTION_BUILD_TEST][n] = value
                self.assertEqual(self.select(invalid), scope.FULL_SCOPE)
        with patch.object(planner, "moderation_build_correction_inputs", return_value=False):
            self.assertEqual(self.select(rows), scope.FULL_SCOPE)

    def test_shipping_ui_recovery_variant_keeps_complete_four_job_scope(self):
        rows = self.rows() | {path: [":100644", "100644", *pair, "M"] for path, pair in planner.MODERATION_UI_RECOVERY_BLOBS.items()}
        with patch.object(planner, "moderation_ui_recovery_inputs", return_value=True):
            self.assertEqual(self.select(rows), planner.MODERATION_RESOLUTION_SCOPE)
            invalid = copy.deepcopy(rows); invalid[planner.MODERATION_RESOLUTION_EXPORT_VIEW][3] = "f" * 40
            self.assertEqual(self.select(invalid), scope.FULL_SCOPE)
        with patch.object(planner, "moderation_ui_recovery_inputs", return_value=False):
            self.assertEqual(self.select(rows), scope.FULL_SCOPE)

    def select(self, rows=None, *, paths=None, raw=None, immutable=None, methods=True):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base": return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0" for path, fields in rows.items())
            if args[0] == "ls-tree":
                ref, path = args[1], args[3]
                return (immutable or {}).get((ref, path), f"100644 blob {planner.MODERATION_RESOLUTION_IMMUTABLE_BLOBS.get(path, 'missing')}\t{path}")
            if args[0] == "rev-parse": return self.head
            if args[0] == "show": return "synthetic owning methods"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git), patch.object(planner, "memory_tests_available", return_value=methods):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": "push",
                                                    "GITHUB_REF": "refs/heads/codex/resolution"})

    def test_complete_batch_selects_four_native_classes_and_five_backends(self):
        self.assertEqual(len(self.rows()), 42)
        self.assertEqual(sum(row[-1] == "A" for row in self.rows().values()), 4)
        selected = planner.MODERATION_RESOLUTION_SCOPE
        self.assertEqual(self.select(), selected)
        self.assertIn(selected, scope.SCOPES)
        expected = (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected)
        self.assertEqual(planner.required_jobs(list(self.rows()), selected), expected)
        self.assertEqual(len(expected), 4)
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(scope.matrix_lanes(selected), ("runtime",))
        self.assertEqual(scope.native_tests(selected), scope.native_tests(scope.FAMILY_WINDOW_UI_SCOPE) + scope.MODERATION_RESOLUTION_TESTS[-3:])
        self.assertEqual(len(scope.native_tests(selected)), 11)
        self.assertEqual(scope.smoke_tests(selected), scope.smoke_tests(scope.FAMILY_WINDOW_UI_SCOPE))
        required = planner.moderation_resolution_requirements(self.head)
        self.assertEqual(len(required), 5)
        self.assertEqual({item["workflow"] for item in required}, {planner.BILLING_WORKFLOW, planner.PRESERVATION_WORKFLOW})
        self.assertTrue(all(item["head_sha"] == self.head and item["event"] == "push" and item["success_required"] for item in required))

    def test_incomplete_unknown_duplicate_control_modes_and_changed_blobs_fail_closed(self):
        rows = self.rows()
        for path, row in rows.items():
            with self.subTest(missing=path):
                self.assertEqual(self.select({p: r for p, r in rows.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":120000"), (1, "100755"), (2, "c" * 40), (3, "d" * 40), (4, "D")):
                altered = copy.deepcopy(rows); altered[path][index] = value
                with self.subTest(path=path, field=index): self.assertEqual(self.select(altered), scope.FULL_SCOPE)
        for path in ("unknown.swift", "NekoWidget/ci/plan-ios-ci.py", "NekoWidget/SharingService/src/unreviewed.ts"):
            self.assertEqual(self.select(rows | {path: [":000000", "100644", "0" * 40, "c" * 40, "A"]}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(rows) + [next(iter(rows))]), scope.FULL_SCOPE)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in rows.items())
        self.assertEqual(self.select(raw=raw + raw.split("\0", 2)[0] + "\0" + next(iter(rows)) + "\0"), scope.FULL_SCOPE)
        self.assertEqual(self.select(methods=False), scope.FULL_SCOPE)

    def test_pending_or_malformed_registration_cannot_select_the_new_scope(self):
        rows, original = self.rows(), planner.MODERATION_RESOLUTION_BLOBS
        path = next(iter(original))
        for invalid in ({}, {key: pair for key, pair in original.items() if key != path},
                        original | {path: (original[path][0], "0" * 40)},
                        original | {path: (original[path][0], original[path][0])},
                        original | {path: ("bad", "a" * 40)}, original | {path: ("a" * 40,)}):
            with patch.object(planner, "MODERATION_RESOLUTION_BLOBS", invalid):
                self.assertEqual(self.select(rows), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_RESOLUTION_IMMUTABLE_BLOBS", {}):
            self.assertEqual(self.select(rows), scope.FULL_SCOPE)

    def test_plan_outputs_native_graph_and_backend_main_does_not_wait_for_itself(self):
        selected = planner.MODERATION_RESOLUTION_SCOPE
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "event").write_text("{}")
            env = {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/codex/resolution",
                   "GITHUB_REPOSITORY": "soso-so-27/neko-widget", "GITHUB_WORKFLOW": "iOS build check",
                   "GITHUB_EVENT_PATH": str(root / "event"), "GITHUB_OUTPUT": str(root / "output"),
                   "GITHUB_STEP_SUMMARY": str(root / "summary")}
            for backend in (False, True):
                output = io.StringIO()
                with patch.dict(os.environ, env | ({"GITHUB_REF": "refs/heads/main", "GITHUB_WORKFLOW": "Sharing service check"} if backend else {})), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=selected), \
                        patch.object(planner, "preservation_sharing_plan", return_value=backend), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("must not await self") if backend else None, return_value=None), \
                        patch.object(planner, "find_test_correction_evidence", return_value=None), contextlib.redirect_stdout(output):
                    planner.main()
                values = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual(values["runtime_scope"], selected)
                self.assertTrue(all(values[key] == str(not backend).lower() for key in ("build", "smoke", "sharing", "app_ui")))
                if not backend:
                    marker = "IOS_CI_PLAN_JSON="
                    plan = json.loads(next(line[len(marker):] for line in output.getvalue().splitlines() if line.startswith(marker)))
                    self.assertEqual(plan["required_backend_runs"], planner.moderation_resolution_requirements(self.head))
                    self.assertEqual(json.loads(values["matrix_lanes"]), ["runtime"])
                    self.assertEqual(json.loads(values["app_ui_lanes"]), ["app-ui"])

    def test_ordinary_handoffs_only_and_both_endpoint_immutable_modes(self):
        for row in ([":000000", "100644", "0" * 40, "e" * 40, "A"], [":100644", "100644", "d" * 40, "e" * 40, "M"]):
            self.assertEqual(self.select(self.rows() | {"handoffs/resolution.md": row}), planner.MODERATION_RESOLUTION_SCOPE)
        for row in ([":100644", "000000", "d" * 40, "0" * 40, "D"], [":000000", "120000", "0" * 40, "e" * 40, "A"]):
            self.assertEqual(self.select(self.rows() | {"handoffs/resolution.md": row}), scope.FULL_SCOPE)
        for path in planner.MODERATION_RESOLUTION_IMMUTABLE_BLOBS:
            for ref in (self.base, self.head):
                for value in ("", f"100755 blob {'d' * 40}\t{path}", f"100644 blob {'d' * 40}\t{path}"):
                    with self.subTest(path=path, ref=ref):
                        self.assertEqual(self.select(immutable={(ref, path): value}), scope.FULL_SCOPE)


class ModerationResolutionBackendEvidenceTests(unittest.TestCase):
    def setUp(self):
        # Reuse only the synthetic API fixture shape; no fixed durable reuse is invoked.
        self.fixture = ModerationAIDurableBackendReuseTests()
        self.fixture.setUp()
        f = self.fixture
        self.sha, self.now, self.responses = f.candidate, f.now, copy.deepcopy(f.responses)
        old = self.responses.pop(f.index("preservation-service.yml", f.source))
        self.responses[f.index("preservation-service.yml", self.sha)] = old
        for response in self.responses.values():
            if "workflow_runs" in response:
                for run in response["workflow_runs"]: run["head_sha"] = self.sha
            if "jobs" in response:
                for job in response["jobs"]: job["head_sha"] = self.sha
        self.indexes = [f.index(w, self.sha) for w in ("preservation-service.yml", "sharing-service.yml")]
        self.job_keys = [f.jobs_path(r) for r in (37911654217, 37913531637)]

    def prove(self):
        return planner.moderation_resolution_backend_evidence(self.sha, self.fixture.repo, self.responses.__getitem__, self.now,
                                                              branch="codex/moderation-ai-durable-20261009")

    def test_same_sha_push_and_all_executed_owning_steps_required(self):
        result = self.prove()
        self.assertEqual(sum(len(row["job_ids"]) for row in result.values()), 5)
        self.assertTrue(all(row["sha"] == self.sha and row["event"] == "push" for row in result.values()))
        for key in self.job_keys:
            original = copy.deepcopy(self.responses[key])
            for n, job in enumerate(original["jobs"]):
                for field, value in (("head_sha", "d" * 40), ("conclusion", "skipped"), ("status", "in_progress"), ("run_id", 4)):
                    self.responses[key] = copy.deepcopy(original); self.responses[key]["jobs"][n][field] = value
                    with self.subTest(job=job["name"], field=field), self.assertRaises(ValueError): self.prove()
                for step in range(len(job["steps"])):
                    if job["steps"][step]["name"] in ("Check out repository", "Set up Node.js", "Install locked dependencies without lifecycle scripts"): continue
                    self.responses[key] = copy.deepcopy(original); self.responses[key]["jobs"][n]["steps"][step]["conclusion"] = "skipped"
                    with self.subTest(job=job["name"], step=step), self.assertRaises(ValueError): self.prove()
            self.responses[key] = original
            self.responses[key]["jobs"].append(copy.deepcopy(original["jobs"][0])); self.responses[key]["total_count"] += 1
            with self.assertRaises(ValueError): self.prove()
            self.responses[key] = original

    def test_absent_dispatch_pr_wrong_owner_stale_newer_failure_and_incomplete_fail_closed(self):
        for key in self.indexes:
            original = copy.deepcopy(self.responses[key])
            for field, value in (("head_sha", "d" * 40), ("event", "workflow_dispatch"), ("event", "pull_request"),
                    ("head_branch", "main"), ("head_branch", "diagnostic/resolution"), ("workflow_id", 88),
                    ("path", ".github/workflows/other.yml"), ("head_repository", {"full_name": "other/repo"}),
                    ("updated_at", "2020-01-01T00:00:00Z"), ("status", "in_progress"), ("conclusion", "failure")):
                self.responses[key] = copy.deepcopy(original); self.responses[key]["workflow_runs"][0][field] = value
                with self.subTest(key=key, field=field), self.assertRaises(ValueError): self.prove()
            for invalid in ({"total_count": 0, "workflow_runs": []}, {"total_count": 2, "workflow_runs": original["workflow_runs"]}):
                self.responses[key] = invalid
                with self.assertRaises(ValueError): self.prove()
            newer = copy.deepcopy(original["workflow_runs"][0]); newer.update(id=123456, run_number=2, conclusion="failure")
            self.responses[key] = {"total_count": 2, "workflow_runs": original["workflow_runs"] + [newer]}
            with self.assertRaises(ValueError): self.prove()
            self.responses[key] = original


class ToolPreservationBackendEvidenceTests(unittest.TestCase):
    def setUp(self):
        # Reuse only the synthetic API fixture shape; no fixed durable reuse is invoked.
        self.fixture = ModerationAIDurableBackendReuseTests()
        self.fixture.setUp()
        f = self.fixture
        self.sha, self.now, self.responses = f.candidate, f.now, copy.deepcopy(f.responses)
        old = self.responses.pop(f.index("preservation-service.yml", f.source))
        self.responses[f.index("preservation-service.yml", self.sha)] = old
        for response in self.responses.values():
            if "workflow_runs" in response:
                for run in response["workflow_runs"]: run["head_sha"] = self.sha
            if "jobs" in response:
                for job in response["jobs"]: job["head_sha"] = self.sha
        self.indexes = [f.index(w, self.sha) for w in ("preservation-service.yml",)]
        self.job_keys = [f.jobs_path(r) for r in (37911654217,)]

    def prove(self):
        return planner.tool_preservation_backend_evidence(self.sha, self.fixture.repo, self.responses.__getitem__, self.now,
                                                              branch="codex/moderation-ai-durable-20261009")

    def test_same_sha_push_and_all_executed_owning_steps_required(self):
        result = self.prove()
        self.assertEqual(sum(len(row["job_ids"]) for row in result.values()), 1)
        self.assertTrue(all(row["sha"] == self.sha and row["event"] == "push" for row in result.values()))
        for key in self.job_keys:
            original = copy.deepcopy(self.responses[key])
            for n, job in enumerate(original["jobs"]):
                for field, value in (("head_sha", "d" * 40), ("conclusion", "skipped"), ("status", "in_progress"), ("run_id", 4)):
                    self.responses[key] = copy.deepcopy(original); self.responses[key]["jobs"][n][field] = value
                    with self.subTest(job=job["name"], field=field), self.assertRaises(ValueError): self.prove()
                for step in range(len(job["steps"])):
                    if job["steps"][step]["name"] in ("Check out repository", "Set up Node.js", "Install locked dependencies without lifecycle scripts"): continue
                    self.responses[key] = copy.deepcopy(original); self.responses[key]["jobs"][n]["steps"][step]["conclusion"] = "skipped"
                    with self.subTest(job=job["name"], step=step), self.assertRaises(ValueError): self.prove()
            self.responses[key] = original
            self.responses[key]["jobs"].append(copy.deepcopy(original["jobs"][0])); self.responses[key]["total_count"] += 1
            with self.assertRaises(ValueError): self.prove()
            self.responses[key] = original

    def test_absent_dispatch_pr_wrong_owner_stale_newer_failure_and_incomplete_fail_closed(self):
        for key in self.indexes:
            original = copy.deepcopy(self.responses[key])
            for field, value in (("head_sha", "d" * 40), ("event", "workflow_dispatch"), ("event", "pull_request"),
                    ("run_attempt", 2), ("head_branch", "codex/other"), ("head_branch", "main"), ("head_branch", "diagnostic/resolution"), ("workflow_id", 88),
                    ("path", ".github/workflows/other.yml"), ("head_repository", {"full_name": "other/repo"}),
                    ("updated_at", "2020-01-01T00:00:00Z"), ("status", "in_progress"), ("conclusion", "failure")):
                self.responses[key] = copy.deepcopy(original); self.responses[key]["workflow_runs"][0][field] = value
                with self.subTest(key=key, field=field), self.assertRaises(ValueError): self.prove()
            for invalid in ({"total_count": 0, "workflow_runs": []}, {"total_count": 2, "workflow_runs": original["workflow_runs"]}):
                self.responses[key] = invalid
                with self.assertRaises(ValueError): self.prove()
            newer = copy.deepcopy(original["workflow_runs"][0]); newer.update(id=123456, run_number=2, conclusion="failure")
            self.responses[key] = {"total_count": 2, "workflow_runs": original["workflow_runs"] + [newer]}
            with self.assertRaises(ValueError): self.prove()
            self.responses[key] = original


class ModerationAIDurableBackendReuseTests(unittest.TestCase):
    def setUp(self):
        self.candidate = planner.MODERATION_AI_DURABLE_REUSE_CANDIDATE
        self.source = planner.MODERATION_AI_DURABLE_REUSE_SOURCE
        self.repo = "soso-so-27/neko-widget"
        self.now = dt.datetime(2026, 10, 9, 10, tzinfo=dt.timezone.utc)
        self.prefix = f"/repos/{self.repo}/actions"
        self.responses = {}
        self.git_changes = {}
        self.steps = {
            planner.PRESERVATION_JOB: ["Check out repository", "Set up Node.js",
                "Install locked dependencies without lifecycle scripts", "Typecheck the disabled service",
                "Verify local identity, custody and storage boundaries",
                "Verify legacy notice evidence migration with synthetic owners",
                "Bundle the private authority without deployment or provisioning",
                "Bundle the private owner deletion executor without deployment"],
            planner.MODERATION_AI_DURABLE_JOBS[0]: ["Run python NekoWidget/ci/plan-ios-ci.py"],
            planner.MODERATION_AI_DURABLE_JOBS[1]: ["Verify Apple transaction service boundary",
                "Verify durable nonce and capability credential boundaries",
                "Build nonroot Node image and private Worker without publishing"],
            planner.MODERATION_AI_DURABLE_JOBS[2]: ["Parse and exercise Windows path, volume, and ACL policy"],
            planner.MODERATION_AI_DURABLE_JOBS[3]: ["Run Worker, D1, staging, moderation, and key ceremony tests",
                "Build deployment bundle without publishing"],
            "Select iOS checks and verify reusable evidence": ["Test CI selection and evidence boundaries", "Select checks"],
        }
        self.specs = (("preservation-service.yml", self.source, 37911654217, (planner.PRESERVATION_JOB,)),
                      ("sharing-service.yml", self.candidate, 37913531637, planner.MODERATION_AI_DURABLE_JOBS[:-1]),
                      ("ios-build.yml", self.candidate, 37913531658, ("Select iOS checks and verify reusable evidence",)))
        self.responses[self.index("preservation-service.yml", self.candidate)] = {"total_count": 0, "workflow_runs": []}
        for number, (workflow, sha, run_id, required) in enumerate(self.specs, 1):
            identity = {"id": number, "path": ".github/workflows/" + workflow, "state": "active"}
            run = {"id": run_id, "workflow_id": number, "path": identity["path"],
                   "repository": {"full_name": self.repo}, "head_repository": {"full_name": self.repo},
                   "head_sha": sha, "head_branch": "codex/moderation-ai-durable-20261009", "event": "push",
                   "status": "completed", "conclusion": "success", "run_attempt": 1, "run_number": 1,
                   "run_started_at": "2026-10-09T09:00:00Z", "updated_at": "2026-10-09T09:05:00Z"}
            jobs = [{"id": run_id * 10 + i, "name": name, "run_id": run_id, "run_attempt": 1,
                     "head_sha": sha, "status": "completed", "conclusion": "success",
                     "started_at": "2026-10-09T09:01:00Z", "completed_at": "2026-10-09T09:04:00Z",
                     "steps": [{"name": step, "number": j, "status": "completed", "conclusion": "success"}
                               for j, step in enumerate(self.steps[name], 1)]}
                    for i, name in enumerate(required, 1)]
            self.responses[f"{self.prefix}/workflows/{workflow}"] = identity
            self.responses[self.index(workflow, sha)] = {"total_count": 1, "workflow_runs": [copy.deepcopy(run)]}
            self.responses[f"{self.prefix}/runs/{run_id}"] = run
            self.responses[self.jobs_path(run_id)] = {"total_count": len(jobs), "jobs": jobs}

    def index(self, workflow, sha):
        return f"{self.prefix}/workflows/{workflow}/runs?head_sha={sha}&event=push&per_page=100"

    def jobs_path(self, run_id):
        return f"{self.prefix}/runs/{run_id}/jobs?filter=latest&per_page=100&page=1"

    def git(self, *args):
        if args in self.git_changes:
            return self.git_changes[args]
        if args[0] == "rev-parse":
            return args[-1].removesuffix("^{commit}")
        if args[0] == "merge-base":
            return self.source
        if args[0] == "ls-tree":
            path = args[-1]
            if path.endswith(".yml"):
                blob = planner.MODERATION_AI_DURABLE_WORKFLOW_BLOBS[path]
                return f"100644 blob {blob}\t{path}"
            if "-r" in args:
                return f"100644 blob {'a' * 40}\t{path}/file.ts\0"
            return f"040000 tree {'b' * 40}\t{path}"
        raise AssertionError(args)

    def prove(self, **kwargs):
        params = {"candidate_sha": self.candidate, "repository": self.repo, "api": self.responses.__getitem__,
                  "now": self.now, "runtime_scope": planner.MODERATION_AI_DURABLE_SCOPE} | kwargs
        with patch.object(planner, "git", side_effect=self.git):
            return planner.moderation_ai_durable_backend_evidence(**params)

    def test_fixed_proof_keeps_source_distinct_and_candidate_jobs_on_candidate(self):
        result = self.prove()
        self.assertEqual(result["source_sha"], self.source)
        self.assertEqual(result["candidate_sha"], self.candidate)
        self.assertEqual(result["candidate_preservation_push_count"], 0)
        self.assertEqual([root["path"] for root in result["verified_roots"]], list(planner.MODERATION_AI_DURABLE_REUSE_ROOTS))
        for workflow, sha, run_id, required in self.specs:
            record = result["workflows"][workflow]
            self.assertEqual((record["head_sha"], record["run_id"]), (sha, run_id))
            self.assertEqual(record["same_candidate_sha"], workflow != "preservation-service.yml")
            self.assertEqual([job["name"] for job in record["jobs"]], list(required))
        self.assertFalse(result["main_integration_verified"])
        self.assertFalse(result["native_or_release_evidence"])

    def test_any_candidate_push_or_incomplete_index_prohibits_reuse(self):
        key = self.index("preservation-service.yml", self.candidate)
        invalid = [{}, {"total_count": False, "workflow_runs": []}, {"total_count": "0", "workflow_runs": []},
                   {"total_count": 0, "workflow_runs": [], "incomplete": True}, {"total_count": 1, "workflow_runs": []}]
        invalid += [{"total_count": 1, "workflow_runs": [{"status": status, "conclusion": conclusion}]}
                    for status, conclusion in (("completed", "success"), ("completed", "failure"),
                                               ("queued", None), ("in_progress", None))]
        for response in invalid:
            with self.subTest(response=response), patch.dict(self.responses, {key: response}), self.assertRaises(ValueError):
                self.prove()

    def test_other_candidate_repository_scope_or_clock_is_rejected(self):
        for values in ({"candidate_sha": self.source}, {"candidate_sha": "a" * 40}, {"repository": "other/repo"},
                       {"runtime_scope": planner.MODERATION_AI_TRANSPORT_SCOPE}, {"now": self.now.replace(tzinfo=None)}):
            with self.subTest(values=values), self.assertRaises(ValueError):
                self.prove(**values)

    def test_ancestry_content_mode_type_missing_and_recursive_difference_are_rejected(self):
        cases = [(('merge-base', self.source, self.candidate), "c" * 40),
                 (("rev-parse", "--verify", self.source + "^{commit}"), "c" * 40)]
        for path in planner.MODERATION_AI_DURABLE_REUSE_ROOTS:
            cases += [(("ls-tree", self.candidate, "--", path), value) for value in
                      ("", f"100755 blob {'b' * 40}\t{path}", f"120000 blob {'b' * 40}\t{path}",
                       f"040000 tree {'c' * 40}\t{path}")]
            cases.append((("ls-tree", "-r", "-z", self.candidate, "--", path), "changed-child-mode-or-content"))
        for args, value in cases:
            with self.subTest(args=args, value=value), patch.dict(self.git_changes, {args: value}), self.assertRaises(ValueError):
                self.prove()

    def test_wrong_workflow_and_run_identity_event_branch_or_attempt_rejected(self):
        for workflow, sha, run_id, _ in self.specs:
            key = f"{self.prefix}/workflows/{workflow}"
            for field, value in (("id", True), ("id", 0), ("state", "disabled_manually"), ("path", ".github/workflows/other.yml")):
                with patch.dict(self.responses, {key: self.responses[key] | {field: value}}), self.assertRaises(ValueError):
                    self.prove()
            for in_index in (True, False):
                key = self.index(workflow, sha) if in_index else f"{self.prefix}/runs/{run_id}"
                original = self.responses[key]
                run = original["workflow_runs"][0] if in_index else original
                mutations = (("id", 7), ("workflow_id", True), ("path", "wrong"), ("head_sha", "a" * 40),
                             ("head_branch", "main"), ("head_branch", "codex/other"), ("event", "pull_request"),
                             ("event", "workflow_dispatch"), ("run_attempt", 2), ("run_attempt", True),
                             ("repository", {"full_name": "other/repo"}), ("head_repository", {"full_name": "other/repo"}),
                             ("status", "in_progress"), ("conclusion", "failure"))
                for field, value in mutations:
                    changed = run | {field: value}
                    response = {"total_count": 1, "workflow_runs": [changed]} if in_index else changed
                    with self.subTest(workflow=workflow, index=in_index, field=field), \
                            patch.dict(self.responses, {key: response}), self.assertRaises(ValueError):
                        self.prove()

    def test_old_future_missing_or_inconsistent_timestamps_rejected(self):
        for workflow, sha, run_id, _ in self.specs:
            key = f"{self.prefix}/runs/{run_id}"
            for value in ("2026-10-08T09:00:00Z", "2026-10-09T10:00:01Z", "2026-10-09T09:00:00", None, "bad"):
                for field in ("updated_at", "run_started_at"):
                    with patch.dict(self.responses, {key: self.responses[key] | {field: value}}), self.assertRaises(ValueError):
                        self.prove()
            key = self.jobs_path(run_id)
            for field, value in (("completed_at", "2026-10-08T09:00:00Z"), ("completed_at", "2026-10-09T10:00:01Z"),
                                 ("completed_at", None), ("started_at", "2026-10-09T09:04:30Z"),
                                 ("started_at", "2026-10-09T08:59:00Z")):
                response = copy.deepcopy(self.responses[key]); response["jobs"][0][field] = value
                with patch.dict(self.responses, {key: response}), self.assertRaises(ValueError):
                    self.prove()

    def test_ambiguous_indexes_and_missing_duplicate_failed_skipped_or_wrong_sha_jobs_rejected(self):
        for workflow, sha, run_id, _ in self.specs:
            key = self.index(workflow, sha)
            for response in ({"total_count": 0, "workflow_runs": []}, {"total_count": 2, "workflow_runs": self.responses[key]["workflow_runs"] * 2}):
                with patch.dict(self.responses, {key: response}), self.assertRaises(ValueError):
                    self.prove()
            key = self.jobs_path(run_id)
            original = self.responses[key]
            cases = [{"total_count": len(original["jobs"]) + 1, "jobs": original["jobs"]},
                     {"total_count": 0, "jobs": []},
                     {"total_count": len(original["jobs"]) + 1, "jobs": original["jobs"] + [original["jobs"][0]]}]
            for field, value in (("run_id", 7), ("run_attempt", 2), ("head_sha", "a" * 40), ("name", "unknown"),
                                 ("conclusion", "skipped"), ("conclusion", "failure"), ("status", "in_progress"),
                                 ("steps", []), ("steps", [{"name": "Set up job", "status": "completed", "conclusion": "success"}])):
                response = copy.deepcopy(original); response["jobs"][0][field] = value; cases.append(response)
            for response in cases:
                with self.subTest(workflow=workflow), patch.dict(self.responses, {key: response}), self.assertRaises(ValueError):
                    self.prove()

    def test_validation_step_missing_duplicate_or_skipped_is_not_job_success(self):
        for _, _, run_id, required in self.specs:
            key = self.jobs_path(run_id)
            for job_index in range(len(required)):
                for action in ("missing", "duplicate", "skipped", "failure"):
                    response = copy.deepcopy(self.responses[key]); steps = response["jobs"][job_index]["steps"]
                    if action == "missing":
                        steps.pop()
                    elif action == "duplicate":
                        steps.append(copy.deepcopy(steps[-1]))
                    else:
                        steps[-1]["conclusion"] = action
                    with patch.dict(self.responses, {key: response}), self.assertRaises(ValueError):
                        self.prove()

    def test_push_appearing_during_collection_is_not_hidden(self):
        key = self.index("preservation-service.yml", self.candidate)
        calls = 0

        def api(path):
            nonlocal calls
            if path == key:
                calls += 1
                if calls > 1:
                    return {"total_count": 1, "workflow_runs": [{"status": "queued"}]}
            return self.responses[path]

        with self.assertRaises(ValueError):
            self.prove(api=api)

    def test_actual_unexpanded_skipped_ios_matrix_names_are_not_executed_jobs(self):
        key = self.jobs_path(37913531658)
        job = self.responses[key]["jobs"][0]
        placeholders = [job | {"id": job["id"] + i + 10,
                        "name": "Sharing checks [${{ matrix.lane }}; scope ${{ needs.plan.outputs.runtime_scope }}]",
                        "conclusion": "skipped", "steps": []} for i in range(4)]
        response = {"total_count": 5, "jobs": [job] + placeholders}
        with patch.dict(self.responses, {key: response}):
            result = self.prove()
        self.assertEqual(len(result["workflows"]["ios-build.yml"]["jobs"]), 1)
        for field, value in (("id", job["id"]), ("conclusion", "success"), ("conclusion", "failure"),
                             ("steps", [{"name": "unexpected execution"}]), ("name", job["name"]),
                             ("name", "unknown duplicate")):
            changed = copy.deepcopy(response)
            for item in changed["jobs"][1:]:
                item[field] = value
            with self.subTest(field=field, value=value), patch.dict(self.responses, {key: changed}), self.assertRaises(ValueError):
                self.prove()

    def test_fixed_contract_is_conditional_and_ordinary_contract_unchanged(self):
        ordinary = planner.moderation_ai_durable_requirements("a" * 40)
        self.assertTrue(all(set(row) == {"workflow", "job", "head_sha", "event", "success_required"} for row in ordinary))
        fixed = planner.moderation_ai_durable_requirements(self.candidate)
        self.assertTrue(all("absent_push_reuse" not in row for row in fixed[:-1]))
        alternate = fixed[-1]["absent_push_reuse"]
        self.assertEqual((alternate["source_sha"], alternate["source_run_id"]), (self.source, 37911654217))
        self.assertTrue(alternate["verification_required"])
        self.assertFalse(alternate["same_candidate_sha"])
        self.assertIn("exactly absent Preservation push", planner.moderation_ai_durable_reason(self.candidate))
        self.assertNotIn("older push", planner.moderation_ai_durable_reason("a" * 40))


class ModerationAIDurableScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_AI_DURABLE_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {(planner.MODERATION_AI_DURABLE_WORKFLOW_BLOBS | planner.MODERATION_AI_DURABLE_MIGRATION_INPUT_BLOBS).get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/moderation-ai-durable"})

    def test_exact_three_additions_require_five_backend_jobs_without_native_evidence(self):
        self.assertEqual([row[4] for row in self.rows().values()], ["A", "A", "A"])
        self.assertEqual(self.select(), planner.MODERATION_AI_DURABLE_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.MODERATION_AI_DURABLE_SCOPE),
                         planner.MODERATION_AI_DURABLE_JOBS)
        self.assertNotIn(planner.MODERATION_AI_DURABLE_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.MODERATION_AI_DURABLE_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.moderation_ai_durable_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in (*planner.MODERATION_AI_TRANSPORT_PATHS, *planner.MODERATION_AI_DURABLE_MIGRATION_INPUT_BLOBS, *planner.MODERATION_AI_PATHS, "NekoWidget/SharingService/src/moderation-operator-router.ts", "NekoWidget/SharingService/package-lock.json",
                        "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/moderation-ai-durable.md",
                        planner.MODERATION_AI_DURABLE_WORKFLOW, planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_AI_DURABLE_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_AI_DURABLE_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40),
                     ("c", "d" * 40), ("0" * 40, "invalid"), ("0" * 40, "d" * 40, "extra")):
            with patch.object(planner, "MODERATION_AI_DURABLE_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(original), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/moderation-ai-durable.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.MODERATION_AI_DURABLE_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_AI_DURABLE_SCOPE),
                             planner.MODERATION_AI_DURABLE_JOBS)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.MODERATION_AI_DURABLE_WORKFLOW_BLOBS.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        original = planner.MODERATION_AI_DURABLE_WORKFLOW_BLOBS
        for path in original:
            with patch.object(planner, "MODERATION_AI_DURABLE_WORKFLOW_BLOBS", original | {path: "0" * 40}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
        for invalid in ({}, {planner.MODERATION_AI_DURABLE_WORKFLOW: original[planner.MODERATION_AI_DURABLE_WORKFLOW]},
                        original | {planner.JPEG_WORKFLOW: "c" * 40}):
            with patch.object(planner, "MODERATION_AI_DURABLE_WORKFLOW_BLOBS", invalid):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/moderation-ai-durable", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.MODERATION_AI_DURABLE_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], list(planner.MODERATION_AI_DURABLE_JOBS))
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_AI_DURABLE_WORKFLOW, "job": job,
                     "head_sha": self.head, "event": "push", "success_required": True}
                    for job in planner.MODERATION_AI_DURABLE_JOBS])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.MODERATION_AI_DURABLE_WORKFLOW, summary)
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("All five jobs", summary)
                self.assertIn("full local D1 migration chain", summary)
                self.assertIn("does not certify their success", summary)


    def test_existing_graph_runs_four_sharing_jobs_and_preservation_for_this_source(self):
        workflow = (Path(__file__).resolve().parents[2] / planner.MODERATION_AI_DURABLE_WORKFLOW).read_text()
        blocks = dict(re.findall(r"(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow))
        ids = ("plan", "billing-verifier-check", "moderation-keygen-windows-policy", "check")
        self.assertEqual(tuple(re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1)
                               for name in ids), planner.MODERATION_AI_DURABLE_JOBS[:-1])
        self.assertEqual({re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1):
                          int(re.search(r"(?m)^    timeout-minutes: (\d+)$", blocks[name]).group(1))
                          for name in ids}, {job: timeout for job, timeout in planner.MODERATION_AI_DURABLE_JOB_TIMEOUTS.items()
                                            if job != planner.PRESERVATION_JOB})
        for name in ids[1:]:
            condition = re.search(r"(?m)^    if: (.+)$", blocks[name]).group(1)
            self.assertEqual("    if: " + condition,
                             planner.SHARING_FULL_CHECK_CONDITION + planner.SHARING_OPERATOR_GUARD)
            excluded = re.findall(r"needs.plan.outputs.scope != '([^']+)'", condition)
            self.assertNotIn(planner.MODERATION_AI_DURABLE_SCOPE, excluded)
        self.assertNotIn(planner.MODERATION_AI_DURABLE_SCOPE, blocks["private-billing-caller"])
        preservation = (Path(__file__).resolve().parents[2] / planner.PRESERVATION_WORKFLOW).read_text()
        self.assertIn('      - "NekoWidget/SharingService/src/**"', preservation)
        self.assertIn("    name: " + planner.PRESERVATION_JOB, preservation)
        self.assertIn("    timeout-minutes: 5", preservation)
        self.assertNotIn("    if:", preservation)
        self.assertEqual(planner.MODERATION_AI_DURABLE_JOBS[-1], planner.PRESERVATION_JOB)


    def test_migration_runner_inputs_require_exact_blobs_and_modes_at_both_ends(self):
        original = planner.MODERATION_AI_DURABLE_MIGRATION_INPUT_BLOBS
        for path, blob in original.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.ts"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
            with patch.object(planner, "MODERATION_AI_DURABLE_MIGRATION_INPUT_BLOBS", original | {path: "0" * 40}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
            with patch.object(planner, "MODERATION_AI_DURABLE_MIGRATION_INPUT_BLOBS",
                              {key: value for key, value in original.items() if key != path}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_AI_DURABLE_MIGRATION_INPUT_BLOBS", original | {"other.ts": "c" * 40}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_owning_worker_job_applies_all_local_migrations_before_discovered_tests(self):
        root = Path(__file__).resolve().parents[2]
        service = root / "NekoWidget/SharingService"
        package = json.loads((service / "package.json").read_text())
        self.assertTrue(package["scripts"]["check"].endswith(" && npm test"))
        self.assertEqual(package["scripts"]["test"], "vitest run")
        config = (service / "vitest.config.ts").read_text()
        self.assertIn('await readD1Migrations(path.join(import.meta.dirname, "migrations"))', config)
        self.assertIn('TEST_MIGRATIONS: migrations', config)
        self.assertIn('include: ["test/**/*.test.ts"]', config)
        self.assertIn('setupFiles: ["./test/setup.ts"]', config)
        setup = (service / "test/setup.ts").read_text()
        self.assertIn('await applyD1Migrations(testEnv.DB, testEnv.TEST_MIGRATIONS);', setup)
        workflow = (root / planner.MODERATION_AI_DURABLE_WORKFLOW).read_text()
        block = re.search(r"(?ms)^  check:\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow).group(1)
        self.assertIn('    name: Typecheck, test, and bundle Worker', block)
        self.assertIn('        working-directory: NekoWidget/SharingService\n        shell: bash\n        run: npm run check', block)
        self.assertIn('NekoWidget/SharingService/migrations/0030_moderation_advisory_jobs.sql',
                      planner.MODERATION_AI_DURABLE_PATHS)
        self.assertIn('NekoWidget/SharingService/test/moderation-ai-durable.test.ts',
                      planner.MODERATION_AI_DURABLE_PATHS)


    def corrected_rows(self):
        return self.rows() | {path: [":100644", "100644", before, after, "M"]
                              for path, (before, after) in planner.MODERATION_AI_DURABLE_FIXTURE_BLOBS.items()}

    def test_exact_fixture_correction_retains_original_shape_scope_and_five_jobs(self):
        original, corrected = self.rows(), self.corrected_rows()
        self.assertEqual([row[4] for row in corrected.values()], ["A", "A", "A", "M", "M", "M"])
        for rows in (original, corrected):
            self.assertEqual(self.select(rows), planner.MODERATION_AI_DURABLE_SCOPE)
            self.assertEqual(planner.required_jobs(list(rows), planner.MODERATION_AI_DURABLE_SCOPE),
                             planner.MODERATION_AI_DURABLE_JOBS)
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            self.assertEqual(self.select(corrected | {"handoffs/correction.md": fields}),
                             planner.MODERATION_AI_DURABLE_SCOPE)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"]):
            self.assertEqual(self.select(corrected | {"handoffs/correction.md": fields}), scope.FULL_SCOPE)

    def test_fixture_only_partial_unknown_modes_and_blobs_cannot_borrow_correction(self):
        corrected = self.corrected_rows()
        fixtures = list(planner.MODERATION_AI_DURABLE_FIXTURE_BLOBS)
        for mask in range(1, 7):
            subset = {path: corrected[path] for index, path in enumerate(fixtures) if mask & (1 << index)}
            self.assertEqual(self.select(subset), scope.FULL_SCOPE)
            self.assertEqual(self.select(self.rows() | subset), scope.FULL_SCOPE)
            self.assertEqual(planner.required_jobs(list(self.rows() | subset), planner.MODERATION_AI_DURABLE_SCOPE), planner.FULL)
        for path in planner.MODERATION_AI_DURABLE_PATHS:
            incomplete = {key: value for key, value in corrected.items() if key != path}
            self.assertEqual(self.select(incomplete), scope.FULL_SCOPE)
            self.assertEqual(planner.required_jobs(list(incomplete), planner.MODERATION_AI_DURABLE_SCOPE), planner.FULL)
        for fixture in fixtures:
            for index, value in ((0, ":000000"), (0, ":100755"), (1, "120000"), (1, "100755"),
                                 (2, "0" * 40), (2, "c" * 40), (3, "d" * 40),
                                 (4, "A"), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(corrected); changed[fixture][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (fixture, index, value))
        for unknown in ("NekoWidget/SharingService/scripts/other.node-tests.mjs",
                        "NekoWidget/ci/plan-ios-ci.py", *planner.MODERATION_AI_TRANSPORT_PATHS):
            changed = corrected | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_AI_DURABLE_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in corrected.items())
        fixture = fixtures[0]
        fixture_raw = " ".join(corrected[fixture]) + "\0" + fixture + "\0"
        self.assertEqual(self.select(raw=raw + fixture_raw, rows=corrected), scope.FULL_SCOPE)
        self.assertEqual(self.select(corrected, paths=list(corrected) + [fixture]), scope.FULL_SCOPE)

    def test_correction_still_requires_original_ancestry_and_fixed_execution_inputs(self):
        corrected = self.corrected_rows()
        self.assertEqual(self.select(corrected, ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(corrected, event="workflow_dispatch"), scope.FULL_SCOPE)
        for path in planner.MODERATION_AI_DURABLE_WORKFLOW_BLOBS | planner.MODERATION_AI_DURABLE_MIGRATION_INPUT_BLOBS:
            for revision in (self.base, self.head):
                self.assertEqual(self.select(corrected, workflows={(revision, path): ""}), scope.FULL_SCOPE)

    def test_invalid_fixture_registration_fails_closed_without_disabling_original_shape(self):
        corrected = self.corrected_rows()
        original = planner.MODERATION_AI_DURABLE_FIXTURE_BLOBS
        invalid_maps = [{}, {"other.mjs": ("c" * 40, "d" * 40)}]
        for fixture in original:
            invalid_maps.append({path: pair for path, pair in original.items() if path != fixture})
            invalid_maps.extend(original | {fixture: pair} for pair in (
                ("0" * 40, "d" * 40), ("c" * 40, "0" * 40), ("c" * 40, "c" * 40),
                ("bad", "d" * 40), ("c" * 40, "d" * 40, "extra")))
        for invalid in invalid_maps:
            with patch.object(planner, "MODERATION_AI_DURABLE_FIXTURE_BLOBS", invalid):
                self.assertEqual(self.select(corrected), scope.FULL_SCOPE)
                self.assertEqual(self.select(), planner.MODERATION_AI_DURABLE_SCOPE)


class ModerationEnrollmentCeremonyScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_ENROLLMENT_CEREMONY_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {(planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW_BLOBS | planner.MODERATION_ENROLLMENT_CEREMONY_INPUT_BLOBS).get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/operator-enrollment"})

    def test_exact_enrollment_product_batch_require_five_backend_jobs_without_native_evidence(self):
        self.assertEqual(len(self.rows()), 8)
        self.assertEqual(sum(row[4] == "M" for row in self.rows().values()), 3)
        self.assertEqual(sum(row[4] == "A" for row in self.rows().values()), 5)
        self.assertEqual(self.select(), planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE),
                         planner.MODERATION_ENROLLMENT_CEREMONY_JOBS)
        self.assertNotIn(planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.moderation_enrollment_ceremony_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in (*planner.MODERATION_AI_PATHS, "NekoWidget/SharingService/src/moderation-operator-router.ts", "NekoWidget/SharingService/package-lock.json",
                        "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/operator-enrollment.md",
                        planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW, planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_ENROLLMENT_CEREMONY_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40),
                     ("c", "d" * 40), ("0" * 40, "invalid"), ("0" * 40, "d" * 40, "extra")):
            with patch.object(planner, "MODERATION_ENROLLMENT_CEREMONY_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(original), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/operator-enrollment.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE),
                             planner.MODERATION_ENROLLMENT_CEREMONY_JOBS)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW_BLOBS.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        original = planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW_BLOBS
        for path in original:
            with patch.object(planner, "MODERATION_ENROLLMENT_CEREMONY_WORKFLOW_BLOBS", original | {path: "0" * 40}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
        for invalid in ({}, {planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW: original[planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW]},
                        original | {planner.JPEG_WORKFLOW: "c" * 40}):
            with patch.object(planner, "MODERATION_ENROLLMENT_CEREMONY_WORKFLOW_BLOBS", invalid):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/operator-enrollment", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], list(planner.MODERATION_ENROLLMENT_CEREMONY_JOBS))
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW, "job": job,
                     "head_sha": self.head, "event": "push", "success_required": True}
                    for job in planner.MODERATION_ENROLLMENT_CEREMONY_JOBS])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW, summary)
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("All five jobs", summary)
                self.assertIn("does not certify their success", summary)


    def test_existing_graph_runs_four_sharing_jobs_and_preservation_for_this_source(self):
        workflow = (Path(__file__).resolve().parents[2] / planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW).read_text()
        blocks = dict(re.findall(r"(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow))
        ids = ("plan", "billing-verifier-check", "moderation-keygen-windows-policy", "check")
        self.assertEqual(tuple(re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1)
                               for name in ids), planner.MODERATION_ENROLLMENT_CEREMONY_JOBS[:-1])
        self.assertEqual({re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1):
                          int(re.search(r"(?m)^    timeout-minutes: (\d+)$", blocks[name]).group(1))
                          for name in ids}, {job: timeout for job, timeout in planner.MODERATION_ENROLLMENT_CEREMONY_JOB_TIMEOUTS.items()
                                            if job != planner.PRESERVATION_JOB})
        for name in ids[1:]:
            condition = re.search(r"(?m)^    if: (.+)$", blocks[name]).group(1)
            self.assertEqual("    if: " + condition,
                             planner.SHARING_FULL_CHECK_CONDITION + planner.SHARING_OPERATOR_GUARD)
            excluded = re.findall(r"needs.plan.outputs.scope != '([^']+)'", condition)
            self.assertNotIn(planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE, excluded)
        self.assertNotIn(planner.MODERATION_ENROLLMENT_CEREMONY_SCOPE, blocks["private-billing-caller"])
        preservation = (Path(__file__).resolve().parents[2] / planner.PRESERVATION_WORKFLOW).read_text()
        self.assertIn('      - "NekoWidget/SharingService/src/**"', preservation)
        self.assertIn('      - "NekoWidget/SharingService/migrations/**"', preservation)
        self.assertIn("    name: " + planner.PRESERVATION_JOB, preservation)
        self.assertIn("    timeout-minutes: 5", preservation)
        self.assertNotIn("    if:", preservation)
        self.assertEqual(planner.MODERATION_ENROLLMENT_CEREMONY_JOBS[-1], planner.PRESERVATION_JOB)


    def test_crypto_public_disabled_entrypoints_and_test_inputs_are_fixed_at_both_ends(self):
        original = planner.MODERATION_ENROLLMENT_CEREMONY_INPUT_BLOBS
        for path, blob in original.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
            for replacement in ({key: value for key, value in original.items() if key != path},
                                original | {path: "0" * 40}, original | {"other.ts": "c" * 40}):
                with patch.object(planner, "MODERATION_ENROLLMENT_CEREMONY_INPUT_BLOBS", replacement):
                    self.assertEqual(self.select(), scope.FULL_SCOPE)


    def test_worker_and_windows_checks_cover_signature_migration_and_privacy_inputs(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW).read_text()
        self.assertIn("run: npm run check", workflow)
        self.assertIn("npm run check:moderation-tool", workflow)
        config = (root / "NekoWidget/SharingService/vitest.config.ts").read_text()
        setup = (root / "NekoWidget/SharingService/test/setup.ts").read_text()
        self.assertIn('readD1Migrations(path.join(import.meta.dirname, "migrations"))', config)
        self.assertIn('test/**/*.test.ts', config)
        self.assertIn('applyD1Migrations(testEnv.DB, testEnv.TEST_MIGRATIONS)', setup)
        for suffix in ("migrations/0033_moderation_operator_enrollment_ceremony.sql", "scripts/staging-config.node-tests.mjs",
                       "scripts/billing-sponsorship-local-drill.mjs", "test/billing-sponsorship-local-drill.node-tests.mjs",
                       "test/moderation-operator-enrollment-canonical.test.ts", "test/moderation-operator-enrollment-ceremony.test.ts"):
            self.assertIn("NekoWidget/SharingService/" + suffix, planner.MODERATION_ENROLLMENT_CEREMONY_PATHS)
        package = json.loads((root / "NekoWidget/SharingService/package.json").read_text())
        for command in ("npm run typecheck", "npm run check:moderation-operator-enrollment-trust",
                        "npm run check:moderation-operator-control-plane", "npm run check:moderation-operator-routes",
                        "npm run check:moderation-operator-webauthn-dependency", "npm run check:staging-config",
                        "npm run check:billing-sponsorship-local-drill", "npm test"):
            self.assertIn(command, package["scripts"]["check"])
        self.assertEqual(planner.moderation_enrollment_ceremony_requirements(planner.MODERATION_AI_DURABLE_REUSE_CANDIDATE), [
            {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_ENROLLMENT_CEREMONY_WORKFLOW,
             "job": job, "head_sha": planner.MODERATION_AI_DURABLE_REUSE_CANDIDATE, "event": "push", "success_required": True}
            for job in planner.MODERATION_ENROLLMENT_CEREMONY_JOBS])


class ModerationOperatorHostScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_OPERATOR_HOST_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {(planner.MODERATION_OPERATOR_HOST_WORKFLOW_BLOBS | planner.MODERATION_OPERATOR_HOST_INPUT_BLOBS).get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/initial-admission"})


    def test_exact_host_shape_and_required_owning_jobs(self):
        self.assertEqual(len(self.rows()),3)
        self.assertEqual(sum(row[4]=='M' for row in self.rows().values()),1)
        self.assertEqual(self.select(),planner.MODERATION_OPERATOR_HOST_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()),planner.MODERATION_OPERATOR_HOST_SCOPE),planner.MODERATION_OPERATOR_HOST_JOBS)
        self.assertNotIn(planner.MODERATION_OPERATOR_HOST_SCOPE,scope.SCOPES)
        expected=[{'workflow':planner.PRESERVATION_WORKFLOW if job==planner.PRESERVATION_JOB else planner.MODERATION_OPERATOR_HOST_WORKFLOW,'job':job,'head_sha':self.head,'event':'push','success_required':True} for job in planner.MODERATION_OPERATOR_HOST_JOBS]
        self.assertEqual(planner.moderation_operator_host_requirements(self.head),expected)

    def test_partial_unknown_duplicate_and_product_control_mix_are_full(self):
        rows=self.rows()
        for path in rows:
            self.assertEqual(self.select({p:r for p,r in rows.items() if p!=path}), 'full-v1')
        for path in ('NekoWidget/NekoWidget/ContentView.swift','NekoWidget/ci/preflight-ci.py','NekoWidget/SharingService/src/index.ts'):
            self.assertEqual(self.select(rows|{path:[':100644','100644','c'*40,'d'*40,'M']}),'full-v1')
        self.assertEqual(self.select(paths=list(rows)+[next(iter(rows))]),'full-v1')

    def test_modes_types_before_after_blobs_and_ancestry_fail_closed(self):
        for path,row in self.rows().items():
            for index,value in ((0,':100755'),(1,'100755'),(1,'120000'),(2,'e'*40),(3,'f'*40),(4,'D')):
                changed=self.rows();changed[path]=row.copy();changed[path][index]=value
                self.assertEqual(self.select(changed),'full-v1')
        self.assertEqual(self.select(ancestor=False),'full-v1')

    def test_all_auth_public_migration_config_and_workflow_inputs_are_pinned(self):
        for path in planner.MODERATION_OPERATOR_HOST_INPUT_BLOBS|planner.MODERATION_OPERATOR_HOST_WORKFLOW_BLOBS:
            for revision in (self.base,self.head):
                drift={(revision,path):f'100644 blob {"f"*40}\t{path}'}
                self.assertEqual(self.select(workflows=drift),'full-v1')

    def test_raw_duplicate_malformed_and_handoff_boundaries(self):
        rows=self.rows();raw=''.join(' '.join(r)+'\0'+p+'\0' for p,r in rows.items())
        self.assertEqual(self.select(raw=raw+raw),'full-v1')
        self.assertEqual(self.select(raw=raw+'not a raw record\0'),'full-v1')
        for status in ('A','M'):
            changed=rows|{'handoffs/2026-10-10-local-operator-host.md':[':000000' if status=='A' else ':100644','100644','0'*40 if status=='A' else 'c'*40,'d'*40,status]}
            self.assertEqual(self.select(changed),planner.MODERATION_OPERATOR_HOST_SCOPE)


class ModerationOperatorStartupScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_OPERATOR_STARTUP_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {(planner.MODERATION_OPERATOR_STARTUP_WORKFLOW_BLOBS | planner.MODERATION_OPERATOR_STARTUP_INPUT_BLOBS).get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/initial-admission"})


    def test_exact_host_shape_and_required_owning_jobs(self):
        self.assertEqual(len(self.rows()),5)
        self.assertEqual(sum(row[4]=='M' for row in self.rows().values()),1)
        self.assertEqual(self.select(),planner.MODERATION_OPERATOR_STARTUP_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()),planner.MODERATION_OPERATOR_STARTUP_SCOPE),planner.MODERATION_OPERATOR_STARTUP_JOBS)
        self.assertNotIn(planner.MODERATION_OPERATOR_STARTUP_SCOPE,scope.SCOPES)
        expected=[{'workflow':planner.PRESERVATION_WORKFLOW if job==planner.PRESERVATION_JOB else planner.MODERATION_OPERATOR_STARTUP_WORKFLOW,'job':job,'head_sha':self.head,'event':'push','success_required':True} for job in planner.MODERATION_OPERATOR_STARTUP_JOBS]
        self.assertEqual(planner.moderation_operator_startup_requirements(self.head),expected)

    def test_partial_unknown_duplicate_and_product_control_mix_are_full(self):
        rows=self.rows()
        for path in rows:
            self.assertEqual(self.select({p:r for p,r in rows.items() if p!=path}), 'full-v1')
        for path in ('NekoWidget/NekoWidget/ContentView.swift','NekoWidget/ci/preflight-ci.py','NekoWidget/SharingService/src/index.ts'):
            self.assertEqual(self.select(rows|{path:[':100644','100644','c'*40,'d'*40,'M']}),'full-v1')
        self.assertEqual(self.select(paths=list(rows)+[next(iter(rows))]),'full-v1')

    def test_modes_types_before_after_blobs_and_ancestry_fail_closed(self):
        for path,row in self.rows().items():
            for index,value in ((0,':100755'),(1,'100755'),(1,'120000'),(2,'e'*40),(3,'f'*40),(4,'D')):
                changed=self.rows();changed[path]=row.copy();changed[path][index]=value
                self.assertEqual(self.select(changed),'full-v1')
        self.assertEqual(self.select(ancestor=False),'full-v1')

    def test_all_auth_public_migration_config_and_workflow_inputs_are_pinned(self):
        for path in planner.MODERATION_OPERATOR_STARTUP_INPUT_BLOBS|planner.MODERATION_OPERATOR_STARTUP_WORKFLOW_BLOBS:
            for revision in (self.base,self.head):
                drift={(revision,path):f'100644 blob {"f"*40}\t{path}'}
                self.assertEqual(self.select(workflows=drift),'full-v1')

    def test_raw_duplicate_malformed_and_handoff_boundaries(self):
        rows=self.rows();raw=''.join(' '.join(r)+'\0'+p+'\0' for p,r in rows.items())
        self.assertEqual(self.select(raw=raw+raw),'full-v1')
        self.assertEqual(self.select(raw=raw+'not a raw record\0'),'full-v1')
        for status in ('A','M'):
            changed=rows|{'handoffs/2026-10-10-operator-local-startup.md':[':000000' if status=='A' else ':100644','100644','0'*40 if status=='A' else 'c'*40,'d'*40,status]}
            self.assertEqual(self.select(changed),planner.MODERATION_OPERATOR_STARTUP_SCOPE)


class ModerationInitialAdmissionScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_INITIAL_ADMISSION_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {(planner.MODERATION_INITIAL_ADMISSION_WORKFLOW_BLOBS | planner.MODERATION_INITIAL_ADMISSION_INPUT_BLOBS).get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/initial-admission"})

    def test_exact_enrollment_product_batch_require_five_backend_jobs_without_native_evidence(self):
        self.assertEqual(len(self.rows()), 10)
        self.assertEqual(sum(row[4] == "M" for row in self.rows().values()), 3)
        self.assertEqual(sum(row[4] == "A" for row in self.rows().values()), 7)
        self.assertEqual(self.select(), planner.MODERATION_INITIAL_ADMISSION_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.MODERATION_INITIAL_ADMISSION_SCOPE),
                         planner.MODERATION_INITIAL_ADMISSION_JOBS)
        self.assertNotIn(planner.MODERATION_INITIAL_ADMISSION_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.MODERATION_INITIAL_ADMISSION_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.moderation_initial_admission_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in (*planner.MODERATION_AI_PATHS, "NekoWidget/SharingService/src/moderation-operator-router.ts", "NekoWidget/SharingService/package-lock.json",
                        "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/operator-enrollment.md",
                        planner.MODERATION_INITIAL_ADMISSION_WORKFLOW, planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_INITIAL_ADMISSION_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_INITIAL_ADMISSION_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40),
                     ("c", "d" * 40), ("0" * 40, "invalid"), ("0" * 40, "d" * 40, "extra")):
            with patch.object(planner, "MODERATION_INITIAL_ADMISSION_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(original), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/operator-admission.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.MODERATION_INITIAL_ADMISSION_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_INITIAL_ADMISSION_SCOPE),
                             planner.MODERATION_INITIAL_ADMISSION_JOBS)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.MODERATION_INITIAL_ADMISSION_WORKFLOW_BLOBS.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        original = planner.MODERATION_INITIAL_ADMISSION_WORKFLOW_BLOBS
        for path in original:
            with patch.object(planner, "MODERATION_INITIAL_ADMISSION_WORKFLOW_BLOBS", original | {path: "0" * 40}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
        for invalid in ({}, {planner.MODERATION_INITIAL_ADMISSION_WORKFLOW: original[planner.MODERATION_INITIAL_ADMISSION_WORKFLOW]},
                        original | {planner.JPEG_WORKFLOW: "c" * 40}):
            with patch.object(planner, "MODERATION_INITIAL_ADMISSION_WORKFLOW_BLOBS", invalid):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/initial-admission", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.MODERATION_INITIAL_ADMISSION_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], list(planner.MODERATION_INITIAL_ADMISSION_JOBS))
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_INITIAL_ADMISSION_WORKFLOW, "job": job,
                     "head_sha": self.head, "event": "push", "success_required": True}
                    for job in planner.MODERATION_INITIAL_ADMISSION_JOBS])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.MODERATION_INITIAL_ADMISSION_WORKFLOW, summary)
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("All five jobs", summary)
                self.assertIn("does not certify their success", summary)


    def test_existing_graph_runs_four_sharing_jobs_and_preservation_for_this_source(self):
        workflow = (Path(__file__).resolve().parents[2] / planner.MODERATION_INITIAL_ADMISSION_WORKFLOW).read_text()
        blocks = dict(re.findall(r"(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow))
        ids = ("plan", "billing-verifier-check", "moderation-keygen-windows-policy", "check")
        self.assertEqual(tuple(re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1)
                               for name in ids), planner.MODERATION_INITIAL_ADMISSION_JOBS[:-1])
        self.assertEqual({re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1):
                          int(re.search(r"(?m)^    timeout-minutes: (\d+)$", blocks[name]).group(1))
                          for name in ids}, {job: timeout for job, timeout in planner.MODERATION_INITIAL_ADMISSION_JOB_TIMEOUTS.items()
                                            if job != planner.PRESERVATION_JOB})
        for name in ids[1:]:
            condition = re.search(r"(?m)^    if: (.+)$", blocks[name]).group(1)
            self.assertEqual("    if: " + condition,
                             planner.SHARING_FULL_CHECK_CONDITION + planner.SHARING_OPERATOR_GUARD)
            excluded = re.findall(r"needs.plan.outputs.scope != '([^']+)'", condition)
            self.assertNotIn(planner.MODERATION_INITIAL_ADMISSION_SCOPE, excluded)
        self.assertNotIn(planner.MODERATION_INITIAL_ADMISSION_SCOPE, blocks["private-billing-caller"])
        preservation = (Path(__file__).resolve().parents[2] / planner.PRESERVATION_WORKFLOW).read_text()
        self.assertIn('      - "NekoWidget/SharingService/src/**"', preservation)
        self.assertIn('      - "NekoWidget/SharingService/migrations/**"', preservation)
        self.assertIn("    name: " + planner.PRESERVATION_JOB, preservation)
        self.assertIn("    timeout-minutes: 5", preservation)
        self.assertNotIn("    if:", preservation)
        self.assertEqual(planner.MODERATION_INITIAL_ADMISSION_JOBS[-1], planner.PRESERVATION_JOB)


    def test_crypto_public_disabled_entrypoints_and_test_inputs_are_fixed_at_both_ends(self):
        original = planner.MODERATION_INITIAL_ADMISSION_INPUT_BLOBS
        for path, blob in original.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
            for replacement in ({key: value for key, value in original.items() if key != path},
                                original | {path: "0" * 40}, original | {"other.ts": "c" * 40}):
                with patch.object(planner, "MODERATION_INITIAL_ADMISSION_INPUT_BLOBS", replacement):
                    self.assertEqual(self.select(), scope.FULL_SCOPE)


    def test_worker_and_windows_checks_cover_signature_migration_and_privacy_inputs(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / planner.MODERATION_INITIAL_ADMISSION_WORKFLOW).read_text()
        self.assertIn("run: npm run check", workflow)
        self.assertIn("npm run check:moderation-tool", workflow)
        config = (root / "NekoWidget/SharingService/vitest.config.ts").read_text()
        setup = (root / "NekoWidget/SharingService/test/setup.ts").read_text()
        self.assertIn('readD1Migrations(path.join(import.meta.dirname, "migrations"))', config)
        self.assertIn('test/**/*.test.ts', config)
        self.assertIn('applyD1Migrations(testEnv.DB, testEnv.TEST_MIGRATIONS)', setup)
        for suffix in ("migrations/0034_moderation_operator_initial_admission.sql", "scripts/staging-config.node-tests.mjs",
                       "scripts/billing-sponsorship-local-drill.mjs", "test/billing-sponsorship-local-drill.node-tests.mjs",
                       "test/moderation-operator-enrollment-admission.test.ts", "test/moderation-operator-enrollment-local.test.ts"):
            self.assertIn("NekoWidget/SharingService/" + suffix, planner.MODERATION_INITIAL_ADMISSION_PATHS)
        package = json.loads((root / "NekoWidget/SharingService/package.json").read_text())
        for command in ("npm run typecheck", "npm run check:moderation-operator-enrollment-trust",
                        "npm run check:moderation-operator-control-plane", "npm run check:moderation-operator-routes",
                        "npm run check:moderation-operator-webauthn-dependency", "npm run check:staging-config",
                        "npm run check:billing-sponsorship-local-drill", "npm test"):
            self.assertIn(command, package["scripts"]["check"])
        self.assertEqual(planner.moderation_initial_admission_requirements(planner.MODERATION_AI_DURABLE_REUSE_CANDIDATE), [
            {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_INITIAL_ADMISSION_WORKFLOW,
             "job": job, "head_sha": planner.MODERATION_AI_DURABLE_REUSE_CANDIDATE, "event": "push", "success_required": True}
            for job in planner.MODERATION_INITIAL_ADMISSION_JOBS])


class ModerationOwnerFlowScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_OWNER_FLOW_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {(planner.MODERATION_OWNER_FLOW_WORKFLOW_BLOBS | planner.MODERATION_OWNER_FLOW_INPUT_BLOBS).get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/moderation-owner-flow"})

    def test_exact_owner_product_batch_require_five_backend_jobs_without_native_evidence(self):
        self.assertEqual(len(self.rows()), 18)
        self.assertEqual(sum(row[4] == "M" for row in self.rows().values()), 7)
        self.assertEqual(sum(row[4] == "A" for row in self.rows().values()), 11)
        self.assertEqual(self.select(), planner.MODERATION_OWNER_FLOW_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.MODERATION_OWNER_FLOW_SCOPE),
                         planner.MODERATION_OWNER_FLOW_JOBS)
        self.assertNotIn(planner.MODERATION_OWNER_FLOW_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.MODERATION_OWNER_FLOW_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.moderation_owner_flow_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in (*planner.MODERATION_AI_PATHS, "NekoWidget/SharingService/src/moderation-operator-router.ts", "NekoWidget/SharingService/package-lock.json",
                        "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/moderation-owner-flow.md",
                        planner.MODERATION_OWNER_FLOW_WORKFLOW, planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_OWNER_FLOW_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_OWNER_FLOW_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40),
                     ("c", "d" * 40), ("0" * 40, "invalid"), ("0" * 40, "d" * 40, "extra")):
            with patch.object(planner, "MODERATION_OWNER_FLOW_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(original), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/moderation-owner-flow.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.MODERATION_OWNER_FLOW_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_OWNER_FLOW_SCOPE),
                             planner.MODERATION_OWNER_FLOW_JOBS)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.MODERATION_OWNER_FLOW_WORKFLOW_BLOBS.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        original = planner.MODERATION_OWNER_FLOW_WORKFLOW_BLOBS
        for path in original:
            with patch.object(planner, "MODERATION_OWNER_FLOW_WORKFLOW_BLOBS", original | {path: "0" * 40}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
        for invalid in ({}, {planner.MODERATION_OWNER_FLOW_WORKFLOW: original[planner.MODERATION_OWNER_FLOW_WORKFLOW]},
                        original | {planner.JPEG_WORKFLOW: "c" * 40}):
            with patch.object(planner, "MODERATION_OWNER_FLOW_WORKFLOW_BLOBS", invalid):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/moderation-owner-flow", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.MODERATION_OWNER_FLOW_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], list(planner.MODERATION_OWNER_FLOW_JOBS))
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_OWNER_FLOW_WORKFLOW, "job": job,
                     "head_sha": self.head, "event": "push", "success_required": True}
                    for job in planner.MODERATION_OWNER_FLOW_JOBS])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.MODERATION_OWNER_FLOW_WORKFLOW, summary)
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("All five jobs", summary)
                self.assertIn("does not certify their success", summary)


    def test_existing_graph_runs_four_sharing_jobs_and_preservation_for_this_source(self):
        workflow = (Path(__file__).resolve().parents[2] / planner.MODERATION_OWNER_FLOW_WORKFLOW).read_text()
        blocks = dict(re.findall(r"(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow))
        ids = ("plan", "billing-verifier-check", "moderation-keygen-windows-policy", "check")
        self.assertEqual(tuple(re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1)
                               for name in ids), planner.MODERATION_OWNER_FLOW_JOBS[:-1])
        self.assertEqual({re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1):
                          int(re.search(r"(?m)^    timeout-minutes: (\d+)$", blocks[name]).group(1))
                          for name in ids}, {job: timeout for job, timeout in planner.MODERATION_OWNER_FLOW_JOB_TIMEOUTS.items()
                                            if job != planner.PRESERVATION_JOB})
        for name in ids[1:]:
            condition = re.search(r"(?m)^    if: (.+)$", blocks[name]).group(1)
            self.assertEqual("    if: " + condition,
                             planner.SHARING_FULL_CHECK_CONDITION + planner.SHARING_OPERATOR_GUARD)
            excluded = re.findall(r"needs.plan.outputs.scope != '([^']+)'", condition)
            self.assertNotIn(planner.MODERATION_OWNER_FLOW_SCOPE, excluded)
        self.assertNotIn(planner.MODERATION_OWNER_FLOW_SCOPE, blocks["private-billing-caller"])
        preservation = (Path(__file__).resolve().parents[2] / planner.PRESERVATION_WORKFLOW).read_text()
        self.assertIn('      - "NekoWidget/SharingService/src/**"', preservation)
        self.assertIn("    name: " + planner.PRESERVATION_JOB, preservation)
        self.assertIn("    timeout-minutes: 5", preservation)
        self.assertNotIn("    if:", preservation)
        self.assertEqual(planner.MODERATION_OWNER_FLOW_JOBS[-1], planner.PRESERVATION_JOB)


    def test_crypto_public_disabled_entrypoints_and_test_inputs_are_fixed_at_both_ends(self):
        original = planner.MODERATION_OWNER_FLOW_INPUT_BLOBS
        for path, blob in original.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
            for replacement in ({key: value for key, value in original.items() if key != path},
                                original | {path: "0" * 40}, original | {"other.ts": "c" * 40}):
                with patch.object(planner, "MODERATION_OWNER_FLOW_INPUT_BLOBS", replacement):
                    self.assertEqual(self.select(), scope.FULL_SCOPE)


    def test_worker_and_windows_checks_cover_migration_inventory_and_isolated_host(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / planner.MODERATION_OWNER_FLOW_WORKFLOW).read_text()
        self.assertIn("run: npm run check", workflow)
        self.assertIn("npm run check:moderation-tool", workflow)
        config = (root / "NekoWidget/SharingService/vitest.config.ts").read_text()
        setup = (root / "NekoWidget/SharingService/test/setup.ts").read_text()
        self.assertIn('readD1Migrations(path.join(import.meta.dirname, "migrations"))', config)
        self.assertIn('test/**/*.test.ts', config)
        self.assertIn('applyD1Migrations(testEnv.DB, testEnv.TEST_MIGRATIONS)', setup)
        for suffix in ("migrations/0031_moderation_owner_flow.sql", "scripts/staging-config.node-tests.mjs",
                       "scripts/billing-sponsorship-local-drill.mjs", "test/billing-sponsorship-local-drill.node-tests.mjs",
                       "test/moderation-owner-flow.test.ts", "test/moderation-owner.integration.test.ts",
                       "test/moderation-owner-review-host.node-tests.mjs"):
            self.assertIn("NekoWidget/SharingService/" + suffix, planner.MODERATION_OWNER_FLOW_PATHS)
        self.assertEqual(planner.moderation_owner_flow_requirements(planner.MODERATION_AI_DURABLE_REUSE_CANDIDATE), [
            {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_OWNER_FLOW_WORKFLOW,
             "job": job, "head_sha": planner.MODERATION_AI_DURABLE_REUSE_CANDIDATE, "event": "push", "success_required": True}
            for job in planner.MODERATION_OWNER_FLOW_JOBS])


class ModerationReviewEvidenceScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_REVIEW_EVIDENCE_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {(planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW_BLOBS | planner.MODERATION_REVIEW_EVIDENCE_INPUT_BLOBS).get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/moderation-review-evidence"})

    def test_exact_package_edit_and_four_additions_require_five_backend_jobs_without_native_evidence(self):
        self.assertEqual([row[4] for row in self.rows().values()], ["M", "A", "A", "A", "A"])
        self.assertEqual(self.select(), planner.MODERATION_REVIEW_EVIDENCE_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.MODERATION_REVIEW_EVIDENCE_SCOPE),
                         planner.MODERATION_REVIEW_EVIDENCE_JOBS)
        self.assertNotIn(planner.MODERATION_REVIEW_EVIDENCE_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.MODERATION_REVIEW_EVIDENCE_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.moderation_review_evidence_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in (*planner.MODERATION_AI_PATHS, "NekoWidget/SharingService/src/moderation-operator-router.ts", "NekoWidget/SharingService/package-lock.json",
                        "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/moderation-review-evidence.md",
                        planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW, planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_REVIEW_EVIDENCE_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_REVIEW_EVIDENCE_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40),
                     ("c", "d" * 40), ("0" * 40, "invalid"), ("0" * 40, "d" * 40, "extra")):
            with patch.object(planner, "MODERATION_REVIEW_EVIDENCE_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(original), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/moderation-review-evidence.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.MODERATION_REVIEW_EVIDENCE_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_REVIEW_EVIDENCE_SCOPE),
                             planner.MODERATION_REVIEW_EVIDENCE_JOBS)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW_BLOBS.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        original = planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW_BLOBS
        for path in original:
            with patch.object(planner, "MODERATION_REVIEW_EVIDENCE_WORKFLOW_BLOBS", original | {path: "0" * 40}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
        for invalid in ({}, {planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW: original[planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW]},
                        original | {planner.JPEG_WORKFLOW: "c" * 40}):
            with patch.object(planner, "MODERATION_REVIEW_EVIDENCE_WORKFLOW_BLOBS", invalid):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/moderation-review-evidence", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.MODERATION_REVIEW_EVIDENCE_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], list(planner.MODERATION_REVIEW_EVIDENCE_JOBS))
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW, "job": job,
                     "head_sha": self.head, "event": "push", "success_required": True}
                    for job in planner.MODERATION_REVIEW_EVIDENCE_JOBS])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW, summary)
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("All five jobs", summary)
                self.assertIn("does not certify their success", summary)


    def test_existing_graph_runs_four_sharing_jobs_and_preservation_for_this_source(self):
        workflow = (Path(__file__).resolve().parents[2] / planner.MODERATION_REVIEW_EVIDENCE_WORKFLOW).read_text()
        blocks = dict(re.findall(r"(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow))
        ids = ("plan", "billing-verifier-check", "moderation-keygen-windows-policy", "check")
        self.assertEqual(tuple(re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1)
                               for name in ids), planner.MODERATION_REVIEW_EVIDENCE_JOBS[:-1])
        self.assertEqual({re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1):
                          int(re.search(r"(?m)^    timeout-minutes: (\d+)$", blocks[name]).group(1))
                          for name in ids}, {job: timeout for job, timeout in planner.MODERATION_REVIEW_EVIDENCE_JOB_TIMEOUTS.items()
                                            if job != planner.PRESERVATION_JOB})
        for name in ids[1:]:
            condition = re.search(r"(?m)^    if: (.+)$", blocks[name]).group(1)
            self.assertEqual("    if: " + condition,
                             planner.SHARING_FULL_CHECK_CONDITION + planner.SHARING_OPERATOR_GUARD)
            excluded = re.findall(r"needs.plan.outputs.scope != '([^']+)'", condition)
            self.assertNotIn(planner.MODERATION_REVIEW_EVIDENCE_SCOPE, excluded)
        self.assertNotIn(planner.MODERATION_REVIEW_EVIDENCE_SCOPE, blocks["private-billing-caller"])
        preservation = (Path(__file__).resolve().parents[2] / planner.PRESERVATION_WORKFLOW).read_text()
        self.assertIn('      - "NekoWidget/SharingService/src/**"', preservation)
        self.assertIn("    name: " + planner.PRESERVATION_JOB, preservation)
        self.assertIn("    timeout-minutes: 5", preservation)
        self.assertNotIn("    if:", preservation)
        self.assertEqual(planner.MODERATION_REVIEW_EVIDENCE_JOBS[-1], planner.PRESERVATION_JOB)


    def test_crypto_public_disabled_entrypoints_and_test_inputs_are_fixed_at_both_ends(self):
        original = planner.MODERATION_REVIEW_EVIDENCE_INPUT_BLOBS
        for path, blob in original.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
            for replacement in ({key: value for key, value in original.items() if key != path},
                                original | {path: "0" * 40}, original | {"other.ts": "c" * 40}):
                with patch.object(planner, "MODERATION_REVIEW_EVIDENCE_INPUT_BLOBS", replacement):
                    self.assertEqual(self.select(), scope.FULL_SCOPE)


class ModerationConsoleScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_CONSOLE_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {(planner.MODERATION_CONSOLE_WORKFLOW_BLOBS | planner.MODERATION_CONSOLE_INPUT_BLOBS).get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/moderation-console"})

    def test_exact_addition_and_two_edits_require_five_backend_jobs_without_native_evidence(self):
        self.assertEqual([row[4] for row in self.rows().values()], ["A", "M", "M"])
        self.assertEqual(self.select(), planner.MODERATION_CONSOLE_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.MODERATION_CONSOLE_SCOPE),
                         planner.MODERATION_CONSOLE_JOBS)
        self.assertNotIn(planner.MODERATION_CONSOLE_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.MODERATION_CONSOLE_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.moderation_console_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in (*planner.MODERATION_AI_PATHS, "NekoWidget/SharingService/src/moderation-operator-router.ts", "NekoWidget/SharingService/package-lock.json",
                        "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/moderation-console.md",
                        planner.MODERATION_CONSOLE_WORKFLOW, planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_CONSOLE_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_CONSOLE_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40),
                     ("c", "d" * 40), ("0" * 40, "invalid"), ("0" * 40, "d" * 40, "extra")):
            with patch.object(planner, "MODERATION_CONSOLE_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(original), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/moderation-console.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.MODERATION_CONSOLE_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_CONSOLE_SCOPE),
                             planner.MODERATION_CONSOLE_JOBS)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.MODERATION_CONSOLE_WORKFLOW_BLOBS.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        original = planner.MODERATION_CONSOLE_WORKFLOW_BLOBS
        for path in original:
            with patch.object(planner, "MODERATION_CONSOLE_WORKFLOW_BLOBS", original | {path: "0" * 40}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
        for invalid in ({}, {planner.MODERATION_CONSOLE_WORKFLOW: original[planner.MODERATION_CONSOLE_WORKFLOW]},
                        original | {planner.JPEG_WORKFLOW: "c" * 40}):
            with patch.object(planner, "MODERATION_CONSOLE_WORKFLOW_BLOBS", invalid):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/moderation-console", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.MODERATION_CONSOLE_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], list(planner.MODERATION_CONSOLE_JOBS))
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_CONSOLE_WORKFLOW, "job": job,
                     "head_sha": self.head, "event": "push", "success_required": True}
                    for job in planner.MODERATION_CONSOLE_JOBS])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.MODERATION_CONSOLE_WORKFLOW, summary)
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("All five jobs", summary)
                self.assertIn("does not certify their success", summary)


    def test_existing_graph_runs_four_sharing_jobs_and_preservation_for_this_source(self):
        workflow = (Path(__file__).resolve().parents[2] / planner.MODERATION_CONSOLE_WORKFLOW).read_text()
        blocks = dict(re.findall(r"(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow))
        ids = ("plan", "billing-verifier-check", "moderation-keygen-windows-policy", "check")
        self.assertEqual(tuple(re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1)
                               for name in ids), planner.MODERATION_CONSOLE_JOBS[:-1])
        self.assertEqual({re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1):
                          int(re.search(r"(?m)^    timeout-minutes: (\d+)$", blocks[name]).group(1))
                          for name in ids}, {job: timeout for job, timeout in planner.MODERATION_CONSOLE_JOB_TIMEOUTS.items()
                                            if job != planner.PRESERVATION_JOB})
        for name in ids[1:]:
            condition = re.search(r"(?m)^    if: (.+)$", blocks[name]).group(1)
            self.assertEqual("    if: " + condition,
                             planner.SHARING_FULL_CHECK_CONDITION + planner.SHARING_OPERATOR_GUARD)
            excluded = re.findall(r"needs.plan.outputs.scope != '([^']+)'", condition)
            self.assertNotIn(planner.MODERATION_CONSOLE_SCOPE, excluded)
        self.assertNotIn(planner.MODERATION_CONSOLE_SCOPE, blocks["private-billing-caller"])
        preservation = (Path(__file__).resolve().parents[2] / planner.PRESERVATION_WORKFLOW).read_text()
        self.assertIn('      - "NekoWidget/SharingService/src/**"', preservation)
        self.assertIn("    name: " + planner.PRESERVATION_JOB, preservation)
        self.assertIn("    timeout-minutes: 5", preservation)
        self.assertNotIn("    if:", preservation)
        self.assertEqual(planner.MODERATION_CONSOLE_JOBS[-1], planner.PRESERVATION_JOB)


    def test_fixed_public_disabled_entrypoints_and_test_inputs_are_required_at_both_ends(self):
        original = planner.MODERATION_CONSOLE_INPUT_BLOBS
        for path, blob in original.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
            for replacement in ({key: value for key, value in original.items() if key != path},
                                original | {path: "0" * 40}, original | {"other.ts": "c" * 40}):
                with patch.object(planner, "MODERATION_CONSOLE_INPUT_BLOBS", replacement):
                    self.assertEqual(self.select(), scope.FULL_SCOPE)


class ModerationAITransportScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_AI_TRANSPORT_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.MODERATION_AI_TRANSPORT_WORKFLOW_BLOBS.get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/moderation-ai-transport"})

    def test_exact_two_additions_require_five_backend_jobs_without_native_evidence(self):
        self.assertEqual([row[4] for row in self.rows().values()], ["A", "A"])
        self.assertEqual(self.select(), planner.MODERATION_AI_TRANSPORT_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.MODERATION_AI_TRANSPORT_SCOPE),
                         planner.MODERATION_AI_TRANSPORT_JOBS)
        self.assertNotIn(planner.MODERATION_AI_TRANSPORT_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.MODERATION_AI_TRANSPORT_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.moderation_ai_transport_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in (*planner.MODERATION_AI_PATHS, "NekoWidget/SharingService/src/moderation-operator-router.ts", "NekoWidget/SharingService/package-lock.json",
                        "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/moderation-ai-transport.md",
                        planner.MODERATION_AI_TRANSPORT_WORKFLOW, planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_AI_TRANSPORT_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_AI_TRANSPORT_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40),
                     ("c", "d" * 40), ("0" * 40, "invalid"), ("0" * 40, "d" * 40, "extra")):
            with patch.object(planner, "MODERATION_AI_TRANSPORT_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(original), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/moderation-ai-transport.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.MODERATION_AI_TRANSPORT_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_AI_TRANSPORT_SCOPE),
                             planner.MODERATION_AI_TRANSPORT_JOBS)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.MODERATION_AI_TRANSPORT_WORKFLOW_BLOBS.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        original = planner.MODERATION_AI_TRANSPORT_WORKFLOW_BLOBS
        for path in original:
            with patch.object(planner, "MODERATION_AI_TRANSPORT_WORKFLOW_BLOBS", original | {path: "0" * 40}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
        for invalid in ({}, {planner.MODERATION_AI_TRANSPORT_WORKFLOW: original[planner.MODERATION_AI_TRANSPORT_WORKFLOW]},
                        original | {planner.JPEG_WORKFLOW: "c" * 40}):
            with patch.object(planner, "MODERATION_AI_TRANSPORT_WORKFLOW_BLOBS", invalid):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/moderation-ai-transport", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.MODERATION_AI_TRANSPORT_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], list(planner.MODERATION_AI_TRANSPORT_JOBS))
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_AI_TRANSPORT_WORKFLOW, "job": job,
                     "head_sha": self.head, "event": "push", "success_required": True}
                    for job in planner.MODERATION_AI_TRANSPORT_JOBS])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.MODERATION_AI_TRANSPORT_WORKFLOW, summary)
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("All five jobs", summary)
                self.assertIn("does not certify their success", summary)


    def test_existing_graph_runs_four_sharing_jobs_and_preservation_for_this_source(self):
        workflow = (Path(__file__).resolve().parents[2] / planner.MODERATION_AI_TRANSPORT_WORKFLOW).read_text()
        blocks = dict(re.findall(r"(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow))
        ids = ("plan", "billing-verifier-check", "moderation-keygen-windows-policy", "check")
        self.assertEqual(tuple(re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1)
                               for name in ids), planner.MODERATION_AI_TRANSPORT_JOBS[:-1])
        self.assertEqual({re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1):
                          int(re.search(r"(?m)^    timeout-minutes: (\d+)$", blocks[name]).group(1))
                          for name in ids}, {job: timeout for job, timeout in planner.MODERATION_AI_TRANSPORT_JOB_TIMEOUTS.items()
                                            if job != planner.PRESERVATION_JOB})
        for name in ids[1:]:
            condition = re.search(r"(?m)^    if: (.+)$", blocks[name]).group(1)
            self.assertEqual("    if: " + condition,
                             planner.SHARING_FULL_CHECK_CONDITION + planner.SHARING_OPERATOR_GUARD)
            excluded = re.findall(r"needs.plan.outputs.scope != '([^']+)'", condition)
            self.assertNotIn(planner.MODERATION_AI_TRANSPORT_SCOPE, excluded)
        self.assertNotIn(planner.MODERATION_AI_TRANSPORT_SCOPE, blocks["private-billing-caller"])
        preservation = (Path(__file__).resolve().parents[2] / planner.PRESERVATION_WORKFLOW).read_text()
        self.assertIn('      - "NekoWidget/SharingService/src/**"', preservation)
        self.assertIn("    name: " + planner.PRESERVATION_JOB, preservation)
        self.assertIn("    timeout-minutes: 5", preservation)
        self.assertNotIn("    if:", preservation)
        self.assertEqual(planner.MODERATION_AI_TRANSPORT_JOBS[-1], planner.PRESERVATION_JOB)


class ModerationAIAdvisoryScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_AI_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.MODERATION_AI_WORKFLOW_BLOBS.get(path, 'unregistered')}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/moderation-ai-advisory"})

    def test_exact_two_additions_require_five_backend_jobs_without_native_evidence(self):
        self.assertEqual([row[4] for row in self.rows().values()], ["A", "A"])
        self.assertEqual(self.select(), planner.MODERATION_AI_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.MODERATION_AI_SCOPE),
                         planner.MODERATION_AI_JOBS)
        self.assertNotIn(planner.MODERATION_AI_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.MODERATION_AI_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.moderation_ai_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/SharingService/src/moderation-operator-router.ts", "NekoWidget/SharingService/package-lock.json",
                        "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/moderation-ai-advisory.md",
                        planner.MODERATION_AI_WORKFLOW, planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_AI_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_AI_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40),
                     ("c", "d" * 40), ("0" * 40, "invalid"), ("0" * 40, "d" * 40, "extra")):
            with patch.object(planner, "MODERATION_AI_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(original), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/moderation-ai-advisory.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.MODERATION_AI_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_AI_SCOPE),
                             planner.MODERATION_AI_JOBS)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.MODERATION_AI_WORKFLOW_BLOBS.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        original = planner.MODERATION_AI_WORKFLOW_BLOBS
        for path in original:
            with patch.object(planner, "MODERATION_AI_WORKFLOW_BLOBS", original | {path: "0" * 40}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)
        for invalid in ({}, {planner.MODERATION_AI_WORKFLOW: original[planner.MODERATION_AI_WORKFLOW]},
                        original | {planner.JPEG_WORKFLOW: "c" * 40}):
            with patch.object(planner, "MODERATION_AI_WORKFLOW_BLOBS", invalid):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/moderation-ai-advisory", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.MODERATION_AI_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], list(planner.MODERATION_AI_JOBS))
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW if job == planner.PRESERVATION_JOB else planner.MODERATION_AI_WORKFLOW, "job": job,
                     "head_sha": self.head, "event": "push", "success_required": True}
                    for job in planner.MODERATION_AI_JOBS])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.MODERATION_AI_WORKFLOW, summary)
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("All five jobs", summary)
                self.assertIn("does not certify their success", summary)


    def test_existing_graph_runs_four_sharing_jobs_and_preservation_for_this_source(self):
        workflow = (Path(__file__).resolve().parents[2] / planner.MODERATION_AI_WORKFLOW).read_text()
        blocks = dict(re.findall(r"(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow))
        ids = ("plan", "billing-verifier-check", "moderation-keygen-windows-policy", "check")
        self.assertEqual(tuple(re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1)
                               for name in ids), planner.MODERATION_AI_JOBS[:-1])
        self.assertEqual({re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1):
                          int(re.search(r"(?m)^    timeout-minutes: (\d+)$", blocks[name]).group(1))
                          for name in ids}, {job: timeout for job, timeout in planner.MODERATION_AI_JOB_TIMEOUTS.items()
                                            if job != planner.PRESERVATION_JOB})
        for name in ids[1:]:
            condition = re.search(r"(?m)^    if: (.+)$", blocks[name]).group(1)
            self.assertEqual("    if: " + condition,
                             planner.SHARING_FULL_CHECK_CONDITION + planner.SHARING_OPERATOR_GUARD)
            excluded = re.findall(r"needs.plan.outputs.scope != '([^']+)'", condition)
            self.assertNotIn(planner.MODERATION_AI_SCOPE, excluded)
        self.assertNotIn(planner.MODERATION_AI_SCOPE, blocks["private-billing-caller"])
        preservation = (Path(__file__).resolve().parents[2] / planner.PRESERVATION_WORKFLOW).read_text()
        self.assertIn('      - "NekoWidget/SharingService/src/**"', preservation)
        self.assertIn("    name: " + planner.PRESERVATION_JOB, preservation)
        self.assertIn("    timeout-minutes: 5", preservation)
        self.assertNotIn("    if:", preservation)
        self.assertEqual(planner.MODERATION_AI_JOBS[-1], planner.PRESERVATION_JOB)


class ModerationEnrollmentScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.MODERATION_ENROLLMENT_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.MODERATION_ENROLLMENT_WORKFLOW_BLOB}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/moderation-enrollment"})

    def test_exact_three_paths_require_the_existing_backend_job_without_native_evidence(self):
        self.assertEqual([row[4] for row in self.rows().values()], ["M", "A", "M"])
        self.assertEqual(self.select(), planner.MODERATION_ENROLLMENT_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.MODERATION_ENROLLMENT_SCOPE),
                         planner.MODERATION_ENROLLMENT_JOBS)
        self.assertNotIn(planner.MODERATION_ENROLLMENT_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.MODERATION_ENROLLMENT_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.moderation_enrollment_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "T"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/SharingService/src/moderation-operator-router.ts", "NekoWidget/SharingService/package-lock.json",
                        "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/moderation-enrollment.md",
                        planner.MODERATION_ENROLLMENT_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_ENROLLMENT_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_ENROLLMENT_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("0" * 40, "d" * 40), ("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40), ("c", "d" * 40)):
            with patch.object(planner, "MODERATION_ENROLLMENT_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/moderation-enrollment.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.MODERATION_ENROLLMENT_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.MODERATION_ENROLLMENT_SCOPE),
                             planner.MODERATION_ENROLLMENT_JOBS)
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in ((planner.MODERATION_ENROLLMENT_WORKFLOW, planner.MODERATION_ENROLLMENT_WORKFLOW_BLOB),):
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        with patch.object(planner, "MODERATION_ENROLLMENT_WORKFLOW_BLOB", "0" * 40):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/moderation-enrollment", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.MODERATION_ENROLLMENT_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], list(planner.MODERATION_ENROLLMENT_JOBS))
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.MODERATION_ENROLLMENT_WORKFLOW, "job": job,
                     "head_sha": self.head, "event": "push", "success_required": True}
                    for job in planner.MODERATION_ENROLLMENT_JOBS])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.MODERATION_ENROLLMENT_WORKFLOW, summary)
                self.assertIn("does not certify their success", summary)


    def test_existing_sharing_graph_runs_all_four_jobs_for_this_scope(self):
        workflow = (Path(__file__).resolve().parents[2] / planner.MODERATION_ENROLLMENT_WORKFLOW).read_text()
        blocks = dict(re.findall(r"(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)", workflow))
        ids = ("plan", "billing-verifier-check", "moderation-keygen-windows-policy", "check")
        self.assertEqual(tuple(re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1)
                               for name in ids), planner.MODERATION_ENROLLMENT_JOBS)
        self.assertEqual({re.search(r"(?m)^    name: (.+)$", blocks[name]).group(1):
                          int(re.search(r"(?m)^    timeout-minutes: (\d+)$", blocks[name]).group(1))
                          for name in ids}, planner.MODERATION_ENROLLMENT_JOB_TIMEOUTS)
        for name in ids[1:]:
            condition = re.search(r"(?m)^    if: (.+)$", blocks[name]).group(1)
            self.assertEqual("    if: " + condition,
                             planner.SHARING_FULL_CHECK_CONDITION + planner.SHARING_OPERATOR_GUARD)
            excluded = re.findall(r"needs.plan.outputs.scope != '([^']+)'", condition)
            self.assertNotIn(planner.MODERATION_ENROLLMENT_SCOPE, excluded)
        self.assertNotIn(planner.MODERATION_ENROLLMENT_SCOPE, blocks["private-billing-caller"])


class PreservationRecoveryReadScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.PRESERVATION_RECOVERY_READ_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.PRESERVATION_RECOVERY_READ_WORKFLOW_BLOB}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/recovery-read"})

    def test_exact_two_paths_require_the_existing_backend_job_without_native_evidence(self):
        self.assertEqual([row[4] for row in self.rows().values()], ["M", "A"])
        self.assertEqual(self.select(), planner.PRESERVATION_RECOVERY_READ_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.PRESERVATION_RECOVERY_READ_SCOPE),
                         (planner.PRESERVATION_JOB,))
        self.assertNotIn(planner.PRESERVATION_RECOVERY_READ_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.PRESERVATION_RECOVERY_READ_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.preservation_recovery_read_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/PreservationService/src/bounded-body.ts", "NekoWidget/PreservationService/src/request-json.ts",
                        "NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/recovery-read.md",
                        planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_RECOVERY_READ_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_RECOVERY_READ_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("0" * 40, "d" * 40), ("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40), ("c", "d" * 40)):
            with patch.object(planner, "PRESERVATION_RECOVERY_READ_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/recovery-read.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.PRESERVATION_RECOVERY_READ_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_RECOVERY_READ_SCOPE),
                             (planner.PRESERVATION_JOB,))
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in ((planner.PRESERVATION_WORKFLOW, planner.PRESERVATION_RECOVERY_READ_WORKFLOW_BLOB),):
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_RECOVERY_READ_WORKFLOW_BLOB", "0" * 40):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/recovery-read", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_RECOVERY_READ_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB])
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
                     "head_sha": self.head, "success_required": True}])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("does not certify that job's success", summary)


class PreservationRequestBufferScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.PRESERVATION_REQUEST_BUFFER_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.PRESERVATION_REQUEST_BUFFER_WORKFLOW_BLOB}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/request-buffer"})

    def test_exact_three_paths_require_the_existing_backend_job_without_native_evidence(self):
        self.assertEqual([row[4] for row in self.rows().values()], ["M", "A", "A"])
        self.assertEqual(self.select(), planner.PRESERVATION_REQUEST_BUFFER_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.PRESERVATION_REQUEST_BUFFER_SCOPE),
                         (planner.PRESERVATION_JOB,))
        self.assertNotIn(planner.PRESERVATION_REQUEST_BUFFER_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.PRESERVATION_REQUEST_BUFFER_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.preservation_request_buffer_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/PreservationService/src/bounded-body.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/request-buffer.md",
                        planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_REQUEST_BUFFER_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_REQUEST_BUFFER_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("0" * 40, "d" * 40), ("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c" * 40, "d" * 40), ("c", "d" * 40)):
            with patch.object(planner, "PRESERVATION_REQUEST_BUFFER_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/request-buffer.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.PRESERVATION_REQUEST_BUFFER_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_REQUEST_BUFFER_SCOPE),
                             (planner.PRESERVATION_JOB,))
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in ((planner.PRESERVATION_WORKFLOW, planner.PRESERVATION_REQUEST_BUFFER_WORKFLOW_BLOB),):
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_REQUEST_BUFFER_WORKFLOW_BLOB", "0" * 40):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/request-buffer", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_REQUEST_BUFFER_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB])
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
                     "head_sha": self.head, "success_required": True}])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("does not certify that job's success", summary)


class PreservationPhotoUploadBodyScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.PRESERVATION_PHOTO_UPLOAD_BODY_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.PRESERVATION_PHOTO_UPLOAD_BODY_WORKFLOW_BLOB}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/photo-upload-body"})

    def test_exact_six_paths_require_the_existing_backend_job_without_native_evidence(self):
        self.assertEqual(self.select(), planner.PRESERVATION_PHOTO_UPLOAD_BODY_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.PRESERVATION_PHOTO_UPLOAD_BODY_SCOPE),
                         (planner.PRESERVATION_JOB,))
        self.assertNotIn(planner.PRESERVATION_PHOTO_UPLOAD_BODY_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.PRESERVATION_PHOTO_UPLOAD_BODY_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.preservation_photo_upload_body_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/PreservationService/src/auth.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/r2-view.md",
                        planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_PHOTO_UPLOAD_BODY_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_PHOTO_UPLOAD_BODY_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("0" * 40, "d" * 40), ("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c", "d" * 40)):
            with patch.object(planner, "PRESERVATION_PHOTO_UPLOAD_BODY_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/photo-upload-body.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.PRESERVATION_PHOTO_UPLOAD_BODY_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_PHOTO_UPLOAD_BODY_SCOPE),
                             (planner.PRESERVATION_JOB,))
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in ((planner.PRESERVATION_WORKFLOW, planner.PRESERVATION_PHOTO_UPLOAD_BODY_WORKFLOW_BLOB),):
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_PHOTO_UPLOAD_BODY_WORKFLOW_BLOB", "0" * 40):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/photo-upload-body", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_PHOTO_UPLOAD_BODY_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB])
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
                     "head_sha": self.head, "event": "push", "success_required": True}])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("does not certify that job's success", summary)


class PreservationOwnedBuffersScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.PRESERVATION_OWNED_BUFFERS_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.PRESERVATION_OWNED_BUFFERS_WORKFLOW_BLOB}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/owned-buffers"})

    def test_exact_four_paths_require_the_existing_backend_job_without_native_evidence(self):
        self.assertEqual(self.select(), planner.PRESERVATION_OWNED_BUFFERS_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.PRESERVATION_OWNED_BUFFERS_SCOPE),
                         (planner.PRESERVATION_JOB,))
        self.assertNotIn(planner.PRESERVATION_OWNED_BUFFERS_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.PRESERVATION_OWNED_BUFFERS_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.preservation_owned_buffers_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/r2-view.md",
                        planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_OWNED_BUFFERS_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_OWNED_BUFFERS_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("0" * 40, "d" * 40), ("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c", "d" * 40)):
            with patch.object(planner, "PRESERVATION_OWNED_BUFFERS_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/owned-buffers.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.PRESERVATION_OWNED_BUFFERS_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_OWNED_BUFFERS_SCOPE),
                             (planner.PRESERVATION_JOB,))
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in ((planner.PRESERVATION_WORKFLOW, planner.PRESERVATION_OWNED_BUFFERS_WORKFLOW_BLOB),):
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_OWNED_BUFFERS_WORKFLOW_BLOB", "0" * 40):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/owned-buffers", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_OWNED_BUFFERS_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB])
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
                     "head_sha": self.head, "event": "push", "success_required": True}])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("does not certify that job's success", summary)


class PreservationR2ViewScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.PRESERVATION_R2_VIEW_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.PRESERVATION_R2_VIEW_WORKFLOW_BLOB}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/r2-view"})

    def test_exact_two_paths_require_the_existing_backend_job_without_native_evidence(self):
        self.assertEqual(self.select(), planner.PRESERVATION_R2_VIEW_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.PRESERVATION_R2_VIEW_SCOPE),
                         (planner.PRESERVATION_JOB,))
        self.assertNotIn(planner.PRESERVATION_R2_VIEW_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.PRESERVATION_R2_VIEW_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.preservation_r2_view_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/r2-view.md",
                        planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_R2_VIEW_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_R2_VIEW_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("0" * 40, "d" * 40), ("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c", "d" * 40)):
            with patch.object(planner, "PRESERVATION_R2_VIEW_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/r2-view.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.PRESERVATION_R2_VIEW_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_R2_VIEW_SCOPE),
                             (planner.PRESERVATION_JOB,))
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in ((planner.PRESERVATION_WORKFLOW, planner.PRESERVATION_R2_VIEW_WORKFLOW_BLOB),):
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_R2_VIEW_WORKFLOW_BLOB", "0" * 40):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/r2-view", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_R2_VIEW_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB])
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
                     "head_sha": self.head, "success_required": True}])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("does not certify that job's success", summary)


class PreservationRecoveryChunksScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.PRESERVATION_RECOVERY_CHUNKS_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.PRESERVATION_RECOVERY_CHUNKS_IMMUTABLE[path]}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/recovery-chunks"})

    def test_exact_two_paths_require_the_existing_backend_job_without_native_evidence(self):
        self.assertEqual(self.select(), planner.PRESERVATION_RECOVERY_CHUNKS_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.PRESERVATION_RECOVERY_CHUNKS_SCOPE),
                         (planner.PRESERVATION_JOB,))
        self.assertNotIn(planner.PRESERVATION_RECOVERY_CHUNKS_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.PRESERVATION_RECOVERY_CHUNKS_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.preservation_recovery_chunks_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/recovery-chunks.md",
                        planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_RECOVERY_CHUNKS_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_RECOVERY_CHUNKS_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("0" * 40, "d" * 40), ("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c", "d" * 40)):
            with patch.object(planner, "PRESERVATION_RECOVERY_CHUNKS_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/recovery-chunks.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.PRESERVATION_RECOVERY_CHUNKS_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_RECOVERY_CHUNKS_SCOPE),
                             (planner.PRESERVATION_JOB,))
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.PRESERVATION_RECOVERY_CHUNKS_IMMUTABLE.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_RECOVERY_CHUNKS_IMMUTABLE", {planner.PRESERVATION_WORKFLOW: "0" * 40}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/recovery-chunks", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_RECOVERY_CHUNKS_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB])
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
                     "head_sha": self.head, "success_required": True}])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("does not certify that job's success", summary)


class ToolBuildRecoveryInputTests(unittest.TestCase):
    def verify(self, *, extra=None, mode="100644", registration=True, approved=True, ancestor=True, signed=True, checkline=True, raw=None, inventory=True):
        p=planner;head="a"*40;approval="b"*40
        release="NekoWidget/ci/release-testflight.py"
        rows={release:[":100644",mode,"8cc1d532e0c53346aacdf0c9f634baabcd170fdf",p.TOOL_RESTORED_RELEASE,"M"],
              "NekoWidget/ci/plan-ios-ci.py":[":100644","100644","c"*40,"d"*40,"M"],
              "NekoWidget/ci/check-development-flow.py":[":100644","100644","c"*40,"d"*40,"M"]}
        if extra:rows.update(extra)
        def git(*args):
            if args[0]=="merge-base":
                if not ancestor and "--is-ancestor" in args:raise subprocess.CalledProcessError(1,args)
                return approval
            if args[0]=="diff":return raw if raw is not None else "".join(" ".join(fields)+"\0"+path+"\0" for path,fields in rows.items())
            if args[0]=="ls-tree":
                ref,path=args[1],args[3]
                blob=p.TOOL_RESTORED_RELEASE if path==release else "e"*40
                if not signed and path==release:blob="f"*40
                if not approved and ref==head:blob="f"*40
                if not inventory and ref==p.TOOL_BUILD_SOURCE and path.endswith("ios_ci_scope.py"):blob="c"*40
                return f"100644 blob {blob}\t{path}"
            if args[0]=="show":
                if args[1].endswith("plan-ios-ci.py"):return f'TOOL_BUILD_SOURCE = "{p.TOOL_BUILD_SOURCE}"' if registration else "unapproved"
                before="CHECKS = (\n)\n"
                if args[1].startswith(p.TOOL_BUILD_SOURCE+":"):return before
                return before.replace("(\n",'(\n    "test-media-staging-release-config.py",\n') if checkline else before
            raise AssertionError(args)
        with patch.object(p,"git",side_effect=git),patch.object(p,"tool_preservation_immutable_inputs",return_value=True):return p.tool_recovery_inputs(head)

    def test_signed_original_and_exact_approved_eight_controls_only(self):
        self.assertTrue(self.verify())
        for kwargs in ({"registration":False},{"approved":False},{"ancestor":False},{"signed":False},{"checkline":False},{"inventory":False},
                       {"mode":"100755"},{"mode":"120000"},{"mode":"160000"},{"raw":"malformed\0"}):
            self.assertFalse(self.verify(**kwargs),kwargs)
        for path in ("NekoWidget/ci/moderation-v2-readiness.json","NekoWidget/ci/verify-moderation-readiness.mjs",
                     "NekoWidget/ci/test-moderation-readiness.mjs",planner.MEMORY_TEST_PATH,
                     planner.PRESERVATION_WORKFLOW,"NekoWidget/ci/unknown.py","NekoWidget/Shared/unknown.swift"):
            self.assertFalse(self.verify(extra={path:[":100644","100644","c"*40,"d"*40,"M"]}),path)
        self.assertTrue(self.verify(extra={"handoffs/result.md":[":000000","100644","0"*40,"d"*40,"A"]}))
        self.assertFalse(self.verify(extra={"handoffs/result.md":[":100644","120000","c"*40,"d"*40,"M"]}))

    def test_fixed_observation_never_accepts_unknown_repo_or_endpoint_and_captures_escapes(self):
        response=subprocess.CompletedProcess([],0,stdout='{"sha":"observed"}',stderr="")
        path=f"repos/soso-so-27/neko-widget/git/commits/{planner.TOOL_PR_MERGE}"
        with patch.object(planner.subprocess,"run",return_value=response) as command:
            self.assertEqual(planner.tool_fixed_observation(path),{"sha":"observed"})
            self.assertTrue(command.call_args.kwargs["capture_output"])
            self.assertEqual(command.call_args.args[0][:7],["gh","api","--hostname","github.com","--method","GET",path])
            for bad in ("repos/other/repo/git/commits/"+planner.TOOL_PR_MERGE,"repos/soso-so-27/neko-widget/actions/workflows/ios-build.yml/dispatches",path+"/extra"):
                with self.assertRaises(ValueError):planner.tool_fixed_observation(bad)
            self.assertEqual(command.call_count,1)

    def test_only_exact_debug_message_pair_is_added_to_the_historical_closure(self):
        p=planner
        row=[":100644","100644",*p.TOOL_PRIVACY_PAIR,"M"]
        self.assertTrue(self.verify(extra={p.TOOL_PRIVACY_PATH:row}))
        for index,value in ((0,":000000"),(1,"100755"),(2,"c"*40),(3,"d"*40),(4,"A")):
            changed=list(row);changed[index]=value
            self.assertFalse(self.verify(extra={p.TOOL_PRIVACY_PATH:changed}))
        def check(*,ancestor=True,before=True,after=True,approved=True,mode="100644"):
            def git(*args):
                if args[0]=="merge-base":
                    if not ancestor:raise subprocess.CalledProcessError(1,args)
                    return ""
                blob=p.TOOL_PRIVACY_PAIR[0] if args[1]==p.TOOL_PRIVACY_FAILED_SOURCE else p.TOOL_PRIVACY_PAIR[1]
                if (args[1]==p.TOOL_PRIVACY_FAILED_SOURCE and not before) or (args[1]!=p.TOOL_PRIVACY_FAILED_SOURCE and not after):blob="f"*40
                return f"{mode} blob {blob}\t{p.TOOL_PRIVACY_PATH}"
            with patch.object(p,"git",side_effect=git),patch.object(p,"tool_recovery_inputs",return_value=approved):return p.tool_privacy_failure_inputs("a"*40)
        self.assertTrue(check())
        for value in ({"ancestor":False},{"before":False},{"after":False},{"approved":False},{"mode":"120000"}):self.assertFalse(check(**value))


class ToolBuildRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.p = planner
        self.head, self.main = "a"*40, "b"*40
        self.now = dt.datetime(2026,10,14,6,tzinfo=dt.timezone.utc)
        self.repo = "soso-so-27/neko-widget"
        p=planner
        self.required = p.required_jobs_from_scope(p.TOOL_PRESERVATION_SCOPE)
        def run(identifier, sha, workflow="ios-build.yml", event="push", result="success"):
            return {"id":identifier,"run_number":identifier,"head_sha":sha,"head_branch":p.TOOL_BUILD_BRANCH,
                    "workflow_id":335014238 if workflow=="ios-build.yml" else 363932714,
                    "path":".github/workflows/"+workflow,"event":event,"run_attempt":1,"status":"completed","conclusion":result,
                    "updated_at":"2026-10-14T05:30:00Z","repository":{"full_name":self.repo},"head_repository":{"full_name":self.repo}}
        def job(identifier,name,owner,steps):
            return {"id":identifier,"name":name,"run_id":owner["id"],"head_sha":owner["head_sha"],"run_attempt":1,
                    "status":"completed","conclusion":"success","completed_at":"2026-10-14T05:30:00Z",
                    "steps":[{"name":step,"status":"completed","conclusion":"success"} for step in steps]}
        self.source=run(p.TOOL_BUILD_SOURCE_RUN,p.TOOL_BUILD_SOURCE,result="failure")
        self.pr=run(p.TOOL_PR_RUN,p.TOOL_BUILD_SOURCE,"preservation-service.yml","pull_request")
        self.pr["head_commit"]={"id":p.TOOL_BUILD_SOURCE,"tree_id":p.TOOL_PR_TREE}
        # GitHub updates these nested pointers even on an old completed run.
        self.pr["pull_requests"]=[{"number":289,"id":4853108830,"base":{"sha":"34c7ac04f4e8b42c9e51e182d7be1d01164a070c","ref":"main","repo":{"id":1335079243}},
                                  "head":{"sha":p.TOOL_PLAN_FAILURE_SOURCE,"ref":p.TOOL_BUILD_BRANCH,"repo":{"id":1335079243}}}]
        self.candidate=run(1003,self.head)
        self.current=dict(run(1004,self.main),head_branch="main")
        self.failed_plan=run(p.TOOL_PLAN_FAILURE_RUN,p.TOOL_PLAN_FAILURE_SOURCE,result="failure")
        failed_steps=("Set up job","Check out repository","Test CI selection and evidence boundaries","Select checks",
                      "Validate public policy pages","Prepare operator test runtime","Validate private billing operation boundaries",
                      "Validate internal Sandbox release preparation","Post Check out repository","Complete job")
        failed_job=job(p.TOOL_PLAN_FAILURE_JOB,p.PLAN_JOB,self.failed_plan,failed_steps)
        failed_job["conclusion"]="failure"
        for index,step in enumerate(failed_job["steps"]):step["conclusion"]="failure" if index==3 else "skipped" if 4<=index<=7 else "success"
        self.failed_plan_jobs=[failed_job]+[dict(job(identifier,name,self.failed_plan,()),conclusion="skipped")
                                         for identifier,name in p.TOOL_PLAN_FAILURE_PLACEHOLDERS.items()]
        workflow=(Path(__file__).parents[2]/".github/workflows/ios-build.yml").read_text(encoding="utf-8")
        block=workflow.split("  build-without-signing:\n",1)[1].split("  simulator-smoke-test:\n",1)[0]
        excluded={"Verify packaged icons and capture first launch","Upload icon display evidence","Upload build result bundle"}
        self.build_steps=tuple(n for n in re.findall(r"^      - name: (.+)$",block,re.M) if n not in excluded)
        self.source_jobs=[]
        for name,identifier in p.TOOL_BUILD_SOURCE_JOBS.items():
            steps=self.build_steps if name==p.BUILD else ("Select checks",) if name==p.PLAN_JOB else ("Run Simulator smoke test",) if name==p.BOOTSTRAP_SMOKE else ("Run sharing runtime matrix",)
            entry=job(identifier,name,self.source,steps)
            if name==p.BUILD:
                entry["conclusion"]="failure"
                for index,step in enumerate(entry["steps"]):step["conclusion"]="success" if index<2 else "failure" if index==2 else "skipped"
            self.source_jobs.append(entry)
        for identifier in p.TOOL_BUILD_SOURCE_PLACEHOLDERS:
            self.source_jobs.append(dict(job(identifier,p.UNEXPANDED_SHARING_JOB,self.source,()),conclusion="skipped"))
        self.privacy=run(p.TOOL_PRIVACY_FAILED_RUN,p.TOOL_PRIVACY_FAILED_SOURCE,result="failure")
        self.privacy_jobs=[job(p.TOOL_PRIVACY_FAILED_PLAN,p.PLAN_JOB,self.privacy,("Select checks",)),
                           job(p.TOOL_PRIVACY_FAILED_BUILD,p.BUILD,self.privacy,self.build_steps)]
        self.privacy_jobs[1]["conclusion"]="failure"
        for index,step in enumerate(self.privacy_jobs[1]["steps"]):step["conclusion"]="success" if index<2 else "failure" if index==2 else "skipped"
        self.privacy_jobs.extend(dict(job(identifier,name,self.privacy,()),conclusion="skipped") for identifier,name in p.TOOL_PRIVACY_FAILED_PLACEHOLDERS.items())
        steps=("Typecheck the disabled service","Verify local identity, custody and storage boundaries",
               "Verify legacy notice evidence migration with synthetic owners","Bundle the private authority without deployment or provisioning",
               "Bundle the private owner deletion executor without deployment")
        self.pr_jobs=[job(p.TOOL_PR_JOB,p.PRESERVATION_JOB,self.pr,steps)]
        self.candidate_jobs=[job(10031,p.PLAN_JOB,self.candidate,("Select checks",)),job(10032,p.BUILD,self.candidate,self.build_steps)]
        self.current_jobs=[job(10041,p.PLAN_JOB,self.current,("Select checks",))]
        self.candidate_backend={"total_count":0,"workflow_runs":[]}
        self.push_backend={"total_count":0,"workflow_runs":[]}
        self.observations={
            f"repos/{self.repo}/git/commits/{p.TOOL_PR_MERGE}":{"sha":p.TOOL_PR_MERGE,"tree":{"sha":p.TOOL_PR_TREE},"parents":[{"sha":v} for v in (p.TOOL_PR_BASE,p.TOOL_BUILD_SOURCE)]},
            f"repos/{self.repo}/git/commits/{p.TOOL_BUILD_SOURCE}":{"sha":p.TOOL_BUILD_SOURCE,"tree":{"sha":p.TOOL_PR_TREE},"parents":[{"sha":v} for v in ("460a732dc0a563e257e1b929a395d992b53f4b1d",p.TOOL_PR_BASE)]},
            f"repos/{self.repo}/actions/jobs/{p.TOOL_PR_JOB}/logs":f"+{p.TOOL_PR_MERGE}:refs/remotes/pull/289/merge\ncheckout {p.TOOL_PR_MERGE}\n",
            f"repos/{self.repo}/actions/jobs/{p.TOOL_BUILD_SOURCE_JOBS[p.BUILD]}/logs":"reviewed_code_changed\n# tests 2\n# pass 1\n# fail 1\n",
            f"repos/{self.repo}/actions/jobs/{p.TOOL_PLAN_FAILURE_JOB}/logs":'IOS_CI_EVIDENCE_JSON={"stage":"lookup_blocked","reason":"evidence_lookup_failed","error":"CorrectionEvidenceUnavailable"}\nEvidence lookup failed; no Mac checks were authorized.\n',
            f"repos/{self.repo}/actions/jobs/{p.TOOL_PRIVACY_FAILED_BUILD}/logs":"FAIL: test_product_code_never_persists_raw_error_text\nNekoWidget/Views/RestoredToolsView.swift\nFAILED (failures=1)\n"}
        self.digests={identifier:p.tool_log_digest(self.observations[f"repos/{self.repo}/actions/jobs/{identifier}/logs"]) for identifier in p.TOOL_LOG_DIGESTS}

    def record(self,sha):
        p=planner
        record={"schema_version":1,"repository":self.repo,"head_sha":sha,"scope":p.TOOL_PRESERVATION_SCOPE,
                "required_jobs":list(self.required),"required_backend_runs":p.tool_preservation_requirements(p.TOOL_BUILD_SOURCE),
                "evidence_run_id":None,"evidence_sha":None,"test_correction_evidence":None}
        if sha==self.head:
            record["test_correction_evidence"]=self.prove()
            record["required_backend_runs"]=[record["test_correction_evidence"]["backend_evidence"]]
        if sha==p.TOOL_PRIVACY_FAILED_SOURCE:
            native=tuple(name for name in self.required if name!=p.BUILD)
            backend={"run_id":p.TOOL_PR_RUN,"job_id":p.TOOL_PR_JOB,"event":"pull_request","candidate_sha":p.TOOL_BUILD_SOURCE,
                     "checkout_sha":p.TOOL_PR_MERGE,"tree":p.TOOL_PR_TREE,"push_evidence":False}
            record["test_correction_evidence"]={"kind":"tool-preservation-signed-release-build-recovery-v1","candidate_sha":sha,
                "run_id":p.TOOL_BUILD_SOURCE_RUN,"sha":p.TOOL_BUILD_SOURCE,
                "jobs":[{"name":name,"job_id":p.TOOL_BUILD_SOURCE_JOBS[name]} for name in native],
                "failed_build_job_id":p.TOOL_BUILD_SOURCE_JOBS[p.BUILD],"failed_build_log_sha256":p.TOOL_LOG_DIGESTS[p.TOOL_BUILD_SOURCE_JOBS[p.BUILD]],
                "backend_evidence":backend,"failed_plan_evidence":p.tool_plan_failure_record(),"owning_jobs_to_execute":[p.BUILD],"source_build_success":False}
            record["required_backend_runs"]=[backend]
        if sha==self.main:record.update(evidence_run_id=1003,evidence_sha=self.head)
        return record

    def api(self,path):
        p=planner; endpoint=path.split("/actions/",1)[1]
        if endpoint=="workflows/preservation-service.yml":return {"id":363932714,"path":p.PRESERVATION_WORKFLOW,"state":"active"}
        if endpoint=="workflows/ios-build.yml":return {"id":335014238,"path":".github/workflows/ios-build.yml","state":"active"}
        if endpoint.startswith("workflows/preservation-service.yml/runs?"):
            if "head_sha="+self.head in endpoint:return self.candidate_backend
            if "event=push" in endpoint:return self.push_backend
            return {"total_count":1,"workflow_runs":[self.pr]}
        if endpoint.startswith("workflows/ios-build.yml/runs?"):
            if "head_sha="+p.TOOL_PRIVACY_FAILED_SOURCE in endpoint:return {"total_count":1,"workflow_runs":[self.privacy]}
            if "head_sha="+p.TOOL_PLAN_FAILURE_SOURCE in endpoint:return {"total_count":1,"workflow_runs":[self.failed_plan]}
            if "head_sha="+p.TOOL_BUILD_SOURCE in endpoint:return {"total_count":1,"workflow_runs":[self.source]}
            return {"workflow_runs":[self.candidate]}
        owners=[(self.source,self.source_jobs),(self.failed_plan,self.failed_plan_jobs),(self.privacy,self.privacy_jobs),(self.pr,self.pr_jobs),(self.candidate,self.candidate_jobs),(self.current,self.current_jobs)]
        for run,jobs in owners:
            if endpoint==f"runs/{run['id']}":return run
            if endpoint==f"runs/{run['id']}/jobs?filter=latest&per_page=100&page=1":return {"total_count":len(jobs),"jobs":jobs}
            for job in jobs:
                if endpoint==f"jobs/{job['id']}":return job
                if endpoint==f"jobs/{job['id']}/logs":return "IOS_CI_PLAN_JSON="+json.dumps(self.record(run["head_sha"]))
        raise AssertionError(path)

    @contextlib.contextmanager
    def mocks(self):
        with patch.object(planner,"tool_recovery_inputs",return_value=True),patch.object(planner,"tool_build_steps",return_value=self.build_steps), \
                patch.object(planner,"tool_privacy_failure_inputs",return_value=True), \
                patch.object(planner,"git",return_value=""), \
                patch.object(planner,"tool_fixed_observation",side_effect=self.observations.__getitem__), \
                patch.object(planner,"TOOL_LOG_DIGESTS",self.digests):yield

    def prove(self):return planner.tool_recovery_source(self.head,self.repo,self.api,self.now)

    def test_fixed_three_native_and_pr_are_required_before_one_complete_build(self):
        with self.mocks():
            proof=self.prove()
            self.assertFalse(proof["source_build_success"])
            self.assertEqual(len(proof["jobs"]),3)
            self.assertEqual(proof["backend_evidence"]["event"],"pull_request")
            self.assertFalse(proof["backend_evidence"]["push_evidence"])
            self.assertEqual(planner.correction_owning_jobs(planner.TOOL_PRESERVATION_SCOPE,planner.TOOL_BUILD_SOURCE),(planner.BUILD,))
            self.assertTrue(planner.covers_corrected_full_graph(self.candidate,self.main,self.required,self.api,self.now,self.candidate_jobs))
            self.assertFalse(planner.covers_jobs(self.source_jobs,self.required,planner.TOOL_BUILD_SOURCE,self.now))
            all_success=copy.deepcopy(self.source_jobs)
            next(j for j in all_success if j["name"]==planner.BUILD)["conclusion"]="success"
            self.assertFalse(planner.covers_jobs(all_success,self.required,planner.TOOL_BUILD_SOURCE,self.now))

    def test_every_new_build_step_must_execute_no_skips_or_extra_failures(self):
        with self.mocks():
            self.assertEqual(len(self.build_steps),39)
            for step in self.candidate_jobs[1]["steps"]:
                step["conclusion"]="skipped"
                self.assertFalse(planner.covers_corrected_full_graph(self.candidate,self.main,self.required,self.api,self.now,self.candidate_jobs),step["name"])
                step["conclusion"]="success"
            self.candidate_jobs.append(dict(self.candidate_jobs[1],id=99999))
            self.assertFalse(planner.covers_corrected_full_graph(self.candidate,self.main,self.required,self.api,self.now,self.candidate_jobs))

    def test_only_fixed_empty_skipped_source_placeholders_are_excluded(self):
        original=copy.deepcopy(self.source_jobs)
        with self.mocks():
            self.assertEqual(len(self.source_jobs),7)
            for identifier in planner.TOOL_BUILD_SOURCE_PLACEHOLDERS:
                for field,value in (("id",99999),("name","unknown skipped job"),("run_id",1),
                                    ("head_sha","f"*40),("run_attempt",2),("status","queued"),
                                    ("conclusion","success"),("steps",[{"name":"unexpected step"}]),("steps",None)):
                    self.source_jobs=copy.deepcopy(original)
                    next(job for job in self.source_jobs if job["id"]==identifier)[field]=value
                    with self.subTest(identifier=identifier,field=field,value=value),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
                self.source_jobs=[job for job in copy.deepcopy(original) if job["id"]!=identifier]
                with self.subTest(missing=identifier),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
            for extra in (original[-1],dict(original[-1],id=99999)):
                self.source_jobs=copy.deepcopy(original)+[copy.deepcopy(extra)]
                with self.subTest(extra=extra["id"]),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
            self.source_jobs=original
            self.assertEqual(len(self.prove()["jobs"]),3)

    def test_source_incomplete_wrong_attempt_extra_native_failure_and_pr_identity_fail(self):
        with self.mocks():
            for job in self.source_jobs:
                if job["name"]==planner.BUILD:continue
                for field,value in (("status","in_progress"),("conclusion","failure"),("run_attempt",2),("head_sha","f"*40)):
                    old=job[field];job[field]=value
                    with self.subTest(job=job["name"],field=field),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
                    job[field]=old
            for field,value in (("event","workflow_dispatch"),("run_attempt",2),("head_branch","codex/other"),("conclusion","failure"),("head_sha","f"*40)):
                old=self.pr[field];self.pr[field]=value
                with self.subTest(field=field),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
                self.pr[field]=old
            for step in self.pr_jobs[0]["steps"]:
                step["conclusion"]="skipped"
                with self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
                step["conclusion"]="success"
            self.push_backend={"total_count":1,"workflow_runs":[self.pr]}
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()

    def test_pr_full_tree_parents_checkout_log_and_candidate_failure_are_not_optional(self):
        with self.mocks():
            for key,value in self.observations.items():
                old=copy.deepcopy(value)
                self.observations[key] = "changed transcript" if isinstance(value,str) else {**value,"tree":{"sha":"f"*40}}
                with self.subTest(key=key),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
                self.observations[key]=old
            self.pr["pull_requests"][0]["base"]["ref"]="other"
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
            self.pr["pull_requests"][0]["base"]["ref"]="main"
            self.candidate_backend={"total_count":1,"workflow_runs":[dict(self.pr,head_sha=self.head,status="in_progress",conclusion=None)]}
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()

    def test_main_reuse_reaches_the_same_graph_and_no_normal_four_job_shortcut(self):
        env={"GITHUB_EVENT_NAME":"push","GITHUB_REF":"refs/heads/main","GITHUB_SHA":self.main,"GITHUB_REPOSITORY":self.repo,"GITHUB_RUN_ID":"1004"}
        with self.mocks(),patch.object(planner,"git",return_value=self.main),patch.object(planner,"equivalent_inputs",return_value=True):
            self.assertEqual(planner.find_evidence(env,self.required,self.api,self.now),(1003,self.head))
            self.candidate_jobs[1]["steps"][2]["conclusion"]="skipped"
            self.assertIsNone(planner.find_evidence(env,self.required,self.api,self.now))

    def test_current_pr_sha_pointers_do_not_replace_historical_checkout_identity(self):
        with self.mocks():
            for sha in (planner.TOOL_PLAN_FAILURE_SOURCE,"c"*40,None):
                for side in ("head","base"):self.pr["pull_requests"][0][side]["sha"]=sha
                self.assertEqual(self.prove()["backend_evidence"]["checkout_sha"],planner.TOOL_PR_MERGE)
                self.assertTrue(planner.covers_corrected_full_graph(self.candidate,self.main,self.required,self.api,self.now,self.candidate_jobs))
            for side,field,value in (("head","ref","codex/other"),("base","ref","other"),("head","repo",{"id":1}),("base","repo",{"id":1})):
                old=self.pr["pull_requests"][0][side][field];self.pr["pull_requests"][0][side][field]=value
                with self.subTest(side=side,field=field),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
                self.pr["pull_requests"][0][side][field]=old
            for field,value in (("id","f"*40),("tree_id","f"*40)):
                old=self.pr["head_commit"][field];self.pr["head_commit"][field]=value
                with self.subTest(field=field),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
                self.pr["head_commit"][field]=old

    def test_registered_plan_failure_is_not_native_success_or_an_unknown_failure_exemption(self):
        original=copy.deepcopy(self.failed_plan_jobs)
        with self.mocks():
            self.assertEqual(self.prove()["failed_plan_evidence"],planner.tool_plan_failure_record())
            for index,job in enumerate(original):
                for field,value in (("id",1),("run_id",1),("head_sha","f"*40),("run_attempt",2),("status","in_progress"),("name","unknown"),
                                    ("conclusion","success"),("steps",[] if index==0 else [{"name":"native"}])):
                    self.failed_plan_jobs=copy.deepcopy(original);self.failed_plan_jobs[index][field]=value
                    with self.subTest(job=job["id"],field=field),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
                self.failed_plan_jobs=copy.deepcopy(original);self.failed_plan_jobs.pop(index)
                with self.subTest(missing=job["id"]),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
            self.failed_plan_jobs=copy.deepcopy(original)+[copy.deepcopy(original[-1])]
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
            self.failed_plan_jobs=copy.deepcopy(original)
            for step in self.failed_plan_jobs[0]["steps"]:
                old=step["conclusion"];step["conclusion"]="failure" if old!="failure" else "success"
                with self.subTest(step=step["name"]),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
                step["conclusion"]=old
            with patch.object(planner,"git",side_effect=subprocess.CalledProcessError(1,"not ancestor")),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
            with patch.object(planner,"tool_recovery_inputs",side_effect=lambda sha:sha!=planner.TOOL_PLAN_FAILURE_SOURCE),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
            key=f"repos/{self.repo}/actions/jobs/{planner.TOOL_PLAN_FAILURE_JOB}/logs"
            self.observations[key]+="IOS_CI_PLAN_JSON={}\n"
            self.digests[planner.TOOL_PLAN_FAILURE_JOB]=planner.tool_log_digest(self.observations[key])
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()

    def test_merged_pr_metadata_may_be_empty_but_immutable_checkout_is_still_required(self):
        original=copy.deepcopy(self.pr["pull_requests"])
        self.pr["pull_requests"]=[]
        with self.mocks():
            self.assertEqual(self.prove()["backend_evidence"]["checkout_sha"],planner.TOOL_PR_MERGE)
            self.assertTrue(planner.covers_corrected_full_graph(self.candidate,self.main,self.required,self.api,self.now,self.candidate_jobs))
            env={"GITHUB_EVENT_NAME":"push","GITHUB_REF":"refs/heads/main","GITHUB_SHA":self.main,"GITHUB_REPOSITORY":self.repo,"GITHUB_RUN_ID":"1004"}
            with patch.object(planner,"git",return_value=self.main),patch.object(planner,"equivalent_inputs",return_value=True):
                self.assertEqual(planner.find_evidence(env,self.required,self.api,self.now),(1003,self.head))
            for value in (None,{},"",original*2,[dict(original[0],id=1)],[dict(original[0],number=290)]):
                self.pr["pull_requests"]=value
                with self.subTest(value=value),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
            self.pr["pull_requests"]=[]
            for key,value in self.observations.items():
                old=copy.deepcopy(value)
                self.observations[key]="changed transcript" if isinstance(value,str) else {**value,"tree":{"sha":"f"*40}}
                with self.subTest(key=key),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
                self.observations[key]=old

    def test_fixed_privacy_failure_retains_old_proof_and_requires_complete_new_build(self):
        original=copy.deepcopy(self.privacy_jobs)
        with self.mocks():
            self.assertEqual(self.prove()["failed_fixture_build_evidence"],planner.tool_privacy_failure_record())
            self.assertFalse(self.prove()["failed_fixture_build_evidence"]["failure_screen_rendering_verified"])
            for index,job in enumerate(original):
                for field,value in (("id",1),("run_id",1),("head_sha","f"*40),("run_attempt",2),("status","queued"),("name","unknown"),("conclusion","cancelled")):
                    self.privacy_jobs=copy.deepcopy(original);self.privacy_jobs[index][field]=value
                    with self.subTest(job=job["id"],field=field),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
                self.privacy_jobs=copy.deepcopy(original);self.privacy_jobs.pop(index)
                with self.subTest(missing=job["id"]),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
            self.privacy_jobs=copy.deepcopy(original)+[copy.deepcopy(original[-1])]
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
            self.privacy_jobs=copy.deepcopy(original)
            for step in self.privacy_jobs[1]["steps"]:
                old=step["conclusion"];step["conclusion"]="success" if old!="success" else "failure"
                with self.subTest(step=step["name"]),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
                step["conclusion"]=old
            self.privacy_jobs[-1]["steps"]=[{"name":"native execution"}]
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
            self.privacy_jobs=copy.deepcopy(original)
            with patch.object(planner,"tool_privacy_failure_inputs",return_value=False),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()
            old_record=self.record
            def wrong_record(sha):
                record=old_record(sha)
                if sha==planner.TOOL_PRIVACY_FAILED_SOURCE:record["test_correction_evidence"]["source_build_success"]=True
                return record
            with patch.object(self,"record",side_effect=wrong_record),self.assertRaises(planner.CorrectionEvidenceUnavailable):self.prove()


class ToolBackendWaitTests(unittest.TestCase):
    def setUp(self):
        self.fixture=ToolBuildRecoveryTests();self.fixture.setUp()
        f=self.fixture;p=planner
        self.run=copy.deepcopy(f.pr)
        self.run.update(id=2001,head_sha=f.head,status="in_progress",conclusion=None,
                        updated_at=(dt.datetime.now(dt.timezone.utc)-dt.timedelta(seconds=1)).isoformat())
        self.run["head_commit"]={"id":f.head,"tree_id":"c"*40}
        self.run["pull_requests"][0]["head"]["sha"]=f.head
        self.run["pull_requests"][0]["base"]["sha"]="d"*40
        self.seconds=0
        self.calls=[]

    def wait(self,responses,latency=0):
        def api(path,*,timeout):
            self.calls.append(timeout)
            self.assertLessEqual(timeout,120-self.seconds)
            self.assertLessEqual(timeout,15)
            self.seconds+=latency
            response=responses.pop(0) if len(responses)>1 else responses[0]
            return copy.deepcopy(response)
        def sleep(seconds):self.seconds+=seconds
        def git(*args):return "c"*40 if args[0]=="rev-parse" else "d"*40
        with patch.object(planner,"tool_recovery_inputs",return_value=True),patch.object(planner,"git",side_effect=git), \
                patch.object(planner.time,"monotonic",side_effect=lambda:self.seconds),patch.object(planner.time,"sleep",side_effect=sleep):
            return planner.tool_wait_candidate_backend(self.fixture.head,self.fixture.repo,api)

    def index(self,run=None):return {"total_count":1,"workflow_runs":[self.run if run is None else run]}

    def test_only_same_candidate_active_can_wait_and_success_is_rechecked_by_common_proof(self):
        done=dict(self.run,status="completed",conclusion="success")
        result=self.wait([self.index(),self.index(done)],latency=3)
        self.assertEqual(result["seconds"],16)
        self.assertEqual(result["run_ids"],[2001])
        self.assertFalse(result["backend_success_evidence"])
        self.assertEqual(result["maximum_seconds"],120)
        f=self.fixture
        f.candidate_backend=self.index()
        with f.mocks(),self.assertRaises(planner.CorrectionEvidenceUnavailable):f.prove()

    def test_api_latency_timeout_and_late_success_are_inside_monotonic_deadline(self):
        with self.assertRaises(ValueError):self.wait([self.index()],latency=4)
        self.assertLessEqual(self.seconds,120)
        self.assertLess(self.calls[-1],15)
        self.seconds=0;self.calls=[]
        done=dict(self.run,status="completed",conclusion="success")
        with self.assertRaises(ValueError):self.wait([self.index(done)],latency=121)
        self.assertEqual(len(self.calls),1)

    def test_failure_unknown_identity_stale_or_incomplete_stops_without_sleep(self):
        for field,value in (("head_sha","f"*40),("head_branch","codex/other"),("workflow_id",9),
                            ("event","workflow_dispatch"),("run_attempt",2),("status","unknown"),
                            ("updated_at","2020-01-01T00:00:00Z")):
            self.seconds=0;self.calls=[]
            bad=dict(self.run,**{field:value})
            with self.subTest(field=field),self.assertRaises(ValueError):self.wait([self.index(bad)])
            self.assertEqual(self.seconds,0)
        for conclusion in ("failure","cancelled","skipped"):
            with self.assertRaises(ValueError):self.wait([self.index(dict(self.run,status="completed",conclusion=conclusion))])
        for index in ({"total_count":2,"workflow_runs":[self.run]}, {"total_count":2,"workflow_runs":[self.run,self.run]}):
            with self.assertRaises(ValueError):self.wait([index])
        bad=copy.deepcopy(self.run);bad["pull_requests"][0]["number"]=290
        with self.assertRaises(ValueError):self.wait([self.index(bad)])

    def test_observed_active_run_cannot_disappear_or_be_replaced_by_another_success(self):
        done=dict(self.run,status="completed",conclusion="success")
        for later in ({"total_count":0,"workflow_runs":[]},self.index(dict(done,id=2002))):
            self.seconds=0;self.calls=[]
            with self.assertRaises(ValueError):self.wait([self.index(),later])
        self.seconds=0;self.calls=[]
        pair={"total_count":2,"workflow_runs":[self.run,dict(self.run,id=2002)]}
        with self.assertRaises(ValueError):self.wait([pair,self.index(done)])


class ToolPreservationScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def project(self):
        before = ("A00000000000000000000021 /* Sources */ = {\n isa = PBXSourcesBuildPhase;\n files = (\n OLD_APP,\n );\n};\n"
                  "A00000000000000000000025 /* Sources */ = {\n isa = PBXSourcesBuildPhase;\n files = (\n OLD_WIDGET,\n );\n};\n"
                  "Services = {\n children = (\n );\n};\nViews = {\n children = (\n );\n};\n")
        definitions, entries, refs = [], [], []
        for n, name in ((1, "ToolPreservation.swift"), (3, "RestoredToolsView.swift")):
            build, file = f"C0261014000000000000000{n}", f"C0261014000000000000000{n+1}"
            definitions += [f"{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file} /* {name} */; }};",
                            f'{file} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};']
            entries.append(f"{build} /* {name} in Sources */,\n")
            refs.append(f"{file} /* {name} */,\n")
        after = "\n".join(definitions) + "\n" + before.replace(" OLD_APP,\n", "".join(entries) + " OLD_APP,\n")
        after = after.replace("Services = {\n children = (\n", "Services = {\n children = (\n" + refs[0])
        after = after.replace("Views = {\n children = (\n", "Views = {\n children = (\n" + refs[1])
        return before, after

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644", before, after,
                       "A" if before == "0" * 40 else "M"] for path, (before, after) in planner.TOOL_PRESERVATION_BLOBS.items()}

    def select(self, rows=None, raw=None, entries=None, registration=True, project=None, tests=None, ancestor=True, manifests=None, recovery=False):
        rows = self.rows() if rows is None else rows
        before, after = self.project() if project is None else project
        source = "final class SoloMemoriesUITests: XCTestCase {\n" + "\n".join(
            "    func " + test.rsplit("/", 1)[1] + "() {}" for test in planner.TOOL_PRESERVATION_TESTS) + "\n}\n"
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor: raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "rev-parse": return self.head
            if args[0] == "diff": return raw if raw is not None else "".join(" ".join(row)+"\0"+path+"\0" for path,row in rows.items())
            if args[0] == "show":
                value = args[1]
                if value.startswith("refs/remotes/origin/main:"): return 'TOOL_PRESERVATION_SCOPE = "reviewed-tool-preservation-ui-v1"' if registration else "unapproved"
                if value.endswith(planner.TOOL_PRESERVATION_PROJECT): return before if value.startswith(self.base+":") else after
                if value.endswith(planner.MEMORY_TEST_PATH): return source if tests is None else tests
                raise AssertionError(args)
            if args[0] == "ls-tree":
                if args[1:3] == ("-r", "-z"):
                    return (manifests or {}).get(args[3], f"100644 blob {'f'*40}\tREADME.md\0")
                ref,path=args[1],args[3]
                if (ref,path) in (entries or {}): return entries[(ref,path)]
                if recovery and path=="NekoWidget/ci/release-testflight.py": return f"100644 blob {planner.TOOL_RESTORED_RELEASE}\t{path}"
                if recovery and path==planner.TOOL_PRIVACY_PATH:return f"100644 blob {rows[path][3]}\t{path}" if path in rows else ""
                if path in planner.TOOL_RECOVERY_CONTROLS: return f"100644 blob {'e'*40}\t{path}"
                if path in planner.TOOL_PRESERVATION_IMMUTABLE: return f"100644 blob {planner.TOOL_PRESERVATION_IMMUTABLE[path]}\t{path}"
                if path in planner.TOOL_PRESERVATION_IMMUTABLE_TREES: return f"040000 tree {planner.TOOL_PRESERVATION_IMMUTABLE_TREES[path]}\t{path}"
                if path == "NekoWidget/PreservationService": return f"040000 tree {planner.TOOL_PRESERVATION_SERVICE_TREES[0 if ref==self.base else 1]}\t{path}"
                raise AssertionError(args)
            raise AssertionError(args)
        manifest = f"100644 blob {'f'*40}\tREADME.md\0"
        with patch.object(planner,"git",side_effect=git), patch.object(planner,"TOOL_PRESERVATION_IMMUTABLE_TREE_SHA256",planner.hashlib.sha256(manifest.encode()).hexdigest()), \
                patch.object(planner,"tool_recovery_inputs",return_value=recovery):
            return planner.runtime_scope(list(rows), {}, {"GITHUB_SHA":self.head,"GITHUB_EVENT_NAME":"push","GITHUB_REF":"refs/heads/codex/tools"})

    def test_exact_inputs_require_four_native_jobs_and_one_real_preservation_backend(self):
        selected=planner.TOOL_PRESERVATION_SCOPE
        self.assertEqual(self.select(),selected)
        self.assertEqual(len(planner.TOOL_PRESERVATION_BLOBS),19)
        self.assertEqual(len(planner.TOOL_PRESERVATION_ADDITIONS),4)
        self.assertEqual(planner.required_jobs(list(self.rows()),selected),
                         (planner.BUILD,planner.BOOTSTRAP_SMOKE)+scope.sharing_jobs(selected))
        self.assertEqual(scope.lanes(selected),("runtime","app-ui"))
        self.assertEqual(scope.lane_tests(selected,"app-ui"),planner.TOOL_PRESERVATION_TESTS)
        self.assertEqual(len(set(planner.TOOL_PRESERVATION_TESTS)),8)
        self.assertEqual(planner.tool_preservation_requirements(self.head),[
            {"workflow":planner.PRESERVATION_WORKFLOW,"job":planner.PRESERVATION_JOB,"head_sha":self.head,"success_required":True}])

    def test_recovery_binds_the_new_view_as_an_exact_addition_from_main(self):
        rows=self.rows();rows[planner.TOOL_PRIVACY_PATH][3]=planner.TOOL_PRIVACY_PAIR[1]
        self.assertEqual(self.select(rows,recovery=True),planner.TOOL_PRESERVATION_SCOPE)
        for index,value in ((0,":100644"),(1,"100755"),(2,"c"*40),(3,"d"*40),(4,"M")):
            changed=copy.deepcopy(rows);changed[planner.TOOL_PRIVACY_PATH][index]=value
            self.assertEqual(self.select(changed,recovery=True),scope.FULL_SCOPE)
        for path in rows:
            changed=copy.deepcopy(rows);changed.pop(path)
            self.assertEqual(self.select(changed,recovery=True),scope.FULL_SCOPE)
        self.assertEqual(self.select(rows|{"NekoWidget/Shared/unknown.swift":[":000000","100644","0"*40,"d"*40,"A"]},recovery=True),scope.FULL_SCOPE)

    def test_partial_unknown_blobs_modes_handoffs_and_mixed_controls_fail_closed(self):
        rows=self.rows()
        for path in rows:
            self.assertEqual(self.select({p:r for p,r in rows.items() if p!=path}),scope.FULL_SCOPE)
            for index,value in ((0,":100755"),(1,"120000"),(2,"c"*40),(3,"d"*40),(4,"D")):
                changed=copy.deepcopy(rows);changed[path][index]=value
                self.assertEqual(self.select(changed),scope.FULL_SCOPE)
        for path in ("NekoWidget/Shared/unknown.swift","NekoWidget/NekoWidgetWidget/unknown.swift",
                     "NekoWidget/PreservationService/package-lock.json","NekoWidget/ci/ios_ci_scope.py",
                     "handoffs/unknown.json",planner.PRESERVATION_WORKFLOW):
            self.assertEqual(self.select(rows|{path:[":100644","100644","c"*40,"d"*40,"M"]}),scope.FULL_SCOPE)
        for mode,status,before in (("100644","A","0"*40),("100644","M","c"*40)):
            self.assertEqual(self.select(rows|{"handoffs/normal.md":[":000000" if status=="A" else ":100644",mode,before,"d"*40,status]}),planner.TOOL_PRESERVATION_SCOPE)
        self.assertEqual(self.select(rows|{"handoffs/unsafe.md":[":100644","100755","c"*40,"d"*40,"M"]}),scope.FULL_SCOPE)
        raw="".join(" ".join(r)+"\0"+p+"\0" for p,r in rows.items())
        for invalid in ("",raw+raw,raw.rsplit("\0",2)[0]): self.assertEqual(self.select(raw=invalid),scope.FULL_SCOPE)

    def test_project_only_adds_two_app_sources_and_preserves_widget_phase(self):
        before,after=self.project()
        self.assertTrue(planner.tool_preservation_project_only(before,after))
        moved=after.replace("C02610140000000000000001 /* ToolPreservation.swift in Sources */,\n", "").replace(
            " OLD_WIDGET,\n", "C02610140000000000000001 /* ToolPreservation.swift in Sources */,\n OLD_WIDGET,\n")
        for invalid in (after+"OTHER_SETTING=YES;\n",moved,after.replace("sourcecode.swift","text",1)):
            self.assertFalse(planner.tool_preservation_project_only(before,invalid))
            self.assertEqual(self.select(project=(before,invalid)),scope.FULL_SCOPE)

    def test_immutable_inputs_registration_selector_and_required_method_are_enforced(self):
        self.assertEqual(self.select(registration=False),scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False),scope.FULL_SCOPE)
        self.assertEqual(self.select(tests="final class SoloMemoriesUITests: XCTestCase {}"),scope.FULL_SCOPE)
        for path in (*planner.TOOL_PRESERVATION_IMMUTABLE,*planner.TOOL_PRESERVATION_IMMUTABLE_TREES,
                     "NekoWidget/PreservationService",*planner.TOOL_PRESERVATION_CONTROLS):
            for ref in (self.base,self.head):
                self.assertEqual(self.select(entries={(ref,path):""}),scope.FULL_SCOPE)

    def test_every_other_tracked_input_is_frozen_in_both_parent_trees(self):
        row = f"100644 blob {'f'*40}\tREADME.md\0"
        for ref in (self.base, self.head):
            for invalid in ("", row + row, row.replace("100644", "100755"), row.replace("f"*40, "d"*40),
                            row + f"100644 blob {'f'*40}\tNekoWidget/Config.xcconfig\0", "malformed\0"):
                self.assertEqual(self.select(manifests={ref:invalid}), scope.FULL_SCOPE)

    def test_native_plan_declares_backend_at_actual_tested_sha_without_claiming_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/"event").write_text("{}")
            env={"GITHUB_EVENT_NAME":"push","GITHUB_REF":"refs/heads/"+planner.TOOL_BUILD_BRANCH,"GITHUB_SHA":self.head,
                 "GITHUB_REPOSITORY":"owner/repo","GITHUB_RUN_ID":"7","GITHUB_EVENT_PATH":str(root/"event"),
                 "GITHUB_OUTPUT":str(root/"output"),"GITHUB_STEP_SUMMARY":str(root/"summary")}
            output=io.StringIO()
            proof={"sha":planner.TOOL_BUILD_SOURCE,"run_id":planner.TOOL_BUILD_SOURCE_RUN,"jobs":[],"backend_evidence":{"event":"pull_request","candidate_sha":planner.TOOL_BUILD_SOURCE}}
            wait={"seconds":10,"maximum_seconds":120,"run_ids":[99],"backend_success_evidence":False}
            with patch.dict(os.environ,env),contextlib.redirect_stdout(output),patch.object(planner,"changed_paths",return_value=list(self.rows())),patch.object(planner,"runtime_scope",return_value=planner.TOOL_PRESERVATION_SCOPE),patch.object(planner,"find_evidence",return_value=None),patch.object(planner,"find_test_correction_evidence",return_value=proof),patch.object(planner,"tool_wait_candidate_backend",return_value=wait):
                planner.main()
            record=json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=",1)[1].splitlines()[0])
            self.assertEqual(record["required_backend_runs"],[proof["backend_evidence"]])
            self.assertEqual(len(record["required_jobs"]),4)
            self.assertIsNone(record["evidence_run_id"])
            self.assertEqual(record["backend_wait"],wait)
            outputs=(root/"output").read_text()
            self.assertIn("build=true",outputs)
            self.assertIn("smoke=false",outputs)
            self.assertIn("sharing=false",outputs)
            self.assertIn("app_ui=false",outputs)


class PreservationPublicRetentionScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.PRESERVATION_PUBLIC_RETENTION_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.PRESERVATION_PUBLIC_RETENTION_IMMUTABLE[path]}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return 'PRESERVATION_PUBLIC_RETENTION_SCOPE = "preservation-public-retention-v1"'
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/public-retention"})

    def test_exact_two_paths_require_the_existing_backend_job_without_native_evidence(self):
        self.assertEqual(self.select(), planner.PRESERVATION_PUBLIC_RETENTION_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.PRESERVATION_PUBLIC_RETENTION_SCOPE),
                         (planner.PRESERVATION_JOB,))
        self.assertNotIn(planner.PRESERVATION_PUBLIC_RETENTION_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.PRESERVATION_PUBLIC_RETENTION_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.preservation_public_retention_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/public-retention.md",
                        planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_PUBLIC_RETENTION_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_PUBLIC_RETENTION_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("0" * 40, "d" * 40), ("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c", "d" * 40)):
            with patch.object(planner, "PRESERVATION_PUBLIC_RETENTION_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/public-retention.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.PRESERVATION_PUBLIC_RETENTION_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_PUBLIC_RETENTION_SCOPE),
                             (planner.PRESERVATION_JOB,))
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.PRESERVATION_PUBLIC_RETENTION_IMMUTABLE.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_PUBLIC_RETENTION_IMMUTABLE", {planner.PRESERVATION_WORKFLOW: "0" * 40}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/public-retention", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_PUBLIC_RETENTION_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB])
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
                     "head_sha": self.head, "success_required": True}])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("does not certify that job's success", summary)


    def test_unapproved_registration_and_mixed_control_cannot_self_select(self):
        registration = 'PRESERVATION_PUBLIC_RETENTION_SCOPE = "preservation-public-retention-v1"'
        original = planner.git
        # The scope itself checks current main registration before raw inputs.
        for text in ('', 'unapproved', registration + '\n' + registration):
            with patch.object(planner, 'git', return_value=text):
                self.assertFalse(planner.preservation_public_retention_backend_only(list(self.rows()), self.base, self.head))
        for path in ('NekoWidget/ci/plan-ios-ci.py', 'NekoWidget/ci/preflight-ci.py', 'NekoWidget/ci/test-plan-ios-ci.py'):
            self.assertEqual(self.select(self.rows() | {path: [':100644','100644','c'*40,'d'*40,'M']}), scope.FULL_SCOPE)


class PreservationToolTrialRepairScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40
    def setUp(self):
        self.registered_closure = planner.PRESERVATION_TOOL_TRIAL_REPAIR_CLOSURE_SHA256
        self.common = f"100644 blob {'f' * 40}\tNekoWidget/Shared/unchanged.swift"
        digest = hashlib.sha256((self.common + "\0").encode()).hexdigest()
        binding = patch.object(planner, "PRESERVATION_TOOL_TRIAL_REPAIR_CLOSURE_SHA256", digest)
        binding.start(); self.addCleanup(binding.stop)
    def rows(self):
        return {p: [":000000" if before == "0" * 40 else ":100644", "100644", before, after,
                    "A" if before == "0" * 40 else "M"]
                for p, (before, after) in planner.PRESERVATION_TOOL_TRIAL_REPAIR_BLOBS.items()}
    def select(self, rows=None, *, raw=None, paths=None, override=None, event="push", ancestor=True,
               ref="refs/heads/codex/tool-trial-resume-repair"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if override and args in override: return override[args]
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor: raise subprocess.CalledProcessError(1,args)
                return self.base
            if args[0] == "rev-parse": return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return 'PRESERVATION_TOOL_TRIAL_REPAIR_SCOPE = "preservation-tool-trial-repair-v1"'
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(v)+"\0"+p+"\0" for p,v in rows.items())
            if args[0] == "ls-tree" and "-r" in args: return self.common + "\0"
            if args[0] == "ls-tree":
                ref, p = args[1], args[3]
                if p in planner.PRESERVATION_TOOL_TRIAL_REPAIR_CONTROLS: return f"100644 blob {'e' * 40}\t{p}"
                pair = planner.PRESERVATION_TOOL_TRIAL_REPAIR_BLOBS[p]
                blob = pair[0 if ref == self.base else 1]
                return "" if blob == "0" * 40 else f"100644 blob {blob}\t{p}"
            raise AssertionError(args)
        with patch.object(planner,"git",side_effect=git):
            payload = ({"pull_request": {"base": {"sha": self.base}}}
                       if event == "pull_request" else {"before": self.base})
            return planner.runtime_scope(paths,payload, {"GITHUB_SHA":self.head,"GITHUB_EVENT_NAME":event,
                "GITHUB_REF":ref})
    def test_exact_backend_requires_real_owning_push_and_cannot_be_release_evidence(self):
        selected=planner.PRESERVATION_TOOL_TRIAL_REPAIR_SCOPE
        self.assertEqual(self.select(),selected)
        self.assertEqual(self.select(ref="refs/heads/main"), selected)
        self.assertEqual(self.select(event="pull_request", ref="refs/pull/302/merge"), selected)
        self.assertEqual(planner.required_jobs(list(self.rows()),selected),(planner.PRESERVATION_JOB,))
        self.assertEqual(planner.preservation_tool_trial_repair_requirements(self.head),[{
            "workflow":planner.PRESERVATION_WORKFLOW,"job":planner.PRESERVATION_JOB,
            "head_sha":self.head,"event":"push","success_required":True}])
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(selected)
    def test_partial_unknown_mode_blob_and_duplicate_rejected(self):
        original=self.rows()
        for p, row in original.items():
            self.assertEqual(self.select({k:v for k,v in original.items() if k!=p}),scope.FULL_SCOPE)
            for index,value in [(0,":100755"),(1,"120000"),(2,"c"*40),(3,"d"*40),(4,"D"),(4,"R100")]:
                changed=copy.deepcopy(original);changed[p][index]=value
                self.assertEqual(self.select(changed),scope.FULL_SCOPE,(p,index,value))
        for p in [planner.PRESERVATION_WORKFLOW,planner.JPEG_WORKFLOW,"NekoWidget/Shared/MembershipAccessPolicy.swift",
                  "NekoWidget/PreservationService/package-lock.json",*planner.PRESERVATION_TOOL_TRIAL_REPAIR_CONTROLS]:
            changed=original|{p:[":100644","100644","c"*40,"d"*40,"M"]}
            self.assertEqual(self.select(changed),scope.FULL_SCOPE,p)
        raw="".join(" ".join(v)+"\0"+p+"\0" for p,v in original.items())
        for bad in ["",raw+raw,raw.rsplit("\0",2)[0]]: self.assertEqual(self.select(raw=bad),scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original)+[next(iter(original))]),scope.FULL_SCOPE)
    def test_full_input_closure_and_every_approved_control_must_match(self):
        for ref in [self.base,self.head]:
            self.assertEqual(self.select(override={("ls-tree","-r","-z",ref):self.common.replace("100644","100755")+"\0"}),scope.FULL_SCOPE)
            for p in planner.PRESERVATION_TOOL_TRIAL_REPAIR_CONTROLS:
                for bad in ["",f"100755 blob {'e'*40}\t{p}",f"100644 blob {'c'*40}\t{p}"]:
                    self.assertEqual(self.select(override={("ls-tree",ref,"--",p):bad}),scope.FULL_SCOPE)
        self.assertEqual(self.select(override={("show",f"{self.base}:NekoWidget/ci/plan-ios-ci.py"):""}),scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False),scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"),scope.FULL_SCOPE)
    def test_handoff_only_normal_addition_or_edit_cannot_hide_changed_input(self):
        original=self.rows();p="handoffs/tool-trial-resume-repair.md"
        for row in [[":000000","100644","0"*40,"c"*40,"A"],[":100644","100644","c"*40,"d"*40,"M"]]:
            self.assertEqual(self.select(original|{p:row}),planner.PRESERVATION_TOOL_TRIAL_REPAIR_SCOPE)
        for row in [[":100644","000000","c"*40,"0"*40,"D"],[":100644","120000","c"*40,"d"*40,"M"]]:
            self.assertEqual(self.select(original|{p:row}),scope.FULL_SCOPE)

    def test_release_candidate_notes_remain_part_of_input_closure(self):
        previous=self.common
        note="NekoWidget/ci/release-candidates/2026-10-14-tool-preservation.md"
        self.assertTrue(planner.is_handoff(note))
        self.common=f"100644 blob {'f'*40}\t{note}"
        digest=hashlib.sha256((self.common+"\0").encode()).hexdigest()
        with patch.object(planner,"PRESERVATION_TOOL_TRIAL_REPAIR_CLOSURE_SHA256",digest):
            self.assertEqual(self.select(),planner.PRESERVATION_TOOL_TRIAL_REPAIR_SCOPE)
            self.assertEqual(self.select(override={("ls-tree","-r","-z",self.head):self.common.replace('f'*40,'c'*40)+"\0"}),scope.FULL_SCOPE)
        self.common=previous

    def test_invalid_registration_missing_modified_blob_or_malformed_bindings_fail_closed(self):
        marker = 'PRESERVATION_TOOL_TRIAL_REPAIR_SCOPE = "preservation-tool-trial-repair-v1"'
        for text in ('', marker + '\n' + marker):
            self.assertEqual(self.select(override={("show", f"{self.base}:NekoWidget/ci/plan-ios-ci.py"): text}), scope.FULL_SCOPE)
        for ref in (self.base, self.head):
            for path in self.rows():
                invalid = (f"100644 blob {'c'*40}\t{path}" if ref == self.base else "")
                self.assertEqual(self.select(override={("ls-tree", ref, "--", path): invalid}), scope.FULL_SCOPE)
        original = self.rows()
        for pair in (("0"*40, "d"*40), ("c"*40, "0"*40), ("c"*40, "c"*40), ("c"*40, "d"), ("c"*40,)):
            with patch.object(planner, "PRESERVATION_TOOL_TRIAL_REPAIR_BLOBS", {p: pair for p in original}):
                self.assertEqual(self.select(original), scope.FULL_SCOPE)
        for digest in ("", "f"*63, "g"*64):
            with patch.object(planner, "PRESERVATION_TOOL_TRIAL_REPAIR_CLOSURE_SHA256", digest):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_registered_closure_matches_actual_main_tree(self):
        # This is the real frozen ancestor, available under the plan's full checkout.
        reference = "a39d71a9d8633b98db7309f0ffd7492408e07186"
        raw = subprocess.check_output(["git", "ls-tree", "-r", "-z", reference],
                                      cwd=Path(__file__).resolve().parents[2]).decode()
        rows = [r for r in raw.split("\0") if r]
        frozen = [r for r in rows if not (r.split("\t",1)[1].startswith("handoffs/") and r.split("\t",1)[1].endswith(".md"))
                  and r.split("\t",1)[1] not in planner.PRESERVATION_TOOL_TRIAL_REPAIR_PATHS | planner.PRESERVATION_TOOL_TRIAL_REPAIR_CONTROLS]
        digest = hashlib.sha256(("\0".join(frozen)+"\0").encode()).hexdigest()
        self.assertEqual(len(frozen), 1183)
        self.assertEqual(digest, self.registered_closure)
        self.assertEqual(digest, "3f123afda2b3ecbd4b27d8650c47d59483c8c5079bd81dbc298f5662f0737c9e")
        tree = {( "ls-tree", "-r", "-z", ref): raw for ref in (self.base, self.head)}
        with patch.object(planner, "PRESERVATION_TOOL_TRIAL_REPAIR_CLOSURE_SHA256", digest):
            self.assertEqual(self.select(override=tree), planner.PRESERVATION_TOOL_TRIAL_REPAIR_SCOPE)
            changed = raw.replace(frozen[0].split("\t",1)[0], "100755 blob " + "d"*40, 1)
            self.assertEqual(self.select(override=tree | {("ls-tree", "-r", "-z", self.head): changed}), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_owning_push_without_native_or_backend_success_claim(self):
        for ref in ("refs/heads/codex/tool-trial-resume-repair", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_TOOL_TRIAL_REPAIR_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=",1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[n] for n in ("build", "smoke", "sharing", "app_ui")], ["false"]*4)
                self.assertTrue(all(flags[n] == "[]" for n in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=",1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB])
                self.assertEqual(record["required_backend_runs"], planner.preservation_tool_trial_repair_requirements(self.head))
                self.assertIsNone(record["evidence_run_id"]); self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("does not certify that job's success", summary)


class PreservationToolTrialFingerprintScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40
    def setUp(self):
        self.registered_closure = planner.PRESERVATION_TOOL_TRIAL_FINGERPRINT_CLOSURE_SHA256
        self.common = f"100644 blob {'f' * 40}\tNekoWidget/Shared/unchanged.swift"
        digest = hashlib.sha256((self.common + "\0").encode()).hexdigest()
        binding = patch.object(planner, "PRESERVATION_TOOL_TRIAL_FINGERPRINT_CLOSURE_SHA256", digest)
        binding.start(); self.addCleanup(binding.stop)
    def rows(self):
        return {p: [":000000" if before == "0" * 40 else ":100644", "100644", before, after,
                    "A" if before == "0" * 40 else "M"]
                for p, (before, after) in planner.PRESERVATION_TOOL_TRIAL_FINGERPRINT_BLOBS.items()}
    def select(self, rows=None, *, raw=None, paths=None, override=None, event="push", ancestor=True,
               ref="refs/heads/codex/tool-resume-fingerprint"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if override and args in override: return override[args]
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor: raise subprocess.CalledProcessError(1,args)
                return self.base
            if args[0] == "rev-parse": return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return 'PRESERVATION_TOOL_TRIAL_FINGERPRINT_SCOPE = "preservation-tool-trial-fingerprint-v1"'
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(v)+"\0"+p+"\0" for p,v in rows.items())
            if args[0] == "ls-tree" and "-r" in args: return self.common + "\0"
            if args[0] == "ls-tree":
                ref, p = args[1], args[3]
                if p in planner.PRESERVATION_TOOL_TRIAL_FINGERPRINT_CONTROLS: return f"100644 blob {'e' * 40}\t{p}"
                pair = planner.PRESERVATION_TOOL_TRIAL_FINGERPRINT_BLOBS[p]
                blob = pair[0 if ref == self.base else 1]
                return "" if blob == "0" * 40 else f"100644 blob {blob}\t{p}"
            raise AssertionError(args)
        with patch.object(planner,"git",side_effect=git):
            payload = ({"pull_request": {"base": {"sha": self.base}}}
                       if event == "pull_request" else {"before": self.base})
            return planner.runtime_scope(paths,payload, {"GITHUB_SHA":self.head,"GITHUB_EVENT_NAME":event,
                "GITHUB_REF":ref})
    def test_exact_backend_requires_real_owning_push_and_cannot_be_release_evidence(self):
        selected=planner.PRESERVATION_TOOL_TRIAL_FINGERPRINT_SCOPE
        self.assertEqual(self.select(),selected)
        self.assertEqual(self.select(ref="refs/heads/main"), selected)
        self.assertEqual(self.select(event="pull_request", ref="refs/pull/302/merge"), selected)
        self.assertEqual(planner.required_jobs(list(self.rows()),selected),(planner.PRESERVATION_JOB,))
        self.assertEqual(planner.preservation_tool_trial_fingerprint_requirements(self.head),[{
            "workflow":planner.PRESERVATION_WORKFLOW,"job":planner.PRESERVATION_JOB,
            "head_sha":self.head,"event":"push","success_required":True}])
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(selected)
    def test_partial_unknown_mode_blob_and_duplicate_rejected(self):
        original=self.rows()
        for p, row in original.items():
            self.assertEqual(self.select({k:v for k,v in original.items() if k!=p}),scope.FULL_SCOPE)
            for index,value in [(0,":100755"),(1,"120000"),(2,"c"*40),(3,"d"*40),(4,"D"),(4,"R100")]:
                changed=copy.deepcopy(original);changed[p][index]=value
                self.assertEqual(self.select(changed),scope.FULL_SCOPE,(p,index,value))
        for p in [planner.PRESERVATION_WORKFLOW,planner.JPEG_WORKFLOW,"NekoWidget/Shared/MembershipAccessPolicy.swift",
                  "NekoWidget/PreservationService/package-lock.json",*planner.PRESERVATION_TOOL_TRIAL_FINGERPRINT_CONTROLS]:
            changed=original|{p:[":100644","100644","c"*40,"d"*40,"M"]}
            self.assertEqual(self.select(changed),scope.FULL_SCOPE,p)
        raw="".join(" ".join(v)+"\0"+p+"\0" for p,v in original.items())
        for bad in ["",raw+raw,raw.rsplit("\0",2)[0]]: self.assertEqual(self.select(raw=bad),scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original)+[next(iter(original))]),scope.FULL_SCOPE)
    def test_full_input_closure_and_every_approved_control_must_match(self):
        for ref in [self.base,self.head]:
            self.assertEqual(self.select(override={("ls-tree","-r","-z",ref):self.common.replace("100644","100755")+"\0"}),scope.FULL_SCOPE)
            for p in planner.PRESERVATION_TOOL_TRIAL_FINGERPRINT_CONTROLS:
                for bad in ["",f"100755 blob {'e'*40}\t{p}",f"100644 blob {'c'*40}\t{p}"]:
                    self.assertEqual(self.select(override={("ls-tree",ref,"--",p):bad}),scope.FULL_SCOPE)
        self.assertEqual(self.select(override={("show",f"{self.base}:NekoWidget/ci/plan-ios-ci.py"):""}),scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False),scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"),scope.FULL_SCOPE)
    def test_handoff_only_normal_addition_or_edit_cannot_hide_changed_input(self):
        original=self.rows();p="handoffs/tool-resume-fingerprint.md"
        for row in [[":000000","100644","0"*40,"c"*40,"A"],[":100644","100644","c"*40,"d"*40,"M"]]:
            self.assertEqual(self.select(original|{p:row}),planner.PRESERVATION_TOOL_TRIAL_FINGERPRINT_SCOPE)
        for row in [[":100644","000000","c"*40,"0"*40,"D"],[":100644","120000","c"*40,"d"*40,"M"]]:
            self.assertEqual(self.select(original|{p:row}),scope.FULL_SCOPE)

    def test_release_candidate_notes_remain_part_of_input_closure(self):
        previous=self.common
        note="NekoWidget/ci/release-candidates/2026-10-14-tool-preservation.md"
        self.assertTrue(planner.is_handoff(note))
        self.common=f"100644 blob {'f'*40}\t{note}"
        digest=hashlib.sha256((self.common+"\0").encode()).hexdigest()
        with patch.object(planner,"PRESERVATION_TOOL_TRIAL_FINGERPRINT_CLOSURE_SHA256",digest):
            self.assertEqual(self.select(),planner.PRESERVATION_TOOL_TRIAL_FINGERPRINT_SCOPE)
            self.assertEqual(self.select(override={("ls-tree","-r","-z",self.head):self.common.replace('f'*40,'c'*40)+"\0"}),scope.FULL_SCOPE)
        self.common=previous

    def test_invalid_registration_missing_modified_blob_or_malformed_bindings_fail_closed(self):
        marker = 'PRESERVATION_TOOL_TRIAL_FINGERPRINT_SCOPE = "preservation-tool-trial-fingerprint-v1"'
        for text in ('', marker + '\n' + marker):
            self.assertEqual(self.select(override={("show", f"{self.base}:NekoWidget/ci/plan-ios-ci.py"): text}), scope.FULL_SCOPE)
        for ref in (self.base, self.head):
            for path in self.rows():
                invalid = (f"100644 blob {'c'*40}\t{path}" if ref == self.base else "")
                self.assertEqual(self.select(override={("ls-tree", ref, "--", path): invalid}), scope.FULL_SCOPE)
        original = self.rows()
        for pair in (("0"*40, "d"*40), ("c"*40, "0"*40), ("c"*40, "c"*40), ("c"*40, "d"), ("c"*40,)):
            with patch.object(planner, "PRESERVATION_TOOL_TRIAL_FINGERPRINT_BLOBS", {p: pair for p in original}):
                self.assertEqual(self.select(original), scope.FULL_SCOPE)
        for digest in ("", "f"*63, "g"*64):
            with patch.object(planner, "PRESERVATION_TOOL_TRIAL_FINGERPRINT_CLOSURE_SHA256", digest):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_registered_closure_matches_actual_main_tree(self):
        # This is the real frozen ancestor, available under the plan's full checkout.
        reference = "3c7e21bf2cc21f7fb99e66562240a4610cf2bef4"
        raw = subprocess.check_output(["git", "ls-tree", "-r", "-z", reference],
                                      cwd=Path(__file__).resolve().parents[2]).decode()
        rows = [r for r in raw.split("\0") if r]
        frozen = [r for r in rows if not (r.split("\t",1)[1].startswith("handoffs/") and r.split("\t",1)[1].endswith(".md"))
                  and r.split("\t",1)[1] not in planner.PRESERVATION_TOOL_TRIAL_FINGERPRINT_PATHS | planner.PRESERVATION_TOOL_TRIAL_FINGERPRINT_CONTROLS]
        digest = hashlib.sha256(("\0".join(frozen)+"\0").encode()).hexdigest()
        self.assertEqual(len(frozen), 1185)
        self.assertEqual(digest, self.registered_closure)
        self.assertEqual(digest, "365f35310ba5ffa6e3ce505a0c59bcdc71b4ffe55c30a2392a79edc45f2d0479")
        tree = {( "ls-tree", "-r", "-z", ref): raw for ref in (self.base, self.head)}
        with patch.object(planner, "PRESERVATION_TOOL_TRIAL_FINGERPRINT_CLOSURE_SHA256", digest):
            self.assertEqual(self.select(override=tree), planner.PRESERVATION_TOOL_TRIAL_FINGERPRINT_SCOPE)
            changed = raw.replace(frozen[0].split("\t",1)[0], "100755 blob " + "d"*40, 1)
            self.assertEqual(self.select(override=tree | {("ls-tree", "-r", "-z", self.head): changed}), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_owning_push_without_native_or_backend_success_claim(self):
        for ref in ("refs/heads/codex/tool-resume-fingerprint", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_TOOL_TRIAL_FINGERPRINT_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=",1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[n] for n in ("build", "smoke", "sharing", "app_ui")], ["false"]*4)
                self.assertTrue(all(flags[n] == "[]" for n in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=",1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB])
                self.assertEqual(record["required_backend_runs"], planner.preservation_tool_trial_fingerprint_requirements(self.head))
                self.assertIsNone(record["evidence_run_id"]); self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("does not certify that job's success", summary)


class PreservationStorageUsageScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40
    def setUp(self):
        self.registered_closure = planner.PRESERVATION_STORAGE_USAGE_CLOSURE_SHA256
        self.common = f"100644 blob {'f' * 40}\tNekoWidget/Shared/unchanged.swift"
        digest = hashlib.sha256((self.common + "\0").encode()).hexdigest()
        binding = patch.object(planner, "PRESERVATION_STORAGE_USAGE_CLOSURE_SHA256", digest)
        binding.start(); self.addCleanup(binding.stop)
    def rows(self):
        return {p: [":000000" if before == "0" * 40 else ":100644", "100644", before, after,
                    "A" if before == "0" * 40 else "M"]
                for p, (before, after) in planner.PRESERVATION_STORAGE_USAGE_BLOBS.items()}
    def select(self, rows=None, *, raw=None, paths=None, override=None, event="push", ancestor=True,
               ref="refs/heads/codex/storage-usage-breakdown"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if override and args in override: return override[args]
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor: raise subprocess.CalledProcessError(1,args)
                return self.base
            if args[0] == "rev-parse": return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return 'PRESERVATION_STORAGE_USAGE_SCOPE = "preservation-storage-usage-v1"'
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(v)+"\0"+p+"\0" for p,v in rows.items())
            if args[0] == "ls-tree" and "-r" in args: return self.common + "\0"
            if args[0] == "ls-tree":
                ref, p = args[1], args[3]
                if p in planner.PRESERVATION_STORAGE_USAGE_CONTROLS: return f"100644 blob {'e' * 40}\t{p}"
                pair = planner.PRESERVATION_STORAGE_USAGE_BLOBS[p]
                blob = pair[0 if ref == self.base else 1]
                return "" if blob == "0" * 40 else f"100644 blob {blob}\t{p}"
            raise AssertionError(args)
        with patch.object(planner,"git",side_effect=git):
            payload = ({"pull_request": {"base": {"sha": self.base}}}
                       if event == "pull_request" else {"before": self.base})
            return planner.runtime_scope(paths,payload, {"GITHUB_SHA":self.head,"GITHUB_EVENT_NAME":event,
                "GITHUB_REF":ref})
    def test_exact_backend_requires_real_owning_push_and_cannot_be_release_evidence(self):
        selected=planner.PRESERVATION_STORAGE_USAGE_SCOPE
        self.assertEqual(self.select(),selected)
        self.assertEqual(self.select(ref="refs/heads/main"), selected)
        self.assertEqual(self.select(event="pull_request", ref="refs/pull/302/merge"), selected)
        self.assertEqual(planner.required_jobs(list(self.rows()),selected),(planner.PRESERVATION_JOB,))
        self.assertEqual(planner.preservation_storage_usage_requirements(self.head),[{
            "workflow":planner.PRESERVATION_WORKFLOW,"job":planner.PRESERVATION_JOB,
            "head_sha":self.head,"event":"push","success_required":True}])
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(selected)
    def test_partial_unknown_mode_blob_and_duplicate_rejected(self):
        original=self.rows()
        for p, row in original.items():
            self.assertEqual(self.select({k:v for k,v in original.items() if k!=p}),scope.FULL_SCOPE)
            for index,value in [(0,":100755"),(1,"120000"),(2,"c"*40),(3,"d"*40),(4,"D"),(4,"R100")]:
                changed=copy.deepcopy(original);changed[p][index]=value
                self.assertEqual(self.select(changed),scope.FULL_SCOPE,(p,index,value))
        for p in [planner.PRESERVATION_WORKFLOW,planner.JPEG_WORKFLOW,"NekoWidget/Shared/MembershipAccessPolicy.swift",
                  "NekoWidget/PreservationService/package-lock.json",*planner.PRESERVATION_STORAGE_USAGE_CONTROLS]:
            changed=original|{p:[":100644","100644","c"*40,"d"*40,"M"]}
            self.assertEqual(self.select(changed),scope.FULL_SCOPE,p)
        raw="".join(" ".join(v)+"\0"+p+"\0" for p,v in original.items())
        for bad in ["",raw+raw,raw.rsplit("\0",2)[0]]: self.assertEqual(self.select(raw=bad),scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original)+[next(iter(original))]),scope.FULL_SCOPE)
    def test_full_input_closure_and_every_approved_control_must_match(self):
        for ref in [self.base,self.head]:
            self.assertEqual(self.select(override={("ls-tree","-r","-z",ref):self.common.replace("100644","100755")+"\0"}),scope.FULL_SCOPE)
            for p in planner.PRESERVATION_STORAGE_USAGE_CONTROLS:
                for bad in ["",f"100755 blob {'e'*40}\t{p}",f"100644 blob {'c'*40}\t{p}"]:
                    self.assertEqual(self.select(override={("ls-tree",ref,"--",p):bad}),scope.FULL_SCOPE)
        self.assertEqual(self.select(override={("show",f"{self.base}:NekoWidget/ci/plan-ios-ci.py"):""}),scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False),scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"),scope.FULL_SCOPE)
    def test_handoff_only_normal_addition_or_edit_cannot_hide_changed_input(self):
        original=self.rows();p="handoffs/storage-usage.md"
        for row in [[":000000","100644","0"*40,"c"*40,"A"],[":100644","100644","c"*40,"d"*40,"M"]]:
            self.assertEqual(self.select(original|{p:row}),planner.PRESERVATION_STORAGE_USAGE_SCOPE)
        for row in [[":100644","000000","c"*40,"0"*40,"D"],[":100644","120000","c"*40,"d"*40,"M"]]:
            self.assertEqual(self.select(original|{p:row}),scope.FULL_SCOPE)

    def test_release_candidate_notes_remain_part_of_input_closure(self):
        previous=self.common
        note="NekoWidget/ci/release-candidates/2026-10-14-tool-preservation.md"
        self.assertTrue(planner.is_handoff(note))
        self.common=f"100644 blob {'f'*40}\t{note}"
        digest=hashlib.sha256((self.common+"\0").encode()).hexdigest()
        with patch.object(planner,"PRESERVATION_STORAGE_USAGE_CLOSURE_SHA256",digest):
            self.assertEqual(self.select(),planner.PRESERVATION_STORAGE_USAGE_SCOPE)
            self.assertEqual(self.select(override={("ls-tree","-r","-z",self.head):self.common.replace('f'*40,'c'*40)+"\0"}),scope.FULL_SCOPE)
        self.common=previous

    def test_invalid_registration_and_missing_addition_or_malformed_bindings_fail_closed(self):
        marker = 'PRESERVATION_STORAGE_USAGE_SCOPE = "preservation-storage-usage-v1"'
        for text in ('', marker + '\n' + marker):
            self.assertEqual(self.select(override={("show", f"{self.base}:NekoWidget/ci/plan-ios-ci.py"): text}), scope.FULL_SCOPE)
        for ref in (self.base, self.head):
            for path in self.rows():
                invalid = (f"100644 blob {'c'*40}\t{path}" if ref == self.base else "")
                self.assertEqual(self.select(override={("ls-tree", ref, "--", path): invalid}), scope.FULL_SCOPE)
        original = self.rows()
        for pair in (("c"*40, "d"*40), ("0"*40, "0"*40), ("0"*40, "d"), ("0"*40,)):
            with patch.object(planner, "PRESERVATION_STORAGE_USAGE_BLOBS", {p: pair for p in original}):
                self.assertEqual(self.select(original), scope.FULL_SCOPE)
        for digest in ("", "f"*63, "g"*64):
            with patch.object(planner, "PRESERVATION_STORAGE_USAGE_CLOSURE_SHA256", digest):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_registered_closure_matches_actual_main_tree(self):
        # This is the real frozen ancestor, available under the plan's full checkout.
        reference = "03fdd1996a3644e453343975cb0494af4f588823"
        raw = subprocess.check_output(["git", "ls-tree", "-r", "-z", reference],
                                      cwd=Path(__file__).resolve().parents[2]).decode()
        rows = [r for r in raw.split("\0") if r]
        frozen = [r for r in rows if not (r.split("\t",1)[1].startswith("handoffs/") and r.split("\t",1)[1].endswith(".md"))
                  and r.split("\t",1)[1] not in planner.PRESERVATION_STORAGE_USAGE_PATHS | planner.PRESERVATION_STORAGE_USAGE_CONTROLS]
        digest = hashlib.sha256(("\0".join(frozen)+"\0").encode()).hexdigest()
        self.assertEqual(len(frozen), 1185)
        self.assertEqual(digest, self.registered_closure)
        self.assertEqual(digest, "feb3c24a1f5af747466b105f2630c0ad08b1ee1f8e1b23384e1a98f4e32186b9")
        tree = {( "ls-tree", "-r", "-z", ref): raw for ref in (self.base, self.head)}
        with patch.object(planner, "PRESERVATION_STORAGE_USAGE_CLOSURE_SHA256", digest):
            self.assertEqual(self.select(override=tree), planner.PRESERVATION_STORAGE_USAGE_SCOPE)
            changed = raw.replace(frozen[0].split("\t",1)[0], "100755 blob " + "d"*40, 1)
            self.assertEqual(self.select(override=tree | {("ls-tree", "-r", "-z", self.head): changed}), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_owning_push_without_native_or_backend_success_claim(self):
        for ref in ("refs/heads/codex/storage-usage-breakdown", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_STORAGE_USAGE_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=",1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[n] for n in ("build", "smoke", "sharing", "app_ui")], ["false"]*4)
                self.assertTrue(all(flags[n] == "[]" for n in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=",1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB])
                self.assertEqual(record["required_backend_runs"], planner.preservation_storage_usage_requirements(self.head))
                self.assertIsNone(record["evidence_run_id"]); self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("does not certify that job's success", summary)


class PreservationToolOwnerTrialScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40
    def setUp(self):
        self.common = f"100644 blob {'f' * 40}\tNekoWidget/Shared/unchanged.swift"
        digest = hashlib.sha256((self.common + "\0").encode()).hexdigest()
        binding = patch.object(planner, "PRESERVATION_TOOL_OWNER_TRIAL_CLOSURE_SHA256", digest)
        binding.start(); self.addCleanup(binding.stop)
    def rows(self):
        return {p: [":000000" if before == "0" * 40 else ":100644", "100644", before, after,
                    "A" if before == "0" * 40 else "M"]
                for p, (before, after) in planner.PRESERVATION_TOOL_OWNER_TRIAL_BLOBS.items()}
    def select(self, rows=None, *, raw=None, paths=None, override=None, event="push", ancestor=True):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if override and args in override: return override[args]
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor: raise subprocess.CalledProcessError(1,args)
                return self.base
            if args[0] == "rev-parse": return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return 'PRESERVATION_TOOL_OWNER_TRIAL_SCOPE = "preservation-tool-owner-trial-v1"'
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(v)+"\0"+p+"\0" for p,v in rows.items())
            if args[0] == "ls-tree" and "-r" in args: return self.common + "\0"
            if args[0] == "ls-tree":
                ref, p = args[1], args[3]
                if p in planner.PRESERVATION_TOOL_OWNER_TRIAL_CONTROLS: return f"100644 blob {'e' * 40}\t{p}"
                pair = planner.PRESERVATION_TOOL_OWNER_TRIAL_BLOBS[p]
                blob = pair[0 if ref == self.base else 1]
                return "" if blob == "0" * 40 else f"100644 blob {blob}\t{p}"
            raise AssertionError(args)
        with patch.object(planner,"git",side_effect=git):
            return planner.runtime_scope(paths,{}, {"GITHUB_SHA":self.head,"GITHUB_EVENT_NAME":event,
                "GITHUB_REF":"refs/heads/codex/tool-owner-trial"})
    def test_exact_backend_requires_real_owning_push_and_cannot_be_release_evidence(self):
        selected=planner.PRESERVATION_TOOL_OWNER_TRIAL_SCOPE
        self.assertEqual(self.select(),selected)
        self.assertEqual(planner.required_jobs(list(self.rows()),selected),(planner.PRESERVATION_JOB,))
        self.assertEqual(planner.preservation_tool_owner_trial_requirements(self.head),[{
            "workflow":planner.PRESERVATION_WORKFLOW,"job":planner.PRESERVATION_JOB,
            "head_sha":self.head,"event":"push","success_required":True}])
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(selected)
    def test_partial_unknown_mode_blob_and_duplicate_rejected(self):
        original=self.rows()
        for p, row in original.items():
            self.assertEqual(self.select({k:v for k,v in original.items() if k!=p}),scope.FULL_SCOPE)
            for index,value in [(0,":100755"),(1,"120000"),(2,"c"*40),(3,"d"*40),(4,"D"),(4,"R100")]:
                changed=copy.deepcopy(original);changed[p][index]=value
                self.assertEqual(self.select(changed),scope.FULL_SCOPE,(p,index,value))
        for p in [planner.PRESERVATION_WORKFLOW,planner.JPEG_WORKFLOW,"NekoWidget/Shared/MembershipAccessPolicy.swift",
                  "NekoWidget/PreservationService/package-lock.json",*planner.PRESERVATION_TOOL_OWNER_TRIAL_CONTROLS]:
            changed=original|{p:[":100644","100644","c"*40,"d"*40,"M"]}
            self.assertEqual(self.select(changed),scope.FULL_SCOPE,p)
        raw="".join(" ".join(v)+"\0"+p+"\0" for p,v in original.items())
        for bad in ["",raw+raw,raw.rsplit("\0",2)[0]]: self.assertEqual(self.select(raw=bad),scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original)+[next(iter(original))]),scope.FULL_SCOPE)
    def test_full_input_closure_and_every_approved_control_must_match(self):
        for ref in [self.base,self.head]:
            self.assertEqual(self.select(override={("ls-tree","-r","-z",ref):self.common.replace("100644","100755")+"\0"}),scope.FULL_SCOPE)
            for p in planner.PRESERVATION_TOOL_OWNER_TRIAL_CONTROLS:
                for bad in ["",f"100755 blob {'e'*40}\t{p}",f"100644 blob {'c'*40}\t{p}"]:
                    self.assertEqual(self.select(override={("ls-tree",ref,"--",p):bad}),scope.FULL_SCOPE)
        self.assertEqual(self.select(override={("show",f"{self.base}:NekoWidget/ci/plan-ios-ci.py"):""}),scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False),scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"),scope.FULL_SCOPE)
    def test_handoff_only_normal_addition_or_edit_cannot_hide_changed_input(self):
        original=self.rows();p="handoffs/trial.md"
        for row in [[":000000","100644","0"*40,"c"*40,"A"],[":100644","100644","c"*40,"d"*40,"M"]]:
            self.assertEqual(self.select(original|{p:row}),planner.PRESERVATION_TOOL_OWNER_TRIAL_SCOPE)
        for row in [[":100644","000000","c"*40,"0"*40,"D"],[":100644","120000","c"*40,"d"*40,"M"]]:
            self.assertEqual(self.select(original|{p:row}),scope.FULL_SCOPE)

    def test_release_candidate_notes_remain_part_of_input_closure(self):
        previous=self.common
        note="NekoWidget/ci/release-candidates/2026-10-14-tool-preservation.md"
        self.assertTrue(planner.is_handoff(note))
        self.common=f"100644 blob {'f'*40}\t{note}"
        digest=hashlib.sha256((self.common+"\0").encode()).hexdigest()
        with patch.object(planner,"PRESERVATION_TOOL_OWNER_TRIAL_CLOSURE_SHA256",digest):
            self.assertEqual(self.select(),planner.PRESERVATION_TOOL_OWNER_TRIAL_SCOPE)
            self.assertEqual(self.select(override={("ls-tree","-r","-z",self.head):self.common.replace('f'*40,'c'*40)+"\0"}),scope.FULL_SCOPE)
        self.common=previous

class PreservationAllPutBytesScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.PRESERVATION_ALL_PUT_BYTES_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                if path == "NekoWidget/ci/plan-ios-ci.py":
                    return (workflows or {}).get((revision, path), f"100644 blob {'e' * 40}\t{path}")
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.PRESERVATION_ALL_PUT_BYTES_IMMUTABLE[path]}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return 'PRESERVATION_ALL_PUT_BYTES_SCOPE = "preservation-all-put-bytes-v1"'
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/all-put-bytes"})

    def test_exact_six_paths_require_the_existing_backend_job_without_native_evidence(self):
        self.assertEqual(self.select(), planner.PRESERVATION_ALL_PUT_BYTES_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.PRESERVATION_ALL_PUT_BYTES_SCOPE),
                         (planner.PRESERVATION_JOB,))
        self.assertNotIn(planner.PRESERVATION_ALL_PUT_BYTES_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.PRESERVATION_ALL_PUT_BYTES_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.preservation_all_put_bytes_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/all-put-bytes.md",
                        planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_ALL_PUT_BYTES_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_ALL_PUT_BYTES_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("0" * 40, "d" * 40), ("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c", "d" * 40)):
            with patch.object(planner, "PRESERVATION_ALL_PUT_BYTES_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/all-put-bytes.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.PRESERVATION_ALL_PUT_BYTES_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_ALL_PUT_BYTES_SCOPE),
                             (planner.PRESERVATION_JOB,))
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.PRESERVATION_ALL_PUT_BYTES_IMMUTABLE.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_ALL_PUT_BYTES_IMMUTABLE", {planner.PRESERVATION_WORKFLOW: "0" * 40}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/all-put-bytes", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_ALL_PUT_BYTES_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB])
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
                     "head_sha": self.head, "success_required": True}])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("does not certify that job's success", summary)


    def test_unapproved_registration_and_mixed_control_cannot_self_select(self):
        registration = 'PRESERVATION_ALL_PUT_BYTES_SCOPE = "preservation-all-put-bytes-v1"'
        original = planner.git
        # The scope itself checks current main registration before raw inputs.
        for text in ('', 'unapproved', registration + '\n' + registration):
            with patch.object(planner, 'git', return_value=text):
                self.assertFalse(planner.preservation_all_put_bytes_backend_only(list(self.rows()), self.base, self.head))
        for path in ('NekoWidget/ci/plan-ios-ci.py', 'NekoWidget/ci/preflight-ci.py', 'NekoWidget/ci/test-plan-ios-ci.py'):
            self.assertEqual(self.select(self.rows() | {path: [':100644','100644','c'*40,'d'*40,'M']}), scope.FULL_SCOPE)

    def test_only_migration_and_policy_are_additions_and_controls_must_match_main(self):
        self.assertEqual(planner.PRESERVATION_ALL_PUT_BYTES_ADDITIONS, {
            "NekoWidget/PreservationService/migrations/0034_all_put_bytes.sql",
            "handoffs/2026-10-14-public-policy.json"})
        self.assertEqual({path for path, row in self.rows().items() if row[4] == "A"},
                         planner.PRESERVATION_ALL_PUT_BYTES_ADDITIONS)
        for path in self.rows():
            rows = self.rows()
            fields = rows[path]
            fields[0], fields[2], fields[4] = (":100644", "c" * 40, "M") if fields[4] == "A" else (":000000", "0" * 40, "A")
            self.assertEqual(self.select(rows), scope.FULL_SCOPE)
        selector = "NekoWidget/ci/plan-ios-ci.py"
        for revision in ("refs/remotes/origin/main", self.head):
            for value in ("", f"100755 blob {'e' * 40}\t{selector}", f"100644 blob {'c' * 40}\t{selector}"):
                self.assertEqual(self.select(workflows={(revision, selector): value}), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_ALL_PUT_BYTES_ADDITIONS", frozenset()):
            self.assertEqual(self.select(), scope.FULL_SCOPE)


class PreservationNoticeMessageIdScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.PRESERVATION_NOTICE_MESSAGE_ID_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.PRESERVATION_NOTICE_MESSAGE_ID_IMMUTABLE[path]}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return 'PRESERVATION_NOTICE_MESSAGE_ID_SCOPE = "preservation-notice-message-id-v1"'
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/notice-message-id"})

    def test_exact_four_paths_require_the_existing_backend_job_without_native_evidence(self):
        self.assertEqual(self.select(), planner.PRESERVATION_NOTICE_MESSAGE_ID_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.PRESERVATION_NOTICE_MESSAGE_ID_SCOPE),
                         (planner.PRESERVATION_JOB,))
        self.assertNotIn(planner.PRESERVATION_NOTICE_MESSAGE_ID_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.PRESERVATION_NOTICE_MESSAGE_ID_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.preservation_notice_message_id_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/notice-message-id.md",
                        planner.PRESERVATION_WORKFLOW, planner.JPEG_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_NOTICE_MESSAGE_ID_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        first_path, first_row = next(iter(original.items()))
        duplicate = (" ".join(first_row) + "\0" + first_path + "\0") * len(original)
        for invalid in ("", raw + raw, duplicate, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_NOTICE_MESSAGE_ID_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)
        for pair in (("0" * 40, "d" * 40), ("c" * 40, "0" * 40), ("c" * 40, "c" * 40), ("c", "d" * 40)):
            with patch.object(planner, "PRESERVATION_NOTICE_MESSAGE_ID_BLOBS", {path: pair for path in original}):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/notice-message-id.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.PRESERVATION_NOTICE_MESSAGE_ID_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_NOTICE_MESSAGE_ID_SCOPE),
                             (planner.PRESERVATION_JOB,))
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_workflow_requires_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.PRESERVATION_NOTICE_MESSAGE_ID_IMMUTABLE.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_NOTICE_MESSAGE_ID_IMMUTABLE", {planner.PRESERVATION_WORKFLOW: "0" * 40}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_same_sha_backend_success_and_never_claims_it(self):
        for ref in ("refs/heads/codex/notice-message-id", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_NOTICE_MESSAGE_ID_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB])
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
                     "head_sha": self.head, "success_required": True}])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("does not certify that job's success", summary)


    def test_unapproved_registration_and_mixed_control_cannot_self_select(self):
        registration = 'PRESERVATION_NOTICE_MESSAGE_ID_SCOPE = "preservation-notice-message-id-v1"'
        original = planner.git
        # The scope itself checks current main registration before raw inputs.
        for text in ('', 'unapproved', registration + '\n' + registration):
            with patch.object(planner, 'git', return_value=text):
                self.assertFalse(planner.preservation_notice_message_id_backend_only(list(self.rows()), self.base, self.head))
        for path in ('NekoWidget/ci/plan-ios-ci.py', 'NekoWidget/ci/preflight-ci.py', 'NekoWidget/ci/test-plan-ios-ci.py'):
            self.assertEqual(self.select(self.rows() | {path: [':100644','100644','c'*40,'d'*40,'M']}), scope.FULL_SCOPE)

class PreservationProviderStreamScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.PRESERVATION_PROVIDER_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.PRESERVATION_PROVIDER_WORKFLOWS[path]}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/provider-stream"})

    def test_exact_three_paths_require_both_existing_jobs_without_native_evidence(self):
        self.assertEqual(self.select(), planner.PRESERVATION_PROVIDER_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.PRESERVATION_PROVIDER_SCOPE),
                         (planner.PRESERVATION_JOB, planner.JPEG_JOB))
        self.assertNotIn(planner.PRESERVATION_PROVIDER_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.PRESERVATION_PROVIDER_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.preservation_provider_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/provider.md",
                        *planner.PRESERVATION_PROVIDER_WORKFLOWS, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_PROVIDER_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        for invalid in ("", raw + raw, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_PROVIDER_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/provider.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.PRESERVATION_PROVIDER_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_PROVIDER_SCOPE),
                             (planner.PRESERVATION_JOB, planner.JPEG_JOB))
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_both_workflows_require_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.PRESERVATION_PROVIDER_WORKFLOWS.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_PROVIDER_WORKFLOWS", {planner.PRESERVATION_WORKFLOW: "b" * 40}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_both_same_sha_successes_and_never_claims_them(self):
        for ref in ("refs/heads/codex/provider-stream", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_PROVIDER_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB, planner.JPEG_JOB])
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
                     "head_sha": self.head, "success_required": True},
                    {"workflow": planner.JPEG_WORKFLOW, "job": planner.JPEG_JOB,
                     "head_sha": self.head, "success_required": True}])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                for workflow in planner.PRESERVATION_PROVIDER_WORKFLOWS: self.assertIn(workflow, summary)
                self.assertIn("Both jobs must execute successfully", summary)
                self.assertIn("does not certify their success", summary)


class JPEGBodyTransportScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.JPEG_BODY_TRANSPORT_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                if path == "NekoWidget/PreservationService":
                    return (workflows or {}).get((revision, path), f"040000 tree {planner.JPEG_BODY_TRANSPORT_SERVICE_TREES[0 if revision == self.base else 1]}\t{path}")
                blobs = planner.JPEG_BODY_TRANSPORT_WORKFLOWS[path]
                blob = blobs[0 if revision == self.base else 1] if isinstance(blobs, tuple) else blobs
                return (workflows or {}).get((revision, path), f"100644 blob {blob}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/jpeg-body-transport"})

    def test_exact_four_paths_require_both_existing_jobs_without_native_evidence(self):
        self.assertEqual(self.select(), planner.JPEG_BODY_TRANSPORT_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.JPEG_BODY_TRANSPORT_SCOPE),
                         (planner.PRESERVATION_JOB, planner.JPEG_JOB))
        self.assertNotIn(planner.JPEG_BODY_TRANSPORT_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.JPEG_BODY_TRANSPORT_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.jpeg_body_transport_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/decoder.ts", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/provider.md",
                        planner.PRESERVATION_WORKFLOW, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.JPEG_BODY_TRANSPORT_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        for invalid in ("", raw + raw, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "JPEG_BODY_TRANSPORT_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/provider.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.JPEG_BODY_TRANSPORT_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.JPEG_BODY_TRANSPORT_SCOPE),
                             (planner.PRESERVATION_JOB, planner.JPEG_JOB))
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_both_workflows_require_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blobs in planner.JPEG_BODY_TRANSPORT_WORKFLOWS.items():
            for revision in (self.base, self.head):
                blob = blobs[0 if revision == self.base else 1] if isinstance(blobs, tuple) else blobs
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        with patch.object(planner, "JPEG_BODY_TRANSPORT_WORKFLOWS", {planner.PRESERVATION_WORKFLOW: "b" * 40}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_preservation_tree_closure_is_exact_at_both_ends(self):
        path = "NekoWidget/PreservationService"
        for revision in (self.base, self.head):
            for invalid in ("", f"040000 tree {'c' * 40}\t{path}",
                            f"100644 blob {'c' * 40}\t{path}"):
                self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        for invalid in ((), ("0" * 40, "0" * 40), ("c" * 40,)):
            with patch.object(planner, "JPEG_BODY_TRANSPORT_SERVICE_TREES", invalid):
                self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_both_same_sha_successes_and_never_claims_them(self):
        for ref in ("refs/heads/codex/jpeg-body-transport", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.JPEG_BODY_TRANSPORT_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB, planner.JPEG_JOB])
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
                     "head_sha": self.head, "success_required": True},
                    {"workflow": planner.JPEG_WORKFLOW, "job": planner.JPEG_JOB,
                     "head_sha": self.head, "success_required": True}])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.JPEG_WORKFLOW, summary)
                self.assertIn("Both jobs must execute successfully", summary)
                self.assertIn("does not certify their success", summary)


class PreservationPhotoStartupScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def test_actual_jpeg_push_filter_excludes_caller_only_scope(self):
        workflow = (Path(__file__).resolve().parents[2] / planner.JPEG_WORKFLOW).read_text()
        push = workflow.split("  push:", 1)[1].split("  pull_request:", 1)[0]
        paths = [line.strip()[3:-1] for line in push.splitlines()
                 if line.strip().startswith('- "') and 'diagnostic/' not in line]
        self.assertEqual(paths, ["NekoWidget/PreservationImageValidator/**", planner.JPEG_WORKFLOW])
        self.assertTrue(all(not path.startswith("NekoWidget/PreservationImageValidator/")
                            and path != planner.JPEG_WORKFLOW for path in self.rows()))
        self.assertEqual(planner.PRESERVATION_PHOTO_STARTUP_JOBS,
                         {planner.PRESERVATION_WORKFLOW: planner.PRESERVATION_JOB})

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.PRESERVATION_PHOTO_STARTUP_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflows=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "ls-tree":
                revision, path = args[1], args[3]
                return (workflows or {}).get((revision, path),
                    f"100644 blob {planner.PRESERVATION_PHOTO_STARTUP_WORKFLOWS[path]}\t{path}")
            if args[0] == "rev-parse":
                return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return "unreviewed other profile"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/photo-startup"})

    def test_exact_two_paths_require_both_existing_jobs_without_native_evidence(self):
        self.assertEqual(self.select(), planner.PRESERVATION_PHOTO_STARTUP_SCOPE)
        self.assertEqual(planner.required_jobs(list(self.rows()), planner.PRESERVATION_PHOTO_STARTUP_SCOPE),
                         (planner.PRESERVATION_JOB,))
        self.assertNotIn(planner.PRESERVATION_PHOTO_STARTUP_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.PRESERVATION_PHOTO_STARTUP_SCOPE)
        for absent in (None, []):
            self.assertFalse(planner.preservation_photo_startup_paths_only(absent))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")
        self.assertEqual(planner.PRESERVATION_UPLOAD_SCOPE, "preservation-upload-memory-v1")

    def test_partial_unknown_modes_and_unreviewed_blobs_cannot_borrow_the_scope(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({p: row for p, row in original.items() if p != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/package.json",
                        "NekoWidget/PreservationImageValidator/src/provider.ts",
                        "NekoWidget/PreservationImageValidator/src/container-worker.mjs",
                        "NekoWidget/PreservationImageValidator/Dockerfile",
                        "NekoWidget/PreservationImageValidator/package-lock.json",
                        "NekoWidget/PreservationImageValidator/test/test-adapter.mjs", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/Shared/MembershipAccessPolicy.swift", "docs/provider.md",
                        *planner.PRESERVATION_PHOTO_STARTUP_WORKFLOWS, ".github/workflows/ios-build.yml",
                        *planner.PRESERVATION_COMPANION_PATHS):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_PHOTO_STARTUP_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        for invalid in ("", raw + raw, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_PHOTO_STARTUP_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_normal_handoff_additions_and_edits_are_allowed_but_unsafe_modes_are_not(self):
        original = self.rows()
        path = "handoffs/provider.md"
        for fields in ([":000000", "100644", "0" * 40, "c" * 40, "A"],
                       [":100644", "100644", "c" * 40, "d" * 40, "M"]):
            changed = original | {path: fields}
            self.assertEqual(self.select(changed), planner.PRESERVATION_PHOTO_STARTUP_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_PHOTO_STARTUP_SCOPE),
                             (planner.PRESERVATION_JOB,))
        for fields in ([":000000", "120000", "0" * 40, "c" * 40, "A"],
                       [":100644", "100755", "c" * 40, "d" * 40, "M"],
                       [":100644", "000000", "c" * 40, "0" * 40, "D"],
                       [":120000", "100644", "c" * 40, "d" * 40, "T"]):
            self.assertEqual(self.select(original | {path: fields}), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [path, path]), scope.FULL_SCOPE)

    def test_both_workflows_require_exact_blob_and_regular_mode_at_base_and_head(self):
        for path, blob in planner.PRESERVATION_PHOTO_STARTUP_WORKFLOWS.items():
            for revision in (self.base, self.head):
                for invalid in ("", f"100755 blob {blob}\t{path}", f"120000 blob {blob}\t{path}",
                                f"100644 blob {'c' * 40}\t{path}", f"100644 blob {blob}\tother.yml"):
                    self.assertEqual(self.select(workflows={(revision, path): invalid}), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_PHOTO_STARTUP_WORKFLOWS", {planner.PRESERVATION_WORKFLOW: "b" * 40}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_plan_declares_both_same_sha_successes_and_never_claims_them(self):
        for ref in ("refs/heads/codex/photo-startup", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_PHOTO_STARTUP_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB])
                self.assertEqual(record["required_backend_runs"], [
                    {"workflow": planner.PRESERVATION_WORKFLOW, "job": planner.PRESERVATION_JOB,
                     "head_sha": self.head, "success_required": True}])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("The owning Preservation push job must execute successfully", summary)
                self.assertIn("does not certify that job's success", summary)


class PreservationUploadMemoryScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def rows(self):
        return {path: [":000000" if before == "0" * 40 else ":100644", "100644",
                       before, after, "A" if before == "0" * 40 else "M"]
                for path, (before, after) in planner.PRESERVATION_UPLOAD_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, ancestor=True, workflow=None, event="push"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor:
                    raise subprocess.CalledProcessError(1, args)
                return self.base
            if args[0] == "diff":
                return raw if raw is not None else "".join(" ".join(fields) + "\0" + path + "\0"
                                                         for path, fields in rows.items())
            if args[0] == "rev-parse":
                if args[1] == "HEAD": return self.head
                if args[1].endswith(":" + planner.PRESERVATION_WORKFLOW):
                    return (workflow or {}).get(args[1].split(":", 1)[0], planner.PRESERVATION_UPLOAD_WORKFLOW_BLOB)
                return "0" * 40  # Never impersonate v26's frozen service tree.
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(paths, {}, {"GITHUB_SHA": self.head, "GITHUB_EVENT_NAME": event,
                                                      "GITHUB_REF": "refs/heads/codex/upload-memory"})

    def test_exact_m_and_a_pair_selects_existing_node_job_without_native_release_evidence(self):
        paths = list(self.rows())
        self.assertEqual(self.select(), planner.PRESERVATION_UPLOAD_SCOPE)
        self.assertEqual(planner.required_jobs(paths, planner.PRESERVATION_UPLOAD_SCOPE), (planner.PRESERVATION_JOB,))
        self.assertNotIn(planner.PRESERVATION_UPLOAD_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.PRESERVATION_UPLOAD_SCOPE)
        self.assertFalse(planner.preservation_upload_paths_only(None))
        self.assertFalse(planner.preservation_upload_paths_only([]))
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertEqual(planner.PRESERVATION_REVIEWED_TREE, "a6299352e82577e33aa0faf3e20c867729505c6d")

    def test_partial_unknown_mixed_modes_blobs_and_changed_workflow_fail_closed(self):
        original = self.rows()
        for path, fields in original.items():
            self.assertEqual(self.select({key: row for key, row in original.items() if key != path}), scope.FULL_SCOPE)
            for index, value in ((0, ":100755"), (1, "120000"), (2, "c" * 40), (3, "d" * 40), (4, "D"), (4, "R100")):
                changed = copy.deepcopy(original); changed[path][index] = value
                self.assertEqual(self.select(changed), scope.FULL_SCOPE, (path, index, value))
            changed = copy.deepcopy(original)
            changed[path][0], changed[path][4] = (":100644", "M") if fields[4] == "A" else (":000000", "A")
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/PreservationService/src/index.ts", "NekoWidget/PreservationService/test/other.test.ts",
                        "NekoWidget/PreservationService/package.json", "NekoWidget/SharingService/src/index.ts",
                        "NekoWidget/NekoWidget/Services/PhotoMemoryNoteExporter.swift", "handoffs/upload.md",
                        planner.PRESERVATION_WORKFLOW, ".github/workflows/ios-build.yml",
                        "NekoWidget/ci/plan-ios-ci.py", "NekoWidget/ci/preflight-ci.py",
                        "NekoWidget/ci/test-plan-ios-ci.py", "NekoWidget/ci/test-preflight-ci.py"):
            changed = original | {unknown: [":100644", "100644", "c" * 40, "d" * 40, "M"]}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE, unknown)
            self.assertEqual(planner.required_jobs(list(changed), planner.PRESERVATION_UPLOAD_SCOPE), planner.FULL)
        raw = "".join(" ".join(row) + "\0" + path + "\0" for path, row in original.items())
        for invalid in ("", raw + raw, raw.rsplit("\0", 2)[0]):
            self.assertEqual(self.select(raw=invalid), scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original) + [next(iter(original))]), scope.FULL_SCOPE)
        self.assertEqual(self.select(ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(event="workflow_dispatch"), scope.FULL_SCOPE)
        for revision in (self.base, self.head):
            self.assertEqual(self.select(workflow={revision: "e" * 40}), scope.FULL_SCOPE)
        with patch.object(planner, "PRESERVATION_UPLOAD_BLOBS", {path: ("0" * 40, "0" * 40) for path in original}):
            self.assertEqual(self.select(), scope.FULL_SCOPE)

    def test_candidate_and_main_plan_only_schedule_the_separate_same_sha_node_workflow(self):
        for ref in ("refs/heads/codex/upload-memory", "refs/heads/main"):
            with self.subTest(ref=ref), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root / "event.json").write_text("{}")
                env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": ref, "GITHUB_SHA": self.head,
                       "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "7",
                       "GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                       "GITHUB_STEP_SUMMARY": str(root / "summary")}
                output = io.StringIO()
                with patch.dict(os.environ, env), contextlib.redirect_stdout(output), \
                        patch.object(planner, "changed_paths", return_value=list(self.rows())), \
                        patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_UPLOAD_SCOPE), \
                        patch.object(planner, "find_evidence", side_effect=AssertionError("backend is not native evidence")):
                    planner.main()
                flags = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual([flags[name] for name in ("build", "smoke", "sharing", "app_ui")], ["false"] * 4)
                self.assertTrue(all(flags[name] == "[]" for name in ("lanes", "matrix_lanes", "app_ui_lanes")))
                record = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
                self.assertEqual(record["head_sha"], self.head)
                self.assertEqual(record["required_jobs"], [planner.PRESERVATION_JOB])
                self.assertIsNone(record["evidence_run_id"])
                self.assertIsNone(record["evidence_sha"])
                summary = (root / "summary").read_text()
                self.assertIn(planner.PRESERVATION_WORKFLOW, summary)
                self.assertIn("does not certify that job's success", summary)


class ImmediateBillingAuthorityScopeTests(unittest.TestCase):
    def candidate(self):
        return {path: ("reviewed before " + path, "reviewed after " + path)
                for path in planner.BILLING_AUTHORITY_PATHS}

    def select(self, changes, *, mutation=None, ancestor=True, workflow="owning workflow", companions=None):
        base, head = "b" * 40, "a" * 40
        pairs = {path: list(map(scope.source_digest, values)) for path, values in self.candidate().items()}
        def git(*args):
            if args[0] == "merge-base":
                if not ancestor: raise subprocess.CalledProcessError(1, args)
                return ""
            if args[0] == "diff":
                rows = []
                for path in changes:
                    modes, status = ":100644 100644", "M"
                    if mutation and path == mutation[0]: modes, status = mutation[1:]
                    rows.append(f"{modes} {'c'*40} {'d'*40} {status}\0{path}\0")
                return "".join(rows)
            if args[0] == "show":
                revision, path = args[1].split(":", 1)
                if path == planner.BILLING_WORKFLOW: return workflow
                return changes[path][revision == head]
            raise AssertionError(args)
        with patch.object(planner, "comparison_base", return_value=base), \
             patch.object(planner, "git", side_effect=git), \
             patch.object(planner, "BILLING_AUTHORITY_PRODUCTS", pairs), \
             patch.object(planner, "BILLING_AUTHORITY_WORKFLOW_DIGEST", scope.source_digest("owning workflow")), \
             patch.object(planner, "BILLING_AUTHORITY_COMPANION_DIGESTS", companions or {}):
            return planner.runtime_scope(list(changes), {}, {"GITHUB_SHA": head})

    def test_exact_batch_requires_existing_owning_backend_job(self):
        self.assertFalse(planner.billing_authority_paths_only(None))
        self.assertFalse(planner.billing_authority_paths_only([]))
        changes = self.candidate()
        self.assertFalse(planner.billing_authority_paths_only(list(changes) + [next(iter(changes))]))
        self.assertEqual(self.select(changes), planner.BILLING_AUTHORITY_SCOPE)
        self.assertEqual(planner.required_jobs(list(changes), planner.BILLING_AUTHORITY_SCOPE),
                         (planner.BILLING_AUTHORITY_JOB,))
        with self.assertRaises(ValueError):
            planner.required_jobs_from_scope(planner.BILLING_AUTHORITY_SCOPE)
        self.assertNotIn(planner.BILLING_AUTHORITY_SCOPE, scope.SCOPES)
        workflow = (Path(__file__).resolve().parents[2] / planner.BILLING_WORKFLOW).read_text(encoding="utf-8")
        check = workflow[workflow.index("  check:"):]
        self.assertIn("name: " + planner.BILLING_AUTHORITY_JOB, check)
        self.assertIn("run: npm run check", check)
        self.assertIn("--dry-run", check)
        self.assertNotIn(planner.BILLING_AUTHORITY_SCOPE, check)

    def test_unknown_partial_changed_or_unsafe_batch_is_full(self):
        original = self.candidate()
        for path in original:
            modified = dict(original); modified[path] = (modified[path][0], modified[path][1] + " unknown")
            self.assertEqual(self.select(modified), scope.FULL_SCOPE)
            removed = dict(original); del removed[path]
            self.assertEqual(self.select(removed), scope.FULL_SCOPE)
            for mode, status in ((":100644 100755", "M"), (":100644 120000", "T"),
                                 (":100644 000000", "D"), (":000000 100644", "A")):
                self.assertEqual(self.select(original, mutation=(path, mode, status)), scope.FULL_SCOPE)
        for path in ("NekoWidget/SharingService/src/env.ts", "NekoWidget/Shared/MembershipAccessPolicy.swift",
                     "NekoWidget/NekoWidget/Services/PlusPurchaseStore.swift", planner.BILLING_WORKFLOW):
            changed = original | {path: ("before", "after")}
            self.assertEqual(self.select(changed), scope.FULL_SCOPE)
            self.assertEqual(planner.required_jobs(list(changed), planner.BILLING_AUTHORITY_SCOPE), planner.FULL)
        self.assertEqual(self.select(original, ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(self.select(original, workflow="changed workflow"), scope.FULL_SCOPE)

    def test_control_companions_require_full_exact_self_bound_batch(self):
        changes = self.candidate()
        companions = {path: ("control before " + path, "control after " + path)
                      for path in planner.BILLING_AUTHORITY_COMPANION_PATHS}
        bindings = {path: list(map(scope.source_digest, pair)) for path, pair in companions.items()}
        planner_path = "NekoWidget/ci/plan-ios-ci.py"
        companions[planner_path] = (companions[planner_path][0],
            companions[planner_path][1] + "\nBILLING_AUTHORITY_COMPANION_DIGESTS = {}\n")
        bindings[planner_path] = list(map(scope.source_digest, companions[planner_path]))
        assignment = "BILLING_AUTHORITY_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        companions[planner_path] = (companions[planner_path][0], companions[planner_path][1].replace(
            "BILLING_AUTHORITY_COMPANION_DIGESTS = {}\n", assignment))
        self.assertEqual(self.select(changes | companions, companions=bindings), planner.BILLING_AUTHORITY_SCOPE)
        for path in companions:
            changed = dict(companions); del changed[path]
            self.assertEqual(self.select(changes | changed, companions=bindings), scope.FULL_SCOPE)
            changed = dict(companions); changed[path] = (changed[path][0], changed[path][1] + " drift")
            self.assertEqual(self.select(changes | changed, companions=bindings), scope.FULL_SCOPE)


class MembershipStateScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def candidate(self):
        products = {path: ("c" * 40, "d" * 40) for path in scope.MEMBERSHIP_STATE_PATHS}
        pairs = {path: ("before " + path, "after " + path) for path in scope.MEMBERSHIP_STATE_COMPANIONS}
        selector = "NekoWidget/ci/plan-ios-ci.py"
        empty = "MEMBERSHIP_STATE_COMPANION_DIGESTS = {}\n"
        pairs[selector] = (pairs[selector][0], empty + "# reviewed selector\n")
        bindings = {path: list(map(scope.source_digest, pair)) for path, pair in pairs.items()}
        literal = "MEMBERSHIP_STATE_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        pairs[selector] = (pairs[selector][0], pairs[selector][1].replace(empty, literal))
        rows = {path: f":100644 100644 {before} {after} M" for path, (before, after) in products.items()}
        rows.update({path: f":100644 100644 {'e' * 40} {'f' * 40} M" for path in pairs})
        source = "final class SoloMemoriesUITests: XCTestCase {\n" + "".join(
            "    func " + test.rsplit("/", 1)[-1] + "() {}\n" for test in scope.MEMBERSHIP_STATE_TESTS[:4])
        source += "}\nfinal class MomentDeliveryComposerUITests: XCTestCase {\n    func "
        source += scope.MEMBERSHIP_STATE_TESTS[-1].rsplit("/", 1)[-1] + "() {}\n}\n"
        return products, pairs, bindings, rows, source

    def verify(self, rows, *, paths=None, mutated=None, extra="", source=None, workflow=None, runtime=False):
        products, pairs, bindings, _, valid_source = self.candidate()
        def git(*args):
            if args[0] == "diff":
                return "".join(header + "\0" + path + "\0" for path, header in rows.items()) + extra
            if args[0] == "show":
                ref, path = args[1].split(":", 1)
                if path == scope.MEMORY_TEST_PATH:
                    return valid_source if source is None else source
                return pairs[path][int(ref == self.head)] + ("# altered" if path == mutated else "")
            if args[0] == "rev-parse":
                return workflow or planner.MEMBERSHIP_STATE_WORKFLOW_BLOB
            if args[0] == "merge-base":
                return self.base
            raise AssertionError(args)
        candidate_paths = list(rows) if paths is None else paths
        with patch.object(planner, "git", side_effect=git), \
                patch.object(planner, "comparison_base", return_value=self.base), \
                patch.object(planner, "MEMBERSHIP_STATE_BLOBS", products), \
                patch.object(planner, "MEMBERSHIP_STATE_COMPANION_DIGESTS", bindings):
            if runtime:
                return planner.runtime_scope(candidate_paths, {}, {"GITHUB_SHA": self.head})
            return planner.membership_state_only(candidate_paths, self.base, self.head)

    def test_complete_products_and_self_bound_controls_select_only_this_scope(self):
        products, pairs, _, rows, _ = self.candidate()
        self.assertTrue(self.verify(rows))
        self.assertTrue(self.verify({path: rows[path] for path in products}))
        self.assertEqual(self.verify(rows, runtime=True), scope.REVIEWED_MEMBERSHIP_STATE_SCOPE)
        self.assertEqual(self.verify({path: rows[path] for path in products}, runtime=True), scope.REVIEWED_MEMBERSHIP_STATE_SCOPE)
        self.assertFalse(planner.membership_state_only([], self.base, self.head))
        # Before final product hash review, real pending values cannot select.
        if any("pending-review" in pair for pair in scope.MEMBERSHIP_STATE_BLOBS.values()):
            self.assertFalse(planner.membership_state_only(list(rows), self.base, self.head))

    def test_partial_mutated_mode_unknown_or_workflow_changes_fail_closed(self):
        products, pairs, _, rows, _ = self.candidate()
        for path in rows:
            with self.subTest(missing=path):
                missing = {key: value for key, value in rows.items() if key != path}
                self.assertFalse(self.verify(missing))
                self.assertEqual(self.verify(missing, runtime=True), scope.FULL_SCOPE)
            for mode in ("100755", "120000", "160000", "000000"):
                changed = dict(rows); changed[path] = changed[path].replace("100644", mode)
                self.assertFalse(self.verify(changed), (path, mode))
            for status in ("A", "D", "T", "R100", "C100"):
                changed = dict(rows); changed[path] = changed[path][:-1] + status
                self.assertFalse(self.verify(changed), (path, status))
        for path, pair in products.items():
            for blob in pair:
                changed = dict(rows); changed[path] = changed[path].replace(blob, "1" * 40)
                self.assertFalse(self.verify(changed), (path, blob))
                self.assertEqual(self.verify(changed, runtime=True), scope.FULL_SCOPE)
        for path in pairs:
            self.assertFalse(self.verify(rows, mutated=path), path)
            self.assertEqual(self.verify(rows, mutated=path, runtime=True), scope.FULL_SCOPE)
        for path in ("NekoWidget/Shared/MembershipAccessPolicy.swift", "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                     "NekoWidget/NekoWidget.xcodeproj/project.pbxproj", scope.CI_WORKFLOW,
                     "NekoWidget/ci/preflight-ci.py", "NekoWidget/NekoWidget/Services/NewStore.swift"):
            changed = rows | {path: f":100644 100644 {'c' * 40} {'d' * 40} M"}
            self.assertFalse(self.verify(changed), path)
            self.assertEqual(self.verify(changed, runtime=True), scope.FULL_SCOPE)
        self.assertFalse(self.verify(rows, workflow="1" * 40))
        self.assertEqual(self.verify(rows, workflow="1" * 40, runtime=True), scope.FULL_SCOPE)
        first = next(iter(rows))
        self.assertFalse(self.verify(rows, paths=list(rows) + [first]))
        self.assertFalse(self.verify(rows, extra=rows[first] + "\0" + first + "\0"))
        handoff = rows | {"handoffs/membership-state.md": f":000000 100644 {'0' * 40} {'d' * 40} A"}
        self.assertTrue(self.verify(handoff))
        handoff["handoffs/membership-state.md"] = handoff["handoffs/membership-state.md"].replace("100644", "120000")
        self.assertFalse(self.verify(handoff))

    def test_all_five_methods_and_available_git_evidence_are_required(self):
        _, _, _, rows, source = self.candidate()
        for test in scope.MEMBERSHIP_STATE_TESTS:
            method = test.rsplit("/", 1)[-1]
            self.assertFalse(self.verify(rows, source=source.replace("func " + method, "func missing")), test)
            self.assertEqual(self.verify(rows, source=source.replace("func " + method, "func missing"), runtime=True), scope.FULL_SCOPE)
        self.assertFalse(self.verify(rows, source=source.replace("MomentDeliveryComposerUITests", "OtherUITests")))
        self.assertFalse(self.verify(rows, source=source.replace("func testMembershipOfferPreviewReturnsToPurpose() {}",
            "/* func testMembershipOfferPreviewReturnsToPurpose() {} */")))
        with patch.object(planner, "comparison_base", return_value=self.base), \
                patch.object(planner, "git", side_effect=subprocess.CalledProcessError(1, "git")):
            self.assertEqual(planner.runtime_scope(sorted(scope.MEMBERSHIP_STATE_PATHS), {}, {"GITHUB_SHA": self.head}), scope.FULL_SCOPE)


class PurchaseCatalogScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def candidate(self):
        products = {path: ("c" * 40, "d" * 40) for path in scope.PURCHASE_CATALOG_PATHS}
        pairs = {path: ("before " + path, "after " + path) for path in scope.PURCHASE_CATALOG_COMPANIONS}
        selector = "NekoWidget/ci/plan-ios-ci.py"
        empty = "PURCHASE_CATALOG_COMPANION_DIGESTS = {}\n"
        pairs[selector] = (pairs[selector][0], empty + "# reviewed selector\n")
        bindings = {path: list(map(scope.source_digest, pair)) for path, pair in pairs.items()}
        literal = "PURCHASE_CATALOG_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        pairs[selector] = (pairs[selector][0], pairs[selector][1].replace(empty, literal))
        rows = {path: f":100644 100644 {before} {after} M" for path, (before, after) in products.items()}
        rows.update({path: f":100644 100644 {'e' * 40} {'f' * 40} M" for path in pairs})
        source = "final class SoloMemoriesUITests: XCTestCase {\n" + "".join(
            "    func " + test.rsplit("/", 1)[-1] + "() {}\n" for test in scope.PURCHASE_CATALOG_TESTS[:4])
        source += "}\nfinal class MomentDeliveryComposerUITests: XCTestCase {\n    func "
        source += scope.PURCHASE_CATALOG_TESTS[-1].rsplit("/", 1)[-1] + "() {}\n}\n"
        return products, pairs, bindings, rows, source

    def verify(self, rows, *, paths=None, mutated=None, extra="", source=None, workflow=None, runtime=False):
        products, pairs, bindings, _, valid_source = self.candidate()
        def git(*args):
            if args[0] == "diff":
                return "".join(header + "\0" + path + "\0" for path, header in rows.items()) + extra
            if args[0] == "show":
                ref, path = args[1].split(":", 1)
                if path == scope.MEMORY_TEST_PATH:
                    return valid_source if source is None else source
                return pairs[path][int(ref == self.head)] + ("# altered" if path == mutated else "")
            if args[0] == "rev-parse":
                return workflow or planner.PURCHASE_CATALOG_WORKFLOW_BLOB
            if args[0] == "merge-base":
                return self.base
            raise AssertionError(args)
        candidate_paths = list(rows) if paths is None else paths
        with patch.object(planner, "git", side_effect=git), \
                patch.object(planner, "comparison_base", return_value=self.base), \
                patch.object(planner, "PURCHASE_CATALOG_BLOBS", products), \
                patch.object(planner, "PURCHASE_CATALOG_COMPANION_DIGESTS", bindings):
            if runtime:
                return planner.runtime_scope(candidate_paths, {}, {"GITHUB_SHA": self.head})
            return planner.purchase_catalog_only(candidate_paths, self.base, self.head)

    def test_complete_products_and_self_bound_controls_select_only_this_scope(self):
        products, pairs, _, rows, _ = self.candidate()
        self.assertTrue(self.verify(rows))
        self.assertTrue(self.verify({path: rows[path] for path in products}))
        self.assertEqual(self.verify(rows, runtime=True), scope.REVIEWED_PURCHASE_CATALOG_SCOPE)
        self.assertEqual(self.verify({path: rows[path] for path in products}, runtime=True), scope.REVIEWED_PURCHASE_CATALOG_SCOPE)
        self.assertFalse(planner.purchase_catalog_only([], self.base, self.head))
        # Before final product hash review, real pending values cannot select.
        if any("pending-review" in pair for pair in scope.PURCHASE_CATALOG_BLOBS.values()):
            self.assertFalse(planner.purchase_catalog_only(list(rows), self.base, self.head))

    def test_partial_mutated_mode_unknown_or_workflow_changes_fail_closed(self):
        products, pairs, _, rows, _ = self.candidate()
        for path in rows:
            with self.subTest(missing=path):
                missing = {key: value for key, value in rows.items() if key != path}
                self.assertFalse(self.verify(missing))
                self.assertEqual(self.verify(missing, runtime=True), scope.FULL_SCOPE)
            for mode in ("100755", "120000", "160000", "000000"):
                changed = dict(rows); changed[path] = changed[path].replace("100644", mode)
                self.assertFalse(self.verify(changed), (path, mode))
            for status in ("A", "D", "T", "R100", "C100"):
                changed = dict(rows); changed[path] = changed[path][:-1] + status
                self.assertFalse(self.verify(changed), (path, status))
        for path, pair in products.items():
            for blob in pair:
                changed = dict(rows); changed[path] = changed[path].replace(blob, "1" * 40)
                self.assertFalse(self.verify(changed), (path, blob))
                self.assertEqual(self.verify(changed, runtime=True), scope.FULL_SCOPE)
        for path in pairs:
            self.assertFalse(self.verify(rows, mutated=path), path)
            self.assertEqual(self.verify(rows, mutated=path, runtime=True), scope.FULL_SCOPE)
        for path in ("NekoWidget/Shared/MembershipAccessPolicy.swift", "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                     "NekoWidget/NekoWidget.xcodeproj/project.pbxproj", scope.CI_WORKFLOW,
                     "NekoWidget/ci/preflight-ci.py", "NekoWidget/NekoWidget/Services/NewStore.swift"):
            changed = rows | {path: f":100644 100644 {'c' * 40} {'d' * 40} M"}
            self.assertFalse(self.verify(changed), path)
            self.assertEqual(self.verify(changed, runtime=True), scope.FULL_SCOPE)
        self.assertFalse(self.verify(rows, workflow="1" * 40))
        self.assertEqual(self.verify(rows, workflow="1" * 40, runtime=True), scope.FULL_SCOPE)
        first = next(iter(rows))
        self.assertFalse(self.verify(rows, paths=list(rows) + [first]))
        self.assertFalse(self.verify(rows, extra=rows[first] + "\0" + first + "\0"))
        handoff = rows | {"handoffs/purchase-catalog.md": f":000000 100644 {'0' * 40} {'d' * 40} A"}
        self.assertTrue(self.verify(handoff))
        handoff["handoffs/purchase-catalog.md"] = handoff["handoffs/purchase-catalog.md"].replace("100644", "120000")
        self.assertFalse(self.verify(handoff))

    def test_all_five_methods_and_available_git_evidence_are_required(self):
        _, _, _, rows, source = self.candidate()
        for test in scope.PURCHASE_CATALOG_TESTS:
            method = test.rsplit("/", 1)[-1]
            self.assertFalse(self.verify(rows, source=source.replace("func " + method, "func missing")), test)
            self.assertEqual(self.verify(rows, source=source.replace("func " + method, "func missing"), runtime=True), scope.FULL_SCOPE)
        self.assertFalse(self.verify(rows, source=source.replace("MomentDeliveryComposerUITests", "OtherUITests")))
        self.assertFalse(self.verify(rows, source=source.replace("func testMembershipOfferPreviewReturnsToPurpose() {}",
            "/* func testMembershipOfferPreviewReturnsToPurpose() {} */")))
        with patch.object(planner, "comparison_base", return_value=self.base), \
                patch.object(planner, "git", side_effect=subprocess.CalledProcessError(1, "git")):
            self.assertEqual(planner.runtime_scope(sorted(scope.PURCHASE_CATALOG_PATHS), {}, {"GITHUB_SHA": self.head}), scope.FULL_SCOPE)


class ToolPreservationDiagnosticInputTests(unittest.TestCase):
    source, head, base = planner.TOOL_PRESERVATION_SOURCE, "a" * 40, "b" * 40

    def rows(self):
        return {path: [":100644", "100644", "c"*40, "d"*40, "M"]
                for path in planner.TOOL_PRESERVATION_CONTROLS}

    def verify(self, rows=None, *, raw=None, source=None, approved=True, product=True, immutable=True, ancestor=True, registration=True):
        rows = self.rows() if rows is None else rows
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor: raise subprocess.CalledProcessError(1,args)
                return self.base
            if args[0] == "show": return f'TOOL_PRESERVATION_SOURCE = "{self.source}"' if registration else "unapproved"
            if args[0] == "diff":
                if "--name-only" in args:
                    return "\0".join(rows if args[-2] == self.source else planner.TOOL_PRESERVATION_PATHS) + "\0"
                return raw if raw is not None else "".join(" ".join(fields)+"\0"+path+"\0" for path,fields in rows.items())
            if args[0] == "ls-tree": return f"100644 blob {('d' if approved or args[1] != self.head else 'e')*40}\t{args[3]}"
            raise AssertionError(args)
        with patch.object(planner,"git",side_effect=git), \
                patch.object(planner,"tool_preservation_only",return_value=product) as gate, \
                patch.object(planner,"tool_preservation_immutable_inputs",return_value=immutable):
            result = planner.tool_preservation_diagnostic_inputs(source or self.source,self.head)
            if gate.called:
                self.assertEqual(set(gate.call_args.args[0]),planner.TOOL_PRESERVATION_PATHS)
                self.assertEqual(gate.call_args.args[1:],(self.base,self.head))
            return result

    def test_only_fixed_source_unchanged_products_and_all_approved_controls_qualify(self):
        self.assertTrue(self.verify())
        for kwargs in ({"source":"e"*40},{"approved":False},{"product":False},{"immutable":False},
                       {"ancestor":False},{"registration":False}):
            self.assertFalse(self.verify(**kwargs),kwargs)

    def test_normal_handoff_only_and_no_source_mode_type_unknown_or_duplicate_changes(self):
        rows=self.rows()
        for status,before in (("M","c"*40),("A","0"*40)):
            note=[":100644" if status=="M" else ":000000","100644",before,"d"*40,status]
            self.assertTrue(self.verify(rows|{"handoffs/review.md":note}))
        for path in (planner.MEMORY_TEST_PATH, planner.TOOL_PRESERVATION_PROJECT,
                     "NekoWidget/ci/run-sharing-runtime-matrix.sh", planner.PRESERVATION_WORKFLOW,
                     "handoffs/2026-10-14-public-policy.json", "unknown"):
            self.assertFalse(self.verify(rows|{path:[":100644","100644","c"*40,"d"*40,"M"]}),path)
        path=next(iter(rows))
        for index,value in ((0,":000000"),(1,"100755"),(1,"120000"),(1,"160000"),(2,"0"*40),(3,"0"*40),(4,"D"),(4,"A"),(4,"R100")):
            changed=copy.deepcopy(rows);changed[path][index]=value
            self.assertFalse(self.verify(changed),(index,value))
        raw="".join(" ".join(fields)+"\0"+path+"\0" for path,fields in rows.items())
        for invalid in ("",raw+raw,raw.rsplit("\0",2)[0]): self.assertFalse(self.verify(raw=invalid))


class PreservationExportScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def candidate(self):
        products = {path: ("0" * 40 if index % 2 else "c" * 40, "d" * 40)
                    for index, path in enumerate(sorted(scope.PRESERVATION_EXPORT_PATHS))}
        pairs = {path: ("before " + path, "after " + path) for path in scope.PRESERVATION_EXPORT_COMPANIONS}
        selector = "NekoWidget/ci/plan-ios-ci.py"
        empty = "PRESERVATION_EXPORT_COMPANION_DIGESTS = {}\n"
        pairs[selector] = (pairs[selector][0], empty + "# reviewed selector\n")
        bindings = {path: list(map(scope.source_digest, pair)) for path, pair in pairs.items()}
        literal = "PRESERVATION_EXPORT_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        pairs[selector] = (pairs[selector][0], pairs[selector][1].replace(empty, literal))
        rows = {path: f":{'000000' if before == '0' * 40 else '100644'} 100644 {before} {after} {'A' if before == '0' * 40 else 'M'}"
                for path, (before, after) in products.items()}
        rows["handoffs/export.md"] = f":000000 100644 {'0' * 40} {'d' * 40} A"
        rows.update({path: f":100644 100644 {'e' * 40} {'f' * 40} M" for path in pairs})
        source = "final class SoloMemoriesUITests: XCTestCase {\n" + "".join(
            "    func " + test.rsplit("/", 1)[-1] + "() {}\n" for test in scope.PRESERVATION_EXPORT_TESTS[:3])
        source += "}\nfinal class MomentDeliveryComposerUITests: XCTestCase {\n    func "
        source += scope.PRESERVATION_EXPORT_TESTS[-1].rsplit("/", 1)[-1] + "() {}\n}\n"
        return products, pairs, bindings, rows, source

    def verify(self, rows, *, paths=None, mutated=None, extra="", source=None, workflow=None, runtime=False):
        products, pairs, bindings, _, valid_source = self.candidate()
        def git(*args):
            if args[0] == "diff":
                return "".join(header + "\0" + path + "\0" for path, header in rows.items()) + extra
            if args[0] == "show":
                ref, path = args[1].split(":", 1)
                if path == scope.MEMORY_TEST_PATH:
                    return valid_source if source is None else source
                return pairs[path][int(ref == self.head)] + ("# altered" if path == mutated else "")
            if args[0] == "rev-parse":
                return workflow or planner.PRESERVATION_EXPORT_WORKFLOWS[args[1].split(":", 1)[1]]
            if args[0] == "merge-base":
                return self.base
            raise AssertionError(args)
        candidate_paths = list(rows) if paths is None else paths
        with patch.object(planner, "git", side_effect=git), \
                patch.object(planner, "comparison_base", return_value=self.base), \
                patch.object(planner, "PRESERVATION_EXPORT_BLOBS", products), \
                patch.object(planner, "PRESERVATION_EXPORT_DOC_BLOBS", {"handoffs/export.md": ("0" * 40, "d" * 40)}), \
                patch.object(planner, "PRESERVATION_EXPORT_COMPANION_DIGESTS", bindings):
            if runtime:
                return planner.runtime_scope(candidate_paths, {}, {"GITHUB_SHA": self.head})
            return planner.preservation_export_only(candidate_paths, self.base, self.head)

    def test_complete_products_and_self_bound_controls_select_only_this_scope(self):
        products, pairs, _, rows, _ = self.candidate()
        self.assertTrue(self.verify(rows))
        self.assertTrue(self.verify({path: rows[path] for path in rows if path not in pairs}))
        self.assertEqual(self.verify(rows, runtime=True), scope.PRESERVATION_EXPORT_SCOPE)
        self.assertEqual(self.verify({path: rows[path] for path in rows if path not in pairs}, runtime=True), scope.PRESERVATION_EXPORT_SCOPE)
        self.assertFalse(planner.preservation_export_only([], self.base, self.head))
        # Before final product hash review, real pending values cannot select.
        if any("pending-review" in pair for pair in scope.PRESERVATION_EXPORT_BLOBS.values()):
            self.assertFalse(planner.preservation_export_only(list(rows), self.base, self.head))

    def test_partial_mutated_mode_unknown_or_workflow_changes_fail_closed(self):
        products, pairs, _, rows, _ = self.candidate()
        for path in rows:
            with self.subTest(missing=path):
                missing = {key: value for key, value in rows.items() if key != path}
                self.assertFalse(self.verify(missing))
                self.assertEqual(self.verify(missing, runtime=True), scope.FULL_SCOPE)
            for mode in ("100755", "120000", "160000", "000000"):
                changed = dict(rows); changed[path] = changed[path].replace("100644", mode)
                self.assertFalse(self.verify(changed), (path, mode))
            for status in ({"A", "M", "D", "T", "R100", "C100"} - {rows[path].split()[-1]}):
                changed = dict(rows); changed[path] = changed[path][:-1] + status
                self.assertFalse(self.verify(changed), (path, status))
        for path, pair in products.items():
            for blob in pair:
                changed = dict(rows); changed[path] = changed[path].replace(blob, "1" * 40)
                self.assertFalse(self.verify(changed), (path, blob))
                self.assertEqual(self.verify(changed, runtime=True), scope.FULL_SCOPE)
        for path in pairs:
            self.assertFalse(self.verify(rows, mutated=path), path)
            self.assertEqual(self.verify(rows, mutated=path, runtime=True), scope.FULL_SCOPE)
        for path in ("NekoWidget/Shared/MembershipAccessPolicy.swift", "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                     "NekoWidget/NekoWidget.xcodeproj/project.pbxproj", scope.CI_WORKFLOW,
                     "NekoWidget/ci/preflight-ci.py", "NekoWidget/NekoWidget/Services/NewStore.swift"):
            changed = rows | {path: f":100644 100644 {'c' * 40} {'d' * 40} M"}
            self.assertFalse(self.verify(changed), path)
            self.assertEqual(self.verify(changed, runtime=True), scope.FULL_SCOPE)
        self.assertFalse(self.verify(rows, workflow="1" * 40))
        self.assertEqual(self.verify(rows, workflow="1" * 40, runtime=True), scope.FULL_SCOPE)
        first = next(iter(rows))
        self.assertFalse(self.verify(rows, paths=list(rows) + [first]))
        self.assertFalse(self.verify(rows, extra=rows[first] + "\0" + first + "\0"))
        handoff = rows | {"handoffs/purchase-catalog.md": f":000000 100644 {'0' * 40} {'d' * 40} A"}
        self.assertFalse(self.verify(handoff))
        handoff["handoffs/purchase-catalog.md"] = handoff["handoffs/purchase-catalog.md"].replace("100644", "120000")
        self.assertFalse(self.verify(handoff))

    def test_all_four_methods_and_available_git_evidence_are_required(self):
        _, _, _, rows, source = self.candidate()
        for test in scope.PRESERVATION_EXPORT_TESTS:
            method = test.rsplit("/", 1)[-1]
            self.assertFalse(self.verify(rows, source=source.replace("func " + method, "func missing")), test)
            self.assertEqual(self.verify(rows, source=source.replace("func " + method, "func missing"), runtime=True), scope.FULL_SCOPE)
        self.assertFalse(self.verify(rows, source=source.replace("MomentDeliveryComposerUITests", "OtherUITests")))
        self.assertFalse(self.verify(rows, source=source.replace("func testManagedPreservationMembershipLinkConsentAndRetry() {}",
            "/* func testManagedPreservationMembershipLinkConsentAndRetry() {} */")))
        with patch.object(planner, "comparison_base", return_value=self.base), \
                patch.object(planner, "git", side_effect=subprocess.CalledProcessError(1, "git")):
            self.assertEqual(planner.runtime_scope(sorted(scope.PRESERVATION_EXPORT_PATHS), {}, {"GITHUB_SHA": self.head}), scope.FULL_SCOPE)


class PreservationExportCorrectionInputTests(unittest.TestCase):
    def test_only_frozen_test_blob_and_all_approved_controls_can_change(self):
        source, head = planner.PRESERVATION_EXPORT_CORRECTION_SOURCE, "a" * 40
        before, after = planner.PRESERVATION_EXPORT_CORRECTION_BLOBS
        path = planner.MEMORY_TEST_PATH
        row = f":100644 100644 {before} {after} M\0{path}\0"
        def verify(raw=row, *, unapproved=None, missing_source=False, registered=True):
            def git(*args):
                if args[0] == "diff": return raw
                if args[:2] == ("merge-base", "--is-ancestor") and missing_source:
                    raise subprocess.CalledProcessError(1, "git")
                if args[0] == "merge-base": return "b" * 40
                if args[0] == "show":
                    return f'PRESERVATION_EXPORT_CORRECTION_SOURCE = "{source}"' if registered else "old planner"
                if args[0] == "rev-parse":
                    return "d" * 40 if args[1] == head + ":" + str(unapproved) else "c" * 40
                raise AssertionError(args)
            with patch.object(planner, "git", side_effect=git):
                return planner.preservation_export_correction_inputs(source, head)
        self.assertTrue(verify())
        for control in planner.TEST_CORRECTION_CONTROL_PATHS:
            extra = f":100644 100644 {'e' * 40} {'c' * 40} M\0{control}\0"
            self.assertTrue(verify(row + extra), control)
            self.assertFalse(verify(row + extra, unapproved=control), control)
            self.assertFalse(verify(unapproved=control), control)
        for invalid in ("", row + row, row.replace(before, "c" * 40), row.replace(after, "d" * 40),
                        row.replace("100644", "100755"), row.replace(" M\0", " A\0")):
            self.assertFalse(verify(invalid))
        for unknown in ("NekoWidget/NekoWidget/Services/PhotoMemoryNoteExporter.swift",
                        ".github/workflows/ios-build.yml", "NekoWidget/ci/ios_ci_scope.py",
                        "NekoWidget/PreservationService/src/index.ts", "handoffs/extra.md"):
            self.assertFalse(verify(row + f":100644 100644 {'e' * 40} {'c' * 40} M\0{unknown}\0"))
        self.assertFalse(verify(missing_source=True))
        self.assertFalse(verify(registered=False))
        self.assertFalse(planner.preservation_export_correction_inputs(source, source))
        self.assertFalse(planner.preservation_export_correction_inputs("c" * 40, head))

    def test_corrected_selector_pins_all_original_products_and_new_test_blob(self):
        base, head = "b" * 40, "a" * 40
        products = dict(planner.PRESERVATION_EXPORT_BLOBS)
        before = products[planner.MEMORY_TEST_PATH][0]
        products[planner.MEMORY_TEST_PATH] = (before, planner.PRESERVATION_EXPORT_CORRECTION_BLOBS[1])
        blobs = products | planner.PRESERVATION_EXPORT_DOC_BLOBS
        raw = "".join(f":{'000000' if old == '0' * 40 else '100644'} 100644 {old} {new} {'A' if old == '0' * 40 else 'M'}\0{path}\0"
                      for path, (old, new) in blobs.items())
        def git(*args):
            if args[0] == "diff": return raw
            if args[0] == "rev-parse": return planner.PRESERVATION_EXPORT_WORKFLOWS[args[1].split(":", 1)[1]]
            if args[0] == "show": return "new test contents"
            raise AssertionError(args)
        with patch.object(planner, "git", side_effect=git), \
                patch.object(planner, "preservation_export_correction_inputs", return_value=True), \
                patch.object(planner, "memory_tests_available", return_value=True), \
                patch.object(planner, "comparison_base", return_value=base):
            self.assertTrue(planner.preservation_export_only(list(blobs), base, head))
            self.assertEqual(planner.runtime_scope(list(blobs), {}, {"GITHUB_SHA": head}), planner.PRESERVATION_EXPORT_SCOPE)
            self.assertEqual(planner.required_jobs(list(blobs), planner.PRESERVATION_EXPORT_SCOPE),
                             planner.required_jobs_from_scope(planner.PRESERVATION_EXPORT_SCOPE))
            with patch.object(planner, "preservation_export_correction_inputs", return_value=False):
                self.assertFalse(planner.preservation_export_only(list(blobs), base, head))


class PreservationSharingPlanTests(unittest.TestCase):
    def test_backend_plan_requires_actual_same_repo_workflow_and_never_uses_native_reuse(self):
        env = {"GITHUB_WORKFLOW": "Sharing service check", "GITHUB_EVENT_NAME": "push", "GITHUB_REPOSITORY": "soso-so-27/neko-widget",
               "GITHUB_SHA": "a" * 40, "GITHUB_RUN_ID": "7"}
        identity = {"id": 5, "path": ".github/workflows/sharing-service.yml", "state": "active"}
        run = {"id": 7, "workflow_id": 5, "path": identity["path"], "event": "push", "head_sha": env["GITHUB_SHA"],
               "repository": {"full_name": env["GITHUB_REPOSITORY"]},
               "head_repository": {"full_name": env["GITHUB_REPOSITORY"]}, "head_branch": "main"}
        def verify(value):
            with patch.object(planner, "github_api", side_effect=[identity, value]), \
                    patch.object(planner, "find_evidence", side_effect=AssertionError("backend cannot reuse native evidence")):
                return planner.preservation_sharing_plan(env)
        self.assertTrue(verify(run))
        self.assertTrue(verify(run | {"head_branch": "codex/export"}))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); event = root / "event.json"; event.write_text("{}")
            main_env = env | {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main",
                "GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(root / "output"),
                "GITHUB_STEP_SUMMARY": str(root / "summary")}
            with patch.dict(os.environ, main_env), \
                    patch.object(planner, "changed_paths", return_value=list(scope.PRESERVATION_EXPORT_PATHS)), \
                    patch.object(planner, "runtime_scope", return_value=scope.PRESERVATION_EXPORT_SCOPE), \
                    patch.object(planner, "github_api", side_effect=[identity, run]), \
                    patch.object(planner, "find_evidence", side_effect=AssertionError("backend cannot wait for itself")):
                planner.main()
            output = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            self.assertEqual(output["runtime_scope"], scope.PRESERVATION_EXPORT_SCOPE)
            self.assertTrue(all(output[flag] == "false" for flag in ("build", "smoke", "sharing", "app_ui")))
            # PR remains a supported backend selection event, but cannot be
            # treated as a successful candidate push or wait for native reuse.
            (root / "output").write_text("")
            event.write_text(json.dumps({"pull_request": {"head": {"repo": {"full_name": env["GITHUB_REPOSITORY"]}}}}))
            with patch.dict(os.environ, main_env | {"GITHUB_EVENT_NAME": "pull_request", "GITHUB_REF": "refs/pull/1/merge"}), \
                    patch.object(planner, "changed_paths", return_value=list(scope.PRESERVATION_EXPORT_PATHS)), \
                    patch.object(planner, "runtime_scope", return_value=scope.PRESERVATION_EXPORT_SCOPE), \
                    patch.object(planner, "github_api", side_effect=AssertionError("PR is not candidate evidence")):
                planner.main()
            pr_output = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            self.assertEqual(pr_output["runtime_scope"], scope.PRESERVATION_EXPORT_SCOPE)
        for key, value in (("id", 8), ("workflow_id", 6), ("path", ".github/workflows/ios-build.yml"),
                ("event", "pull_request"), ("head_sha", "b" * 40), ("head_branch", "diagnostic/export"),
                ("repository", {"full_name": "other/repo"}), ("head_repository", {"full_name": "other/repo"})):
            with self.subTest(key=key), self.assertRaises(ValueError): verify(run | {key: value})
        with patch.object(planner, "github_api", side_effect=AssertionError("wrong audience")):
            self.assertFalse(planner.preservation_sharing_plan(env | {"GITHUB_WORKFLOW": "iOS build check"}))


class MembershipManagementScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40

    def candidate(self):
        products = {path: ("c" * 40, "d" * 40) for path in scope.MEMBERSHIP_MANAGEMENT_PATHS}
        pairs = {path: ("before " + path, "after " + path) for path in scope.MEMBERSHIP_MANAGEMENT_COMPANIONS}
        selector = "NekoWidget/ci/plan-ios-ci.py"
        empty = "MEMBERSHIP_MANAGEMENT_COMPANION_DIGESTS = {}\n"
        pairs[selector] = (pairs[selector][0], empty + "# reviewed selector\n")
        bindings = {path: list(map(scope.source_digest, pair)) for path, pair in pairs.items()}
        literal = "MEMBERSHIP_MANAGEMENT_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        pairs[selector] = (pairs[selector][0], pairs[selector][1].replace(empty, literal))
        rows = {path: f":100644 100644 {before} {after} M" for path, (before, after) in products.items()}
        rows.update({path: f":100644 100644 {'e' * 40} {'f' * 40} M" for path in pairs})
        source = "final class SoloMemoriesUITests: XCTestCase {\n" + "".join(
            "    func " + test.rsplit("/", 1)[-1] + "() {}\n" for test in scope.MEMBERSHIP_MANAGEMENT_TESTS[:4])
        source += "}\n"
        return products, pairs, bindings, rows, source

    def verify(self, rows, *, paths=None, mutated=None, extra="", source=None, workflow=None, runtime=False):
        products, pairs, bindings, _, valid_source = self.candidate()
        def git(*args):
            if args[0] == "diff":
                return "".join(header + "\0" + path + "\0" for path, header in rows.items()) + extra
            if args[0] == "show":
                ref, path = args[1].split(":", 1)
                if path == scope.MEMORY_TEST_PATH:
                    return valid_source if source is None else source
                return pairs[path][int(ref == self.head)] + ("# altered" if path == mutated else "")
            if args[0] == "rev-parse":
                return workflow or planner.MEMBERSHIP_MANAGEMENT_WORKFLOW_BLOB
            if args[0] == "merge-base":
                return self.base
            raise AssertionError(args)
        candidate_paths = list(rows) if paths is None else paths
        with patch.object(planner, "git", side_effect=git), \
                patch.object(planner, "comparison_base", return_value=self.base), \
                patch.object(planner, "MEMBERSHIP_MANAGEMENT_BLOBS", products), \
                patch.object(planner, "MEMBERSHIP_MANAGEMENT_COMPANION_DIGESTS", bindings):
            if runtime:
                return planner.runtime_scope(candidate_paths, {}, {"GITHUB_SHA": self.head})
            return planner.membership_management_only(candidate_paths, self.base, self.head)

    def test_complete_products_and_self_bound_controls_select_only_this_scope(self):
        products, pairs, _, rows, _ = self.candidate()
        self.assertTrue(self.verify(rows))
        self.assertTrue(self.verify({path: rows[path] for path in products}))
        self.assertEqual(self.verify(rows, runtime=True), scope.REVIEWED_MEMBERSHIP_MANAGEMENT_SCOPE)
        self.assertEqual(self.verify({path: rows[path] for path in products}, runtime=True), scope.REVIEWED_MEMBERSHIP_MANAGEMENT_SCOPE)
        self.assertFalse(planner.membership_management_only([], self.base, self.head))
        # Before final product hash review, real pending values cannot select.
        if any("pending-review" in pair for pair in scope.MEMBERSHIP_MANAGEMENT_BLOBS.values()):
            self.assertFalse(planner.membership_management_only(list(rows), self.base, self.head))

    def test_partial_mutated_mode_unknown_or_workflow_changes_fail_closed(self):
        products, pairs, _, rows, _ = self.candidate()
        for path in rows:
            with self.subTest(missing=path):
                missing = {key: value for key, value in rows.items() if key != path}
                self.assertFalse(self.verify(missing))
                self.assertEqual(self.verify(missing, runtime=True), scope.FULL_SCOPE)
            for mode in ("100755", "120000", "160000", "000000"):
                changed = dict(rows); changed[path] = changed[path].replace("100644", mode)
                self.assertFalse(self.verify(changed), (path, mode))
            for status in ("A", "D", "T", "R100", "C100"):
                changed = dict(rows); changed[path] = changed[path][:-1] + status
                self.assertFalse(self.verify(changed), (path, status))
        for path, pair in products.items():
            for blob in pair:
                changed = dict(rows); changed[path] = changed[path].replace(blob, "1" * 40)
                self.assertFalse(self.verify(changed), (path, blob))
                self.assertEqual(self.verify(changed, runtime=True), scope.FULL_SCOPE)
        for path in pairs:
            self.assertFalse(self.verify(rows, mutated=path), path)
            self.assertEqual(self.verify(rows, mutated=path, runtime=True), scope.FULL_SCOPE)
        for path in ("NekoWidget/Shared/MembershipAccessPolicy.swift", "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                     "NekoWidget/NekoWidget.xcodeproj/project.pbxproj", scope.CI_WORKFLOW,
                     "NekoWidget/ci/preflight-ci.py", "NekoWidget/NekoWidget/Services/NewStore.swift"):
            changed = rows | {path: f":100644 100644 {'c' * 40} {'d' * 40} M"}
            self.assertFalse(self.verify(changed), path)
            self.assertEqual(self.verify(changed, runtime=True), scope.FULL_SCOPE)
        self.assertFalse(self.verify(rows, workflow="1" * 40))
        self.assertEqual(self.verify(rows, workflow="1" * 40, runtime=True), scope.FULL_SCOPE)
        first = next(iter(rows))
        self.assertFalse(self.verify(rows, paths=list(rows) + [first]))
        self.assertFalse(self.verify(rows, extra=rows[first] + "\0" + first + "\0"))
        handoff = rows | {"handoffs/membership-management.md": f":000000 100644 {'0' * 40} {'d' * 40} A"}
        self.assertTrue(self.verify(handoff))
        handoff["handoffs/membership-management.md"] = handoff["handoffs/membership-management.md"].replace("100644", "120000")
        self.assertFalse(self.verify(handoff))

    def test_all_four_methods_and_available_git_evidence_are_required(self):
        _, _, _, rows, source = self.candidate()
        for test in scope.MEMBERSHIP_MANAGEMENT_TESTS:
            method = test.rsplit("/", 1)[-1]
            self.assertFalse(self.verify(rows, source=source.replace("func " + method, "func missing")), test)
            self.assertEqual(self.verify(rows, source=source.replace("func " + method, "func missing"), runtime=True), scope.FULL_SCOPE)
        self.assertFalse(self.verify(rows, source=source.replace("SoloMemoriesUITests", "OtherUITests")))
        self.assertFalse(self.verify(rows, source=source.replace("func testMembershipOfferPreviewReturnsToPurpose() {}",
            "/* func testMembershipOfferPreviewReturnsToPurpose() {} */")))
        with patch.object(planner, "comparison_base", return_value=self.base), \
                patch.object(planner, "git", side_effect=subprocess.CalledProcessError(1, "git")):
            self.assertEqual(planner.runtime_scope(sorted(scope.MEMBERSHIP_MANAGEMENT_PATHS), {}, {"GITHUB_SHA": self.head}), scope.FULL_SCOPE)


class PlanTests(unittest.TestCase):
    def test_billing_operator_scope_is_closed_and_requires_owning_tests(self):
        paths = sorted(planner.BILLING_OPERATOR_PATHS) + ["handoffs/operator.md"]
        def selected(changed=paths, *, altered=None, duplicate=False, wired=True):
            def git(*args):
                if args[0] == "diff":
                    rows = []
                    for path in ([changed[0]] * len(changed) if duplicate else changed):
                        modes, status = ((":000000 100644", "A") if path == planner.BILLING_OPERATOR_ENTRY
                                         else (":100644 100644", "M"))
                        if altered and path == altered[0]: modes, status = altered[1:]
                        rows.append(f"{modes} {'c' * 40} {'d' * 40} {status}\0{path}\0")
                    return "".join(rows)
                if args[0] == "show":
                    return (planner.BILLING_OPERATOR_WORKFLOW_STEP if "ios-build.yml" in args[1]
                            else planner.SHARING_OPERATOR_GUARD * 3) if wired else "unwired"
                return self.sha
            with patch.object(planner, "comparison_base", return_value="b" * 40), \
                    patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(changed, {}, self.env)
        self.assertEqual(selected(), planner.BILLING_OPERATOR_SCOPE)
        for path in planner.BILLING_OPERATOR_PATHS:
            self.assertEqual(selected([path]), planner.BILLING_OPERATOR_SCOPE)
            for mode, status in ((":100644 100755", "M"), (":100644 120000", "T"),
                                 (":100644 000000", "D"), (":100644 100644", "R100")):
                self.assertEqual(selected(altered=(path, mode, status)), scope.FULL_SCOPE)
            if path != planner.BILLING_OPERATOR_ENTRY:
                self.assertEqual(selected(altered=(path, ":000000 100644", "A")), scope.FULL_SCOPE)
        for extra in ("NekoWidget/SharingService/src/billing-gateway.ts", "NekoWidget/SharingService/package.json",
                      "NekoWidget/SharingService/scripts/unknown.mjs", "NekoWidget/Shared/Models/Photo.swift",
                      ".github/workflows/sharing-service.yml", "NekoWidget/ci/plan-ios-ci.py"):
            self.assertEqual(selected(paths + [extra]), scope.FULL_SCOPE, extra)
        self.assertEqual(selected(wired=False), scope.FULL_SCOPE)
        self.assertEqual(selected(duplicate=True), scope.FULL_SCOPE)
        self.assertEqual(selected(paths + [paths[0]]), scope.FULL_SCOPE)

    def test_billing_operator_owning_tests_run_without_native_or_release_evidence(self):
        paths = sorted(planner.BILLING_OPERATOR_PATHS)
        self.assertEqual(planner.required_jobs(paths, planner.BILLING_OPERATOR_SCOPE), (planner.PLAN_JOB,))
        self.assertEqual(planner.required_jobs(paths + ["unknown.swift"], planner.BILLING_OPERATOR_SCOPE), planner.FULL)
        self.assertNotIn(planner.BILLING_OPERATOR_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError): planner.required_jobs_from_scope(planner.BILLING_OPERATOR_SCOPE)
        root = Path(__file__).resolve().parents[2]
        self.assertEqual((root / ".github/workflows/ios-build.yml").read_text(encoding="utf-8")
                         .count(planner.BILLING_OPERATOR_WORKFLOW_STEP), 1)
        backend = (root / ".github/workflows/sharing-service.yml").read_text(encoding="utf-8")
        self.assertEqual(backend.count(planner.SHARING_OPERATOR_GUARD), 3)
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory); (temp / "event.json").write_text("{}")
            env = dict(self.env, GITHUB_EVENT_PATH=str(temp / "event.json"),
                       GITHUB_OUTPUT=str(temp / "output"), GITHUB_STEP_SUMMARY=str(temp / "summary"))
            with patch.dict(os.environ, env), patch.object(planner, "changed_paths", return_value=paths), \
                    patch.object(planner, "runtime_scope", return_value=planner.BILLING_OPERATOR_SCOPE), \
                    patch.object(planner, "find_evidence") as lookup:
                planner.main()
            lookup.assert_not_called()
            output = dict(line.split("=", 1) for line in (temp / "output").read_text().splitlines())
            self.assertTrue(all(output[name] == "false" for name in ("build", "smoke", "sharing", "app_ui")))
            self.assertEqual(output["matrix_lanes"], "[]")

    def test_backend_orchestration_exemption_preserves_all_backend_commands(self):
        path = ".github/workflows/sharing-service.yml"
        after = (Path(__file__).resolve().parents[2] / path).read_text(encoding="utf-8")
        before = after.replace(planner.SHARING_OPERATOR_GUARD, "")
        def matches(new):
            def git(*args):
                if args[0] == "show": return before if args[1].startswith("base:") else new
                return f":100644 100644 {'c' * 40} {'d' * 40} M\0{path}\0"
            with patch.object(planner, "git", side_effect=git):
                return planner.orchestration_only([path], "base", "head")
        self.assertTrue(matches(after))
        self.assertFalse(matches(after.replace(planner.SHARING_OPERATOR_GUARD, "", 1)))
        self.assertFalse(matches(after.replace("node-version: \"22\"", "node-version: \"24\"", 1)))
        self.assertFalse(matches(after.replace("npm run typecheck", "echo skipped", 1)))
        moved_guard = after.replace(planner.SHARING_OPERATOR_GUARD, "", 1)
        moved_guard = moved_guard.replace("npm run typecheck", "npm run typecheck" + planner.SHARING_OPERATOR_GUARD, 1)
        self.assertFalse(matches(moved_guard))
        self.assertFalse(matches(after.replace('"$GITHUB_SHA"', '"$RELEASE_SOURCE_SHA"'))
                         if '"$GITHUB_SHA"' in after else matches(after + '\n      run: "$RELEASE_SOURCE_SHA"\n'))
        self.assertFalse(matches(after.replace("needs.plan.outputs.scope == 'billing-private-service-v2'", "false")))
        self.assertFalse(matches(after + "\n  unreviewed-job:\n    run: deploy\n"))

    def test_policy_docs_require_closed_paths_modes_and_owning_workflow_check(self):
        paths = ["docs/privacy/index.html", "docs/support/index.html", "handoffs/policy.md"]
        def selected(changed=paths, *, mode=":100644 100644", status="M", wired=True, duplicate=False):
            def git(*args):
                if args[0] == "diff":
                    raw_paths = [changed[0]] * len(changed) if duplicate else changed
                    return "".join(f"{mode} {'c' * 40} {'d' * 40} {status}\0{path}\0" for path in raw_paths)
                if args[0] == "show":
                    return planner.POLICY_DOC_WORKFLOW_STEP if wired else "no HTML check"
                return self.sha
            with patch.object(planner, "comparison_base", return_value="b" * 40), \
                    patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(changed, {}, self.env)
        for path in planner.POLICY_DOC_PATHS:
            self.assertEqual(selected([path]), planner.POLICY_DOC_SCOPE)
        self.assertEqual(selected(), planner.POLICY_DOC_SCOPE)
        for extra in ("docs/unknown.html", "docs/privacy/script.js", "NekoWidget/ci/plan-ios-ci.py",
                      ".github/workflows/ios-build.yml", "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                      "NekoWidget/NekoWidget/Views/HomeView.swift", "NekoWidget/Config.xcconfig"):
            self.assertEqual(selected(paths + [extra]), scope.FULL_SCOPE, extra)
        for mode, status in ((":000000 100644", "A"), (":100644 000000", "D"),
                             (":100644 100755", "M"), (":100644 120000", "T"),
                             (":100644 100644", "R100")):
            self.assertEqual(selected(mode=mode, status=status), scope.FULL_SCOPE)
        self.assertEqual(selected(wired=False), scope.FULL_SCOPE)
        self.assertEqual(selected(duplicate=True), scope.FULL_SCOPE)
        self.assertEqual(selected(paths + [paths[0]]), scope.FULL_SCOPE)

    def test_policy_doc_success_cannot_become_native_release_evidence(self):
        paths = ["docs/privacy/index.html"]
        self.assertEqual(planner.required_jobs(paths, planner.POLICY_DOC_SCOPE), (planner.PLAN_JOB,))
        self.assertEqual(planner.required_jobs(paths + ["unknown.swift"], planner.POLICY_DOC_SCOPE), planner.FULL)
        self.assertNotIn(planner.POLICY_DOC_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError):
            planner.required_jobs_from_scope(planner.POLICY_DOC_SCOPE)
        workflow = Path(__file__).resolve().parents[2] / ".github/workflows/ios-build.yml"
        self.assertEqual(workflow.read_text(encoding="utf-8").count(planner.POLICY_DOC_WORKFLOW_STEP), 1)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "event.json").write_text("{}")
            env = dict(self.env, GITHUB_EVENT_PATH=str(root / "event.json"),
                       GITHUB_OUTPUT=str(root / "output"), GITHUB_STEP_SUMMARY=str(root / "summary"))
            with patch.dict(os.environ, env), patch.object(planner, "changed_paths", return_value=paths), \
                    patch.object(planner, "runtime_scope", return_value=planner.POLICY_DOC_SCOPE), \
                    patch.object(planner, "find_evidence") as lookup:
                planner.main()
            lookup.assert_not_called()
            output = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            self.assertTrue(all(output[name] == "false" for name in ("build", "smoke", "sharing", "app_ui")))
            self.assertEqual(output["matrix_lanes"], "[]")

    def test_daily_tool_membership_requires_exact_sources_and_owning_ui(self):
        paths = sorted(scope.MEMBERSHIP_TOOLS_PATHS)
        self.assertEqual(len(paths), 15)
        self.assertEqual(len(scope.MEMBERSHIP_TOOLS_TESTS), 5)
        changes = {path: ("before " + path, "after " + path) for path in paths}
        declarations = "final class SoloMemoriesUITests: XCTestCase {\n" + "".join(
            "    func " + name.rsplit("/", 1)[1] + "() {}\n" for name in scope.MEMBERSHIP_TOOLS_TESTS) + "}\n"
        changes[scope.MEMORY_TEST_PATH] = ("old tests", declarations)
        bindings = {path: list(map(scope.source_digest, pair)) for path, pair in changes.items()}
        with patch.object(scope, "MEMBERSHIP_TOOLS_DIGESTS", bindings):
            self.assertEqual(scope.select_scope(changes), scope.MEMBERSHIP_TOOLS_SCOPE)
            for path in paths:
                missing = dict(changes); del missing[path]
                self.assertNotEqual(scope.select_scope(missing), scope.MEMBERSHIP_TOOLS_SCOPE)
                for side in (0, 1):
                    changed = dict(changes); pair = list(changed[path]); pair[side] += " changed"
                    changed[path] = tuple(pair)
                    self.assertEqual(scope.select_scope(changed), scope.FULL_SCOPE, (path, side))
            for extra in ("NekoWidget/NekoWidget/Info.plist", ".github/workflows/ios-build.yml",
                          "NekoWidget/NekoWidget.xcodeproj/project.pbxproj", "NekoWidget/ci/ios_ci_scope.py",
                          "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift"):
                self.assertEqual(scope.select_scope(dict(changes, **{extra: ("old", "new")})), scope.FULL_SCOPE)
            for test in scope.MEMBERSHIP_TOOLS_TESTS:
                changed = copy.deepcopy(changes)
                changed[scope.MEMORY_TEST_PATH] = ("old tests", declarations.replace(
                    "    func " + test.rsplit("/", 1)[1], "    // func " + test.rsplit("/", 1)[1]))
                rebound = dict(bindings); rebound[scope.MEMORY_TEST_PATH] = list(map(scope.source_digest, changed[scope.MEMORY_TEST_PATH]))
                with patch.object(scope, "MEMBERSHIP_TOOLS_DIGESTS", rebound):
                    self.assertEqual(scope.select_scope(changed), scope.FULL_SCOPE)
            base = "b" * 40
            def selected(modes=None, status="M", extra_raw=""):
                modes = modes or {}
                def git(*args):
                    if args[0] == "diff":
                        return "".join(f"{modes.get(path, ':100644 100644')} {'c' * 40} {'d' * 40} {status}\0{path}\0"
                                       for path in paths) + extra_raw
                    if args[0] == "show":
                        ref, path = args[1].split(":", 1)
                        return changes[path][0 if ref == base else 1]
                    return self.sha
                with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                    return planner.runtime_scope(paths, {}, self.env)
            self.assertEqual(selected(), scope.MEMBERSHIP_TOOLS_SCOPE)
            for path in paths:
                for modes in (":100644 100755", ":100644 120000", ":000000 100644", ":100644 000000"):
                    self.assertEqual(selected({path: modes}), scope.FULL_SCOPE)
            for status in ("A", "D", "T", "R100", "C100"):
                self.assertEqual(selected(status=status), scope.FULL_SCOPE)
            self.assertEqual(selected(extra_raw=f":100644 100644 {'c' * 40} {'d' * 40} M\0{paths[0]}\0"), scope.FULL_SCOPE)
        expected = (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.MEMBERSHIP_TOOLS_SCOPE)
        self.assertEqual(planner.required_jobs(paths, scope.MEMBERSHIP_TOOLS_SCOPE), expected)
        self.assertEqual(scope.lanes(scope.MEMBERSHIP_TOOLS_SCOPE), ("runtime", "app-ui"))
        self.assertEqual(scope.smoke_tests(scope.MEMBERSHIP_TOOLS_SCOPE),
                         ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",
                          "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary"))
        self.assertEqual(scope.lane_tests(scope.MEMBERSHIP_TOOLS_SCOPE, "app-ui"), scope.MEMBERSHIP_TOOLS_TESTS)
        for gallery in scope.LANES[2:]:
            with self.assertRaises(ValueError): scope.lane_tests(scope.MEMBERSHIP_TOOLS_SCOPE, gallery)
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"} for name in expected]
        self.assertTrue(planner.covers_jobs(jobs, expected, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, planner.FULL, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, expected, "d" * 40))

    def test_tool_cat_autofill_requires_complete_frozen_sources_and_six_real_tests(self):
        paths = sorted(scope.TOOL_CAT_AUTOFILL_PATHS)
        self.assertEqual(len(paths), 9)
        self.assertEqual(len(scope.TOOL_CAT_AUTOFILL_TESTS), 6)
        self.assertEqual(len(set(scope.TOOL_CAT_AUTOFILL_TESTS)), 6)
        changes = {path: ("before " + path, "after " + path) for path in paths}
        declarations = "final class SoloMemoriesUITests: XCTestCase {\n" + "".join(
            "    func " + name.rsplit("/", 1)[1] + "() {}\n" for name in scope.TOOL_CAT_AUTOFILL_TESTS) + "}\n"
        changes[scope.MEMORY_TEST_PATH] = ("old tests", declarations)
        bindings = {path: list(map(scope.source_digest, pair)) for path, pair in changes.items()}
        with patch.object(scope, "TOOL_CAT_AUTOFILL_DIGESTS", bindings):
            self.assertEqual(scope.select_scope(changes), scope.TOOL_CAT_AUTOFILL_SCOPE)
            for path in paths:
                missing = dict(changes); del missing[path]
                self.assertNotEqual(scope.select_scope(missing), scope.TOOL_CAT_AUTOFILL_SCOPE)
                for side in (0, 1):
                    changed = dict(changes); pair = list(changed[path]); pair[side] += " changed"
                    changed[path] = tuple(pair)
                    self.assertEqual(scope.select_scope(changed), scope.FULL_SCOPE, (path, side))
            for extra in ("NekoWidget/Shared/Storage/AtomicJSON.swift", ".github/workflows/ios-build.yml",
                          "NekoWidget/NekoWidget.xcodeproj/project.pbxproj", "NekoWidget/ci/ios_ci_scope.py"):
                self.assertEqual(scope.select_scope(dict(changes, **{extra: ("old", "new")})), scope.FULL_SCOPE)
            # A hash declaration cannot turn absent/commented tests into evidence.
            for test in scope.TOOL_CAT_AUTOFILL_TESTS:
                changed = copy.deepcopy(changes)
                changed[scope.MEMORY_TEST_PATH] = ("old tests", declarations.replace(
                    "    func " + test.rsplit("/", 1)[1], "    // func " + test.rsplit("/", 1)[1]))
                rebound = dict(bindings); rebound[scope.MEMORY_TEST_PATH] = list(map(scope.source_digest, changed[scope.MEMORY_TEST_PATH]))
                with patch.object(scope, "TOOL_CAT_AUTOFILL_DIGESTS", rebound):
                    self.assertEqual(scope.select_scope(changed), scope.FULL_SCOPE)
            base = "b" * 40
            def selected(modes=None, status="M", extras=""):
                modes = modes or {}
                def git(*args):
                    if args[0] == "diff":
                        return "".join(f"{modes.get(path, ':100644 100644')} {'c' * 40} {'d' * 40} {status}\0{path}\0"
                                       for path in paths) + extras
                    if args[0] == "show":
                        ref, path = args[1].split(":", 1)
                        return changes[path][0 if ref == base else 1]
                    return self.sha
                with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                    return planner.runtime_scope(paths, {}, self.env)
            self.assertEqual(selected(), scope.TOOL_CAT_AUTOFILL_SCOPE)
            for path in paths:
                for modes in (":100644 100755", ":100644 120000", ":000000 100644", ":100644 000000"):
                    self.assertEqual(selected({path: modes}), scope.FULL_SCOPE)
            for status in ("A", "D", "T", "R100", "C100"):
                self.assertEqual(selected(status=status), scope.FULL_SCOPE)
            self.assertEqual(selected(extras=f":100644 100644 {'c' * 40} {'d' * 40} M\0{paths[0]}\0"), scope.FULL_SCOPE)
        expected = (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.TOOL_CAT_AUTOFILL_SCOPE)
        self.assertEqual(planner.required_jobs(paths, scope.TOOL_CAT_AUTOFILL_SCOPE), expected)
        self.assertEqual(scope.lanes(scope.TOOL_CAT_AUTOFILL_SCOPE), ("runtime", "app-ui"))
        self.assertEqual(scope.smoke_tests(scope.TOOL_CAT_AUTOFILL_SCOPE),
                         ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",
                          "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary"))
        self.assertEqual(scope.lane_tests(scope.TOOL_CAT_AUTOFILL_SCOPE, "app-ui"), scope.TOOL_CAT_AUTOFILL_TESTS)
        for gallery in scope.LANES[2:]:
            with self.assertRaises(ValueError):
                scope.lane_tests(scope.TOOL_CAT_AUTOFILL_SCOPE, gallery)
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"} for name in expected]
        self.assertTrue(planner.covers_jobs(jobs, expected, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, planner.FULL, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, expected, "d" * 40))
        for index in range(len(jobs)):
            for conclusion in ("failure", "skipped", "cancelled", None):
                wrong = copy.deepcopy(jobs); wrong[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(wrong, expected, self.sha))

    def test_window_hub_requires_frozen_product_and_complete_ci_boundary(self):
        product = dict(scope.WINDOW_HUB_BLOBS)
        pairs = {path: ("before " + path, "after " + path) for path in scope.WINDOW_HUB_COMPANIONS}
        selector = "NekoWidget/ci/plan-ios-ci.py"
        empty = "WINDOW_HUB_COMPANION_DIGESTS = {}\n"
        pairs[selector] = (pairs[selector][0], empty + "# reviewed selector\n")
        bindings = {path: list(map(scope.source_digest, pair)) for path, pair in pairs.items()}
        literal = "WINDOW_HUB_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        pairs[selector] = (pairs[selector][0], pairs[selector][1].replace(empty, literal))
        rows = {path: f":100644 100644 {before} {after} M" for path, (before, after) in product.items()}
        rows.update({path: f":100644 100644 {'c' * 40} {'d' * 40} M" for path in pairs})

        def verify(candidate, paths=None, extra="", mutated=None):
            def git(*args):
                if args[0] == "diff":
                    return "".join(header + "\0" + path + "\0" for path, header in candidate.items()) + extra
                if args[0] == "show":
                    ref, path = args[1].split(":", 1)
                    return pairs[path][int(ref == self.sha)] + ("# changed" if path == mutated else "")
                raise AssertionError(args)
            with patch.object(planner, "git", side_effect=git), \
                    patch.object(planner, "WINDOW_HUB_COMPANION_DIGESTS", bindings):
                return planner.window_hub_only(list(candidate) if paths is None else paths, "b" * 40, self.sha)

        self.assertTrue(verify(rows))
        self.assertTrue(verify({path: rows[path] for path in product}))
        with patch.object(planner, "comparison_base", return_value="b" * 40), \
                patch.object(planner, "window_hub_only", return_value=True):
            self.assertEqual(planner.runtime_scope(list(rows), {}, self.env), scope.WINDOW_HUB_SCOPE)
        expected = (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.WINDOW_HUB_SCOPE)
        self.assertEqual(planner.required_jobs(list(rows), scope.WINDOW_HUB_SCOPE), expected)
        self.assertEqual(scope.lanes(scope.WINDOW_HUB_SCOPE), ("runtime", "app-ui"))
        source = (Path(__file__).resolve().parents[2] / scope.MEMORY_TEST_PATH).read_text(encoding="utf-8")
        self.assertEqual(scope.native_tests(scope.WINDOW_HUB_SCOPE), scope.diagnostic_tests(
            "OfficialWindowUITests", ",".join(test.rsplit("/", 1)[-1] for test in scope.WINDOW_HUB_TESTS), source))
        self.assertEqual(len(scope.WINDOW_HUB_TESTS), 3)
        for path in rows:
            missing = dict(rows)
            del missing[path]
            self.assertFalse(verify(missing), path)
            for mode in ("100755", "120000", "160000"):
                changed = dict(rows)
                changed[path] = changed[path].replace("100644", mode)
                self.assertFalse(verify(changed), (path, mode))
        for path, (before, after) in product.items():
            for blob in (before, after):
                changed = dict(rows)
                changed[path] = changed[path].replace(blob, "e" * 40)
                self.assertFalse(verify(changed), path)
        for path in pairs:
            self.assertFalse(verify(rows, mutated=path), path)
        for unknown in ("NekoWidget/Shared/Models/Photo.swift", ".github/workflows/ios-build.yml",
                        "NekoWidget/NekoWidget.xcodeproj/project.pbxproj"):
            self.assertFalse(verify(dict(rows, **{unknown: f":000000 100644 {'0' * 40} {'e' * 40} A"})))
        first = next(iter(rows))
        self.assertFalse(verify(rows, paths=list(rows) + [first]))
        self.assertFalse(verify(rows, extra=rows[first] + "\0" + first + "\0"))
        handoff = dict(rows, **{"handoffs/window-hub.md": f":000000 100644 {'0' * 40} {'e' * 40} A"})
        self.assertTrue(verify(handoff))
        handoff["handoffs/window-hub.md"] = handoff["handoffs/window-hub.md"].replace("100644", "120000")
        self.assertFalse(verify(handoff))

    def test_tools_hub_requires_exact_pixels_sources_and_complete_companions(self):
        product = dict(scope.TOOLS_HUB_BLOBS)
        before_after = {path: ("before " + path, "after " + path)
                        for path in scope.TOOLS_HUB_COMPANIONS}
        selector = "NekoWidget/ci/plan-ios-ci.py"
        empty = "TOOLS_HUB_COMPANION_DIGESTS = {}\n"
        before_after[selector] = (before_after[selector][0], empty + "# reviewed logic\n")
        bindings = {path: list(map(scope.source_digest, pair)) for path, pair in before_after.items()}
        literal = "TOOLS_HUB_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        before_after[selector] = (before_after[selector][0], before_after[selector][1].replace(empty, literal))
        def records(companions=False):
            rows = {}
            for path, (old, new) in product.items():
                modes, status = (":000000 100644", "A") if old == "0" * 40 else (":100644 100644", "M")
                rows[path] = f"{modes} {old} {new} {status}"
            if companions:
                rows.update({path: f":100644 100644 {'c' * 40} {'d' * 40} M" for path in before_after})
            return rows
        def select(rows, sources=None, raw_extra="", mutate_companion=False):
            def git(*args):
                if args[0] == "diff":
                    return "".join(header + "\0" + path + "\0" for path, header in rows.items()) + raw_extra
                if args[0] == "show":
                    ref, path = args[1].split(":", 1)
                    return before_after[path][int(ref == self.sha)] + ("# changed" if mutate_companion else "")
                raise AssertionError(args)
            with patch.object(planner, "comparison_base", return_value="b" * 40), \
                    patch.object(planner, "git", side_effect=git), \
                    patch.object(planner, "TOOLS_HUB_COMPANION_DIGESTS", bindings):
                return planner.runtime_scope(list(rows) if sources is None else sources, {}, self.env)
        self.assertEqual(select(records()), scope.TOOLS_HUB_SCOPE)
        self.assertEqual(select(records(True)), scope.TOOLS_HUB_SCOPE)
        expected = (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.TOOLS_HUB_SCOPE)
        self.assertEqual(planner.required_jobs(list(records(True)), scope.TOOLS_HUB_SCOPE), expected)
        self.assertEqual(scope.lanes(scope.TOOLS_HUB_SCOPE), ("runtime", "app-ui"))
        self.assertEqual(len(scope.native_tests(scope.TOOLS_HUB_SCOPE)), 3)
        self.assertIn("NekoWidgetUITests/SoloMemoriesUITests/testToolsReplaceAlbumShowcaseEntryAtStandardAndLargeText",
                      scope.native_tests(scope.TOOLS_HUB_SCOPE))
        for path in product:
            changed = records()
            changed[path] = changed[path].replace(product[path][1], "e" * 40)
            self.assertEqual(select(changed), scope.FULL_SCOPE, path)
            missing = records()
            del missing[path]
            self.assertEqual(select(missing), scope.FULL_SCOPE, path)
        image = next(path for path in product if path.endswith(".png"))
        for mode in ("100755", "120000", "160000"):
            changed = records()
            changed[image] = changed[image].replace("100644", mode)
            self.assertEqual(select(changed), scope.FULL_SCOPE)
        for companion in before_after:
            changed = records(True)
            del changed[companion]
            self.assertEqual(select(changed), scope.FULL_SCOPE)
        self.assertEqual(select(records(True), mutate_companion=True), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/Shared/Models/Photo.swift", "NekoWidget/NekoWidget.xcodeproj/project.pbxproj",
                        ".github/workflows/ios.yml", "NekoWidget/NekoWidget/Assets.xcassets/Other.imageset/a.png"):
            changed = records()
            changed[unknown] = f":000000 100644 {'0' * 40} {'e' * 40} A"
            self.assertEqual(select(changed), scope.FULL_SCOPE)
        self.assertEqual(select(records(), sources=list(records()) + [image]), scope.FULL_SCOPE)
        self.assertEqual(select(records(), raw_extra=records()[image] + "\0" + image + "\0"), scope.FULL_SCOPE)
        handoff = records()
        handoff["handoffs/tools.md"] = f":000000 100644 {'0' * 40} {'d' * 40} A"
        self.assertEqual(select(handoff), scope.TOOLS_HUB_SCOPE)
        handoff["handoffs/tools.md"] = f":000000 120000 {'0' * 40} {'d' * 40} A"
        self.assertEqual(select(handoff), scope.FULL_SCOPE)

    @staticmethod
    def jpeg_changes(companions=True, profile="JPEG"):
        workflow = getattr(planner, profile + "_WORKFLOW")
        companion_paths = getattr(planner, profile + "_COMPANION_PATHS")
        product = ("NekoWidget/PreservationImageValidator/src/provider.ts" if profile == "JPEG"
                   else "NekoWidget/PreservationService/src/index.ts")
        changes = {product: ("", "reviewed provider"),
                   workflow: ("", "name: " + getattr(planner, profile + "_JOB") + "\ntimeout-minutes: 5\n")}
        if companions:
            changes.update({path: ("before " + path, "after " + path) for path in companion_paths})
            selector = "NekoWidget/ci/plan-ios-ci.py"
            empty = profile + "_COMPANION_DIGESTS = {}\n"
            changes[selector] = (changes[selector][0], empty + "# complete reviewed selector\n")
            bindings = {path: list(map(scope.source_digest, changes[path])) for path in companion_paths}
            literal = profile + "_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
            changes[selector] = (changes[selector][0], changes[selector][1].replace(empty, literal))
        else:
            bindings = {}
        return changes, bindings

    def test_private_billing_backend_requires_all_frozen_dependencies_and_workflows(self):
        path = next(iter(planner.BILLING_PATHS))
        changed = [path]
        self.assertEqual(planner.BILLING_SCOPE, "billing-private-service-v2")
        self.assertNotIn(planner.BILLING_JOB, planner.required_jobs(list(planner.BILLING_PATHS), planner.BILLING_SCOPE))
        snapshot = dict(planner.BILLING_REVIEWED_TREES)
        def frozen_git(*args):
            if args[0] == "rev-parse":
                return snapshot[args[1].split(":NekoWidget/", 1)[1]]
            if args[0] == "show":
                return "frozen preservation workflow"
            raise AssertionError(args)
        digest = scope.source_digest("frozen preservation workflow")
        with patch.object(planner, "git", side_effect=frozen_git), \
                patch.object(planner, "PRESERVATION_WORKFLOW_DIGEST", digest), \
                patch.object(planner, "backend_only", return_value=True) as boundary:
            self.assertTrue(planner.billing_backend_only(changed, "base", "head"))
            self.assertEqual(boundary.call_args.kwargs["binding_name"], "BILLING_COMPANION_DIGESTS")
            for dependency in planner.BILLING_REVIEWED_TREES:
                wrong = dict(planner.BILLING_REVIEWED_TREES); wrong[dependency] = "0" * 40
                with patch.object(planner, "BILLING_REVIEWED_TREES", wrong):
                    self.assertFalse(planner.billing_backend_only(changed, "base", "head"))
            with patch.object(planner, "PRESERVATION_WORKFLOW_DIGEST", "wrong"):
                self.assertFalse(planner.billing_backend_only(changed, "base", "head"))
        self.assertEqual(planner.required_jobs(changed, planner.BILLING_SCOPE),
                         (planner.BILLING_CALLER_JOB, planner.PRESERVATION_JOB))
        for unknown in ("NekoWidget/NekoWidget/Views/PhotoView.swift", "NekoWidget/Config.xcconfig",
                        "NekoWidget/BillingVerificationService/src/unknown.ts"):
            self.assertFalse(planner.billing_paths_only(changed + [unknown]))
            self.assertEqual(planner.required_jobs(changed + [unknown], planner.BILLING_SCOPE), planner.FULL)
        self.assertFalse(planner.billing_paths_only(changed + [next(iter(planner.BILLING_COMPANION_PATHS))]))
        with self.assertRaises(ValueError):
            planner.required_jobs_from_scope(planner.BILLING_SCOPE)

    def test_internal_release_preparation_is_frozen_and_never_native_evidence(self):
        changed = {path: ("before " + path, "after " + path)
                   for path in planner.RELEASE_PREP_PATHS}
        changed[planner.RELEASE_PREP_WORKFLOW] = ("old CI", "frozen plan CI")
        product_digests = {path: list(map(scope.source_digest, pair))
                           for path, pair in changed.items() if path in planner.RELEASE_PREP_PATHS}
        workflow_digest = scope.source_digest("frozen plan CI")
        def select(candidate, ancestor=True):
            def git(*args):
                if args[0] == "merge-base":
                    if not ancestor:
                        raise subprocess.CalledProcessError(1, "git")
                    return ""
                if args[0] == "show":
                    ref, path = args[1].split(":", 1)
                    return candidate[path][1 if ref == self.sha else 0]
                if args[0] == "diff":
                    return "".join(f":100644 100644 {'c' * 40} {'d' * 40} M\0{path}\0"
                                   for path in sorted(candidate))
                raise AssertionError(args)
            with patch.object(planner, "comparison_base", return_value="base"), \
                    patch.object(planner, "git", side_effect=git), \
                    patch.object(planner, "RELEASE_PREP_PRODUCTS", product_digests), \
                    patch.object(planner, "RELEASE_PREP_WORKFLOW_DIGEST", workflow_digest):
                return planner.runtime_scope(sorted(candidate), {}, self.env)
        self.assertEqual(select(changed), planner.RELEASE_PREP_SCOPE)
        self.assertEqual(planner.required_jobs(sorted(changed), planner.RELEASE_PREP_SCOPE),
                         (planner.PLAN_JOB, planner.RELEASE_PREP_BACKEND_PLAN_JOB))
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/sharing-service.yml").read_text(encoding="utf-8")
        guarded = "if: needs.plan.outputs.scope != 'billing-private-service-v2' && needs.plan.outputs.scope != 'internal-billing-release-prep-v1'"
        self.assertEqual(workflow.count(guarded), 3)
        for path in planner.RELEASE_PREP_PATHS | {planner.RELEASE_PREP_WORKFLOW}:
            mutated = dict(changed); mutated[path] = (mutated[path][0], mutated[path][1] + " drift")
            self.assertEqual(select(mutated), scope.FULL_SCOPE)
        for unknown in ("NekoWidget/NekoWidget/Views/SettingsView.swift", "NekoWidget/Config.xcconfig",
                        "NekoWidget/Shared/Models/Photo.swift", "NekoWidget/NekoWidget/Info.plist"):
            mixed = dict(changed); mixed[unknown] = ("old", "new")
            self.assertEqual(select(mixed), scope.FULL_SCOPE)
        mixed = dict(changed); mixed[next(iter(planner.RELEASE_PREP_COMPANION_PATHS))] = ("old", "new")
        self.assertEqual(select(mixed), scope.FULL_SCOPE)
        self.assertEqual(select(changed, ancestor=False), scope.FULL_SCOPE)
        with self.assertRaises(ValueError):
            planner.required_jobs_from_scope(planner.RELEASE_PREP_SCOPE)

    def test_preservation_backend_requires_frozen_introduction_and_rejects_mixed_or_unsafe_inputs(self):
        original, bindings = self.jpeg_changes(profile="PRESERVATION")
        migration = "NekoWidget/PreservationService/migrations/0004_upload_owner_index.sql"
        original[migration] = ("", "CREATE INDEX pa_upload_owner_bytes ON pa_uploads(owner_id,reserved_bytes);\n")
        workflow_digest = scope.source_digest(original[planner.PRESERVATION_WORKFLOW][1])
        def select(changes, alter=lambda raw: raw, ancestor=True, tree_ok=True):
            def git(*args):
                if args[0] == "rev-parse" and args[1].endswith(":NekoWidget/PreservationService"):
                    return planner.PRESERVATION_REVIEWED_TREE if tree_ok else "0" * 40
                if args[0] == "merge-base":
                    if not ancestor:
                        raise subprocess.CalledProcessError(1, "git")
                    return ""
                if args[0] == "diff":
                    return alter("".join(f"{':100644 100644' if pair[0] else ':000000 100644'} "
                        f"{'c' * 40} {'d' * 40} {'M' if pair[0] else 'A'}\0{path}\0"
                        for path, pair in sorted(changes.items())))
                if args[0] == "show":
                    revision, path = args[1].split(":", 1)
                    return changes[path][1 if revision == self.sha else 0]
                raise AssertionError(args)
            with patch.object(planner, "comparison_base", return_value="b" * 40), \
                    patch.object(planner, "git", side_effect=git), \
                    patch.object(planner, "PRESERVATION_WORKFLOW_DIGEST", workflow_digest), \
                    patch.object(planner, "PRESERVATION_COMPANION_DIGESTS", bindings):
                return planner.runtime_scope(sorted(changes), {}, self.env)
        pilot_new_paths = (
            "migrations/0025_intake_control.sql", "migrations/0026_pilot_control.sql",
            "operations/pilot-plan.json", "scripts/estimate-pilot-budget.mjs",
            "src/intake-control.ts", "src/pilot-control.ts",
            "test/intake-control.test.ts", "test/pilot-control.test.ts", "test/pilot-wiring.test.ts",
        )
        self.assertEqual(len(planner.PRESERVATION_PATHS), 175)
        self.assertEqual(planner.PRESERVATION_SCOPE, "preservation-service-v26")
        self.assertIn("NekoWidget/PreservationService/migrations/0029_general_admission.sql", planner.PRESERVATION_PATHS)
        self.assertIn("NekoWidget/PreservationService/migrations/0030_general_cost_review.sql", planner.PRESERVATION_PATHS)
        self.assertTrue(all("NekoWidget/PreservationService/" + path in planner.PRESERVATION_PATHS
                            for path in pilot_new_paths))
        self.assertIn("NekoWidget/PreservationService/src/owner-deletion-worker.ts", planner.PRESERVATION_PATHS)
        self.assertEqual(select(original), planner.PRESERVATION_SCOPE)
        plain, _ = self.jpeg_changes(companions=False, profile="PRESERVATION")
        self.assertEqual(select({migration: original[migration],
                                 planner.PRESERVATION_WORKFLOW: plain[planner.PRESERVATION_WORKFLOW]}),
                         planner.PRESERVATION_SCOPE)
        self.assertEqual(select({**plain, "handoffs/custody.md": ("", "notes")}), planner.PRESERVATION_SCOPE)
        self.assertEqual(select({**plain, "NekoWidget/PreservationService/test/key-fixture.ts": ("", "synthetic helper")}),
                         planner.PRESERVATION_SCOPE)
        for path in ("src/billing-link-protocol.ts", "src/membership-links.ts", "src/billing-authority.ts",
                     "migrations/0003_membership_links.sql", "wrangler.billing.disabled.jsonc",
                     "test/membership-links.test.ts", "test/billing-authority.test.ts",
                     "src/aws-kms-key-wrapper.ts", "test/aws-kms-key-wrapper.test.ts", "wrangler.kms.disabled.jsonc",
                     "migrations/0005_retention_ledger.sql", "src/retention-ledger.ts", "test/retention-ledger.test.ts",
                     "migrations/0006_notice_contact.sql", "migrations/0007_notice_submissions.sql",
                     "src/notice-events.ts", "src/notice-submissions.ts",
                     "test/notice-events.test.ts", "test/notice-submissions.test.ts",
                     "migrations/0017_purge_execution_claims.sql", "migrations/0018_purge_claim_lease.sql", "src/owner-purge-abort.ts",
                     "test/owner-purge-abort.test.ts", "test/purge-execution-claims.test.ts",
                     "src/owner-snapshot-codec.ts", "test/owner-snapshot-codec.test.ts"):
            self.assertEqual(select({**plain, "NekoWidget/PreservationService/" + path: ("", "reviewed addition")}),
                             planner.PRESERVATION_SCOPE)
        for path in pilot_new_paths:
            self.assertEqual(select({**plain, "NekoWidget/PreservationService/" + path: ("", "reviewed addition")}),
                             planner.PRESERVATION_SCOPE)
        self.assertEqual(select({**plain, **{"NekoWidget/PreservationService/" + path: ("", "reviewed addition")
                                            for path in pilot_new_paths}}), planner.PRESERVATION_SCOPE)
        for path in ("migrations/0019_prepared_owner_fence.sql", "migrations/0024_purge_event_delete_guard.sql",
                     "src/owner-d1-erase.ts", "src/recovery-write-lease.ts", "src/owner-cloud-erase.ts",
                     "test/owner-d1-erase.test.ts", "test/s3-purge-manifest.test.ts"):
            self.assertEqual(select({**plain, "NekoWidget/PreservationService/" + path: ("", "reviewed addition")}),
                             planner.PRESERVATION_SCOPE)
        self.assertEqual(select(original, ancestor=False), scope.FULL_SCOPE)
        # Same filenames with any different service content (including an
        # in-place sender, Queue binding, or deletion) must not use v23.
        self.assertEqual(select(original, tree_ok=False), scope.FULL_SCOPE)
        for extra in ("NekoWidget/PreservationService/src/new.ts",
                      "NekoWidget/PreservationService/src/notice-sender.ts",
                      "NekoWidget/PreservationService/src/notice-queue.ts",
                      "NekoWidget/PreservationService/src/delete-worker.ts",
                      "NekoWidget/PreservationService/migrations/0008_unknown.sql",
                      "NekoWidget/PreservationService/migrations/0004_other.sql", "NekoWidget/SharingService/src/index.ts",
                      "NekoWidget/SharingService/src/billing-auth.ts", "NekoWidget/SharingService/src/billing-entitlement.ts",
                      "NekoWidget/SharingService/migrations/0019_billing_foundation.sql",
                      "NekoWidget/NekoWidget/Services/ManagedPreservationClient.swift", "NekoWidget/Config.xcconfig",
                      scope.CI_WORKFLOW, "NekoWidget/ci/ios_ci_scope.py", "NekoWidget/ci/check-development-flow.py",
                      "NekoWidget/PreservationImageValidator/src/provider.ts", planner.JPEG_WORKFLOW):
            mixed = {**original, extra: ("old", "new")}
            self.assertEqual(select(mixed), scope.FULL_SCOPE, extra)
            self.assertEqual(planner.required_jobs(list(mixed), planner.PRESERVATION_SCOPE), planner.FULL)
        for path in planner.PRESERVATION_COMPANION_PATHS:
            missing = dict(original); del missing[path]
            self.assertEqual(select(missing), scope.FULL_SCOPE)
            for side in (0, 1):
                pair = list(original[path]); pair[side] += " unreviewed"
                self.assertEqual(select({**original, path: tuple(pair)}), scope.FULL_SCOPE)
        selector = "NekoWidget/ci/plan-ios-ci.py"
        literal = "PRESERVATION_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        for source in (original[selector][1] + literal,
                       original[selector][1].replace(literal, literal.replace(" = ", "=", 1)),
                       original[selector][1].replace(bindings[selector][0], "f" * 64)):
            self.assertEqual(select({**original, selector: (original[selector][0], source)}), scope.FULL_SCOPE)
        self.assertEqual(select({**original, planner.PRESERVATION_WORKFLOW: ("", "changed workflow")}), scope.FULL_SCOPE)
        migration_raw = f":000000 100644 {'c' * 40} {'d' * 40} A\0{migration}\0"
        for changed in (migration_raw.replace("100644", "100755"),
                        migration_raw.replace("100644", "120000"),
                        migration_raw.replace(" A\0", " D\0"),
                        migration_raw.replace(" A\0", " R100\0")):
            self.assertEqual(select(original, alter=lambda raw: raw.replace(migration_raw, changed)), scope.FULL_SCOPE)
        for transform in (lambda raw: raw.replace(":000000 100644", ":000000 100755", 1),
                          lambda raw: raw.replace(":000000 100644", ":100644 120000", 1),
                          lambda raw: raw.replace(" A\0", " D\0", 1),
                          lambda raw: raw.replace(" A\0", " R100\0", 1),
                          lambda raw: raw.replace(" M\0", " A\0", 1),
                          lambda raw: raw + raw):
            self.assertEqual(select(original, alter=transform), scope.FULL_SCOPE)

    def test_preservation_job_and_workflow_never_certify_native_or_reuse_success(self):
        changes, _ = self.jpeg_changes(profile="PRESERVATION")
        self.assertEqual(planner.required_jobs(list(changes), planner.PRESERVATION_SCOPE), (planner.PRESERVATION_JOB,))
        with patch.object(planner, "preservation_backend_only") as backend:
            self.assertEqual(planner.runtime_scope(list(changes), {},
                dict(self.env, GITHUB_EVENT_NAME="workflow_dispatch")), scope.FULL_SCOPE)
            backend.assert_not_called()
        self.assertNotIn(planner.PRESERVATION_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError):
            planner.required_jobs_from_scope(planner.PRESERVATION_SCOPE)
        job = dict(name=planner.PRESERVATION_JOB, head_sha=self.sha, status="completed", conclusion="success")
        self.assertFalse(planner.covers_jobs([job], planner.FULL, self.sha))
        self.assertFalse(planner.covers_jobs([job], (planner.JPEG_JOB,), self.sha))
        self.assertFalse(planner.covers_jobs(self.jobs, (planner.PRESERVATION_JOB,), self.sha))
        workflow = (Path(__file__).resolve().parents[2] / planner.PRESERVATION_WORKFLOW).read_text(encoding="utf-8")
        for required in ("name: " + planner.PRESERVATION_JOB, "runs-on: ubuntu-24.04", "timeout-minutes: 5",
                         'node-version: "22.17.0"', "npm ci --ignore-scripts --legacy-peer-deps",
                         "npm run typecheck", "npm test", "working-directory: NekoWidget/PreservationService"):
            self.assertIn(required, workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertIn('"NekoWidget/SharingService/src/**"', workflow)
        self.assertIn('"NekoWidget/SharingService/migrations/**"', workflow)
        self.assertIn('wrangler deploy --dry-run --config wrangler.billing.disabled.jsonc', workflow)
        self.assertIn('--autoconfig=false --experimental-provision=false --experimental-auto-create=false', workflow)
        self.assertNotIn("--remote", workflow)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "event.json").write_text("{}")
            env = dict(self.env, GITHUB_EVENT_PATH=str(root / "event.json"),
                       GITHUB_OUTPUT=str(root / "output"), GITHUB_STEP_SUMMARY=str(root / "summary"))
            with patch.dict(os.environ, env), patch.object(planner, "changed_paths", return_value=list(changes)), \
                    patch.object(planner, "runtime_scope", return_value=planner.PRESERVATION_SCOPE), \
                    patch.object(planner, "find_evidence") as lookup, patch("sys.stdout", new_callable=io.StringIO) as output:
                planner.main()
            lookup.assert_not_called()
            values = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            self.assertTrue(all(values[name] == "false" for name in ("build", "smoke", "sharing", "app_ui")))
            self.assertEqual(values["matrix_lanes"], "[]")
            evidence = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
            self.assertEqual(evidence["required_jobs"], [planner.PRESERVATION_JOB])
            self.assertIsNone(evidence["evidence_run_id"])
            self.assertIn(planner.PRESERVATION_WORKFLOW, (root / "summary").read_text())

    def test_jpeg_backend_requires_exact_paths_modes_workflow_and_frozen_companions(self):
        self.assertEqual(planner.JPEG_SCOPE, "preservation-image-validator-v3")
        self.assertEqual(planner.JPEG_JOB_TIMEOUT_MINUTES, 10)
        self.assertEqual(len(planner.JPEG_PATHS), 25)
        original, bindings = self.jpeg_changes()
        workflow_digest = scope.source_digest(original[planner.JPEG_WORKFLOW][1])
        def select(changes, altered_raw=None, ancestor=True, base="b" * 40):
            paths = sorted(changes)
            raw = "".join(f"{':100644 100644' if pair[0] else ':000000 100644'} "
                          f"{'c' * 40} {'d' * 40} {'M' if pair[0] else 'A'}\0{path}\0"
                          for path, pair in sorted(changes.items()))
            def git(*args):
                if args[0] == "merge-base":
                    if not ancestor:
                        raise subprocess.CalledProcessError(1, "git")
                    return ""
                if args[0] == "diff":
                    return altered_raw(raw) if altered_raw else raw
                if args[0] == "show":
                    revision, path = args[1].split(":", 1)
                    return changes[path][1 if revision == self.sha else 0]
                raise AssertionError(args)
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git), \
                    patch.object(planner, "JPEG_WORKFLOW_DIGEST", workflow_digest), \
                    patch.object(planner, "JPEG_COMPANION_DIGESTS", bindings):
                return planner.runtime_scope(paths, {}, self.env)
        self.assertEqual(select(original), planner.JPEG_SCOPE)
        plain, _ = self.jpeg_changes(companions=False)
        self.assertEqual(select(plain), planner.JPEG_SCOPE)
        for name in ("Dockerfile", "wrangler.container.disabled.jsonc", "src/container-worker.mjs",
                     "src/http-server.ts", "src/start-server.ts", "test/http-server.test.mjs",
                     "test/container-probe.mjs", "src/runtime-budget.mjs", "test/runtime-budget.test.mjs"):
            addition = "NekoWidget/PreservationImageValidator/" + name
            self.assertEqual(select({**plain, addition: ("", "reviewed container addition")}), planner.JPEG_SCOPE)
        self.assertEqual(select({**plain, "handoffs/jpeg.md": ("", "read-only notes")}), planner.JPEG_SCOPE)
        self.assertEqual(select(original, ancestor=False), scope.FULL_SCOPE)
        self.assertEqual(select(original, base=None), scope.FULL_SCOPE)  # manual iOS workflow
        selector = "NekoWidget/ci/plan-ios-ci.py"
        literal = "JPEG_COMPANION_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        for source in (original[selector][1] + literal,
                       original[selector][1].replace(literal, literal.replace(" = ", "=", 1)),
                       original[selector][1].replace(bindings[selector][0], "f" * 64)):
            self.assertEqual(select({**original, selector: (original[selector][0], source)}), scope.FULL_SCOPE)
        for extra in ("NekoWidget/PreservationImageValidator/src/new.ts", "NekoWidget/PreservationService/src/index.ts",
                      "NekoWidget/NekoWidget/Views/SettingsView.swift", "NekoWidget/Config.xcconfig",
                      scope.CI_WORKFLOW, "NekoWidget/ci/ios_ci_scope.py", "NekoWidget/ci/check-development-flow.py"):
            mixed = {**original, extra: ("old", "new")}
            self.assertEqual(select(mixed), scope.FULL_SCOPE, extra)
            self.assertEqual(planner.required_jobs(list(mixed), planner.JPEG_SCOPE), planner.FULL)
        for path in planner.JPEG_COMPANION_PATHS | {planner.JPEG_WORKFLOW}:
            for side in (0, 1):
                if path == planner.JPEG_WORKFLOW and side == 0:
                    continue
                changed = list(original[path]); changed[side] += " unreviewed"
                self.assertEqual(select({**original, path: tuple(changed)}), scope.FULL_SCOPE, path)
        for path in planner.JPEG_COMPANION_PATHS:
            missing = dict(original); del missing[path]
            self.assertEqual(select(missing), scope.FULL_SCOPE)
        for transform in (lambda raw: raw.replace(":000000 100644", ":000000 100755", 1),
                          lambda raw: raw.replace(":000000 100644", ":100644 120000", 1),
                          lambda raw: raw.replace(" A\0", " D\0", 1),
                          lambda raw: raw.replace(" A\0", " R100\0", 1),
                          lambda raw: raw.replace(" M\0", " A\0", 1),
                          lambda raw: raw + raw.split("\0", 2)[0] + "\0" + raw.split("\0", 2)[1] + "\0"):
            self.assertEqual(select(original, altered_raw=transform), scope.FULL_SCOPE)

    def test_jpeg_job_is_required_but_never_ios_release_or_reused_evidence(self):
        changes, _ = self.jpeg_changes()
        self.assertEqual(planner.required_jobs(list(changes), planner.JPEG_SCOPE), (planner.JPEG_JOB,))
        with patch.object(planner, "jpeg_backend_only") as backend:
            self.assertEqual(planner.runtime_scope(list(changes), {},
                dict(self.env, GITHUB_EVENT_NAME="workflow_dispatch")), scope.FULL_SCOPE)
            backend.assert_not_called()
        self.assertNotIn(planner.JPEG_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError):
            planner.required_jobs_from_scope(planner.JPEG_SCOPE)
        node_job = dict(name=planner.JPEG_JOB, head_sha=self.sha, status="completed", conclusion="success")
        self.assertFalse(planner.covers_jobs([node_job], planner.FULL, self.sha))
        self.assertFalse(planner.covers_jobs(self.jobs, (planner.JPEG_JOB,), self.sha))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "event.json").write_text("{}")
            env = dict(self.env, GITHUB_EVENT_PATH=str(root / "event.json"),
                       GITHUB_OUTPUT=str(root / "output"), GITHUB_STEP_SUMMARY=str(root / "summary"))
            with patch.dict(os.environ, env), patch.object(planner, "changed_paths", return_value=list(changes)), \
                    patch.object(planner, "runtime_scope", return_value=planner.JPEG_SCOPE), \
                    patch.object(planner, "find_evidence") as lookup, patch("sys.stdout", new_callable=io.StringIO) as output:
                planner.main()
            lookup.assert_not_called()
            values = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            self.assertTrue(all(values[name] == "false" for name in ("build", "smoke", "sharing", "app_ui")))
            self.assertEqual(values["matrix_lanes"], "[]")
            evidence = json.loads(output.getvalue().split("IOS_CI_PLAN_JSON=", 1)[1].splitlines()[0])
            self.assertEqual(evidence["required_jobs"], [planner.JPEG_JOB])
            self.assertIsNone(evidence["evidence_run_id"])
            self.assertIn("does not certify", (root / "summary").read_text())

    @staticmethod
    def evidence_maintenance_changes():
        changes = {path: ("before " + path, "after " + path) for path in scope.CI_EVIDENCE_PATHS}
        selector = "NekoWidget/ci/ios_ci_scope.py"
        empty = "CI_EVIDENCE_DIGESTS = {}\n"
        changes[selector] = (changes[selector][0], empty + "# reviewed selector\n")
        digests = {path: list(map(scope.source_digest, pair)) for path, pair in changes.items()}
        binding = "CI_EVIDENCE_DIGESTS = " + json.dumps(digests, indent=4, sort_keys=True) + "\n"
        changes[selector] = (changes[selector][0], changes[selector][1].replace(empty, binding))
        return changes, digests

    def test_evidence_maintenance_is_complete_frozen_and_not_release_evidence(self):
        changes, digests = self.evidence_maintenance_changes()
        with patch.object(scope, "CI_EVIDENCE_DIGESTS", digests):
            self.assertEqual(scope.select_scope(changes), scope.CI_EVIDENCE_SCOPE)
            for path in changes:
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(missing), scope.FULL_SCOPE)
                for side in (0, 1):
                    pair = list(changes[path]); pair[side] += " unreviewed"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(pair)})), scope.FULL_SCOPE)
            for path in (scope.CI_WORKFLOW, scope.CI_DIAGNOSTIC_WORKFLOW, scope.CI_DIAGNOSTIC_MATRIX,
                         "NekoWidget/NekoWidget/Views/MainTabView.swift", "NekoWidget/ci/preflight-ci.py",
                         "NekoWidget/Config.xcconfig", "unknown.swift"):
                self.assertEqual(scope.select_scope(dict(changes, **{path: ("old", "new")})), scope.FULL_SCOPE)
        self.assertEqual(planner.required_jobs(sorted(changes), scope.CI_EVIDENCE_SCOPE), (planner.PLAN_JOB,))
        self.assertEqual(planner.required_jobs(sorted(changes) + [scope.CI_WORKFLOW], scope.CI_EVIDENCE_SCOPE), planner.FULL)
        self.assertNotIn(scope.CI_EVIDENCE_SCOPE, scope.SCOPES)
        with self.assertRaises(ValueError):
            planner.required_jobs_from_scope(scope.CI_EVIDENCE_SCOPE)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "event.json").write_text("{}")
            env = dict(self.env, GITHUB_EVENT_PATH=str(root / "event.json"),
                       GITHUB_OUTPUT=str(root / "output"), GITHUB_STEP_SUMMARY=str(root / "summary"))
            with patch.dict(os.environ, env), patch.object(planner, "changed_paths", return_value=sorted(changes)), \
                    patch.object(planner, "runtime_scope", return_value=scope.CI_EVIDENCE_SCOPE), \
                    patch.object(planner, "find_evidence") as lookup:
                planner.main()
            lookup.assert_not_called()
            output = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            self.assertTrue(all(output[name] == "false" for name in ("build", "smoke", "sharing", "app_ui")))
            self.assertEqual(output["matrix_lanes"], "[]")

    def test_evidence_maintenance_requires_raw_modifications_and_main_ancestry(self):
        changes, digests = self.evidence_maintenance_changes()
        base, paths = "b" * 40, sorted(changes)
        def selected(path=None, mode=":100644 100644", status="M", ancestor=True):
            def git(*args):
                if args[0] == "merge-base" and not ancestor:
                    raise subprocess.CalledProcessError(1, "git")
                if args[0] == "diff":
                    return "".join(f"{mode if item == path else ':100644 100644'} {'c' * 40} {'d' * 40} "
                                   f"{status if item == path else 'M'}\0{item}\0" for item in paths)
                if args[0] == "show":
                    revision, item = args[1].split(":", 1)
                    return changes[item][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        with patch.object(scope, "CI_EVIDENCE_DIGESTS", digests):
            self.assertEqual(selected(), planner.ORCHESTRATION_SCOPE)
            self.assertEqual(selected(ancestor=False), planner.ORCHESTRATION_SCOPE)
            for path in paths:
                for mode, status in ((":000000 100644", "A"), (":100644 000000", "D"),
                                     (":100644 100755", "M"), (":100644 120000", "T"),
                                     (":100644 100644", "R100"), (":100644 100644", "C100")):
                    expected = (planner.ORCHESTRATION_SCOPE if Path(path).name.startswith("test-")
                                and mode == ":000000 100644" and status == "A" else scope.FULL_SCOPE)
                    self.assertEqual(selected(path, mode, status), expected)

    @staticmethod
    def membership_access_changes(*, enforced=False, extra_step=False):
        classes = {}
        for identifier in scope.REVIEWED_MEMBERSHIP_ACCESS_TESTS:
            _, owner, method = identifier.split("/")
            classes.setdefault(owner, []).append(f"    func {method}() {{}}")
        source = "\n".join(f"final class {owner}: XCTestCase {{\n" + "\n".join(methods) + "\n}"
                           for owner, methods in classes.items())
        changes = {path: ("" if path in scope.MEMBERSHIP_ACCESS_NEW_PATHS else "before " + path,
                          source if path == scope.MEMORY_TEST_PATH else "after " + path)
                   for path in scope.MEMBERSHIP_ACCESS_PATHS}
        anchor = "      - name: Verify personal Widget photo rotation\n"
        workflow = "jobs:\n" + anchor + "        run: existing-safe-check\n"
        changes[scope.CI_WORKFLOW] = (workflow, workflow.replace(anchor, scope.MEMBERSHIP_ACCESS_WORKFLOW_ADDITION + anchor))
        if extra_step:
            changes[scope.CI_WORKFLOW] = (workflow, changes[scope.CI_WORKFLOW][1] + "unreviewed-step\n")
        for path in ("NekoWidget/NekoWidget/Info.plist", "NekoWidget/NekoWidgetWidget/Info.plist"):
            after = '<plist version="1.0"><dict><key>MembershipAccessEnforced</key>' + ('<true/>' if enforced else '<false/>') + '</dict></plist>'
            changes[path] = (changes[path][0], after)
        product = {path: tuple(map(scope.source_digest, pair)) for path, pair in changes.items()}
        review = {"schemaVersion": 1, "scope": scope.REVIEWED_MEMBERSHIP_ACCESS_SCOPE,
                  "purpose": "Reviewed beta-disabled membership access", "visualReview": "native-ui-required",
                  "dataReview": scope.MEMBERSHIP_ACCESS_DATA_REVIEW,
                  "files": {path: {"before": pair[0], "after": pair[1]} for path, pair in product.items()}}
        changes[scope.REVIEW_MANIFEST] = ("{}", json.dumps(review))
        changes.update({path: ("before " + path, "after " + path) for path in scope.MEMBERSHIP_ACCESS_COMPANION_PATHS})
        selector = "NekoWidget/ci/ios_ci_scope.py"
        empty = "MEMBERSHIP_ACCESS_COMPANION_DIGESTS = {}\n"
        changes[selector] = ("old selector", empty + "# reviewed selector source\n")
        companions = {path: list(map(scope.source_digest, changes[path]))
                      for path in scope.MEMBERSHIP_ACCESS_COMPANION_PATHS | {scope.REVIEW_MANIFEST}}
        literal = "MEMBERSHIP_ACCESS_COMPANION_DIGESTS = " + json.dumps(companions, indent=4, sort_keys=True) + "\n"
        changes[selector] = (changes[selector][0], changes[selector][1].replace(empty, literal))
        return changes, product, companions

    def test_membership_access_requires_complete_frozen_product_and_companions(self):
        changes, product, companions = self.membership_access_changes()
        with patch.object(scope, "MEMBERSHIP_ACCESS_DIGESTS", {}):
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        with patch.object(scope, "MEMBERSHIP_ACCESS_DIGESTS", product), \
                patch.object(scope, "MEMBERSHIP_ACCESS_COMPANION_DIGESTS", companions):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_MEMBERSHIP_ACCESS_SCOPE)
            for path in changes:
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(missing), scope.FULL_SCOPE)
                for side in (0, 1):
                    altered = list(changes[path]); altered[side] += " unreviewed change"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(altered)})), scope.FULL_SCOPE)
            for extra in (scope.CI_WORKFLOW, scope.CI_DIAGNOSTIC_MATRIX,
                          "NekoWidget/NekoWidget/Services/UnknownMembership.swift",
                          "NekoWidget/Config.xcconfig", "NekoWidget/NekoWidget/Info.plist",
                          "NekoWidget/NekoWidget/Services/FamilyRecordClient.swift",
                          "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift"):
                self.assertEqual(scope.select_scope(dict(changes, **{extra: ("old", "new")})), scope.FULL_SCOPE)
            selector = "NekoWidget/ci/ios_ci_scope.py"
            source = changes[selector][1]
            for altered in (source + source, source.replace("DIGESTS = ", "DIGESTS=", 1)):
                self.assertEqual(scope.select_scope(dict(changes, **{selector: (changes[selector][0], altered)})),
                                 scope.FULL_SCOPE)

    def test_membership_access_rehashed_flags_and_extra_workflow_step_still_fail_closed(self):
        for arguments in ({"enforced": True}, {"extra_step": True}):
            changes, product, companions = self.membership_access_changes(**arguments)
            with patch.object(scope, "MEMBERSHIP_ACCESS_DIGESTS", product), \
                    patch.object(scope, "MEMBERSHIP_ACCESS_COMPANION_DIGESTS", companions):
                self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)

    def test_membership_access_raw_diff_and_safety_evidence_remain_required(self):
        changes, product, companions = self.membership_access_changes()
        base, paths = "b" * 40, sorted(changes)
        def selected(path=None, modes=":100644 100644", status="M", extra=False):
            raw = ""
            for item in paths:
                default_modes = ":000000 100644" if item in scope.MEMBERSHIP_ACCESS_NEW_PATHS else ":100644 100644"
                default_status = "A" if item in scope.MEMBERSHIP_ACCESS_NEW_PATHS else "M"
                raw += (f"{modes if item == path else default_modes} {'c' * 40} {'d' * 40} "
                        f"{status if item == path else default_status}\0{item}\0")
            if extra:
                raw += f":100644 100644 {'c' * 40} {'d' * 40} M\0unreported.swift\0"
            def git(*args):
                if args[0] == "diff":
                    return raw
                if args[0] == "show":
                    revision, item = args[1].split(":", 1)
                    if revision == base and item in scope.MEMBERSHIP_ACCESS_NEW_PATHS:
                        raise AssertionError("An approved addition has no base blob")
                    return changes[item][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        with patch.object(scope, "MEMBERSHIP_ACCESS_DIGESTS", product), \
                patch.object(scope, "MEMBERSHIP_ACCESS_COMPANION_DIGESTS", companions):
            self.assertEqual(selected(), scope.REVIEWED_MEMBERSHIP_ACCESS_SCOPE)
            self.assertEqual(selected(extra=True), scope.FULL_SCOPE)
            for path in paths:
                invalid = [(":100644 000000", "D"), (":100644 100755", "M"),
                           (":100644 120000", "T"), (":100644 100644", "R100"),
                           (":100644 100644", "C100"), (":000000 100755", "A"),
                           (":000000 120000", "A")]
                invalid.append((":100644 100644", "M") if path in scope.MEMBERSHIP_ACCESS_NEW_PATHS
                               else (":000000 100644", "A"))
                for modes, status in invalid:
                    self.assertEqual(selected(path, modes, status), scope.FULL_SCOPE)
        selected_scope = scope.REVIEWED_MEMBERSHIP_ACCESS_SCOPE
        required = planner.required_jobs(paths, selected_scope)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected_scope))
        self.assertTrue(scope.accepts_paths(selected_scope, paths))
        self.assertEqual(scope.lanes(selected_scope), scope.LANES)
        tests = scope.lane_tests(selected_scope, "app-ui")
        self.assertEqual(len(tests), 2)
        self.assertEqual(len(set(tests)), 2)
        self.assertTrue(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1], tests))
        self.assertFalse(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1].replace(
            "testMembershipAccessPreservesExistingMemoAndDistinguishesUnknown", "absent"), tests))
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, required, base))
        self.assertFalse(planner.covers_jobs(jobs, planner.required_jobs_from_scope(scope.REVIEWED_CAT_NOTE_SCOPE), self.sha))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            self.assertFalse(planner.covers_jobs(jobs + [jobs[index]], required, self.sha))
            for conclusion in ("failure", "skipped", "cancelled"):
                altered = copy.deepcopy(jobs); altered[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(altered, required, self.sha))

    DELIVERY_TESTS = (
        "NekoWidgetUITests/MomentDeliveryComposerUITests/testPhotoDeliveryProgressAllowsOtherActionsAndShowsTruthfulStates",
        "NekoWidgetUITests/MomentDeliveryComposerUITests/testPhotoWindowRetryPreservesConfirmedPhotoAndCaption",
        "NekoWidgetUITests/MomentDeliveryComposerUITests/testFamilyRecordKeepsOtherAuthorsWordsWhenPhotoIsWithdrawnAndRevokesAccess",
    )

    @staticmethod
    def delivery_membership_changes(resuming=False, exporting=False, managed=False):
        prefix = "MANAGED_PRESERVATION" if managed else "RECORD_PORTABILITY" if exporting else "WINDOW_SUPPORT" if resuming else "DELIVERY_MEMBERSHIP"
        paths, new_paths = (getattr(scope, prefix + suffix) for suffix in ("_PATHS", "_NEW_PATHS"))
        companion_paths = getattr(scope, prefix + "_COMPANION_PATHS")
        selected = getattr(scope, "REVIEWED_" + prefix + "_SCOPE")
        native = getattr(scope, "REVIEWED_" + prefix + "_TESTS")
        classes = {}
        for identifier in native:
            _, owner, method = identifier.split("/")
            classes.setdefault(owner, []).append(f"    func {method}() {{}}")
        source = "\n".join(f"final class {owner}: XCTestCase {{\n" + "\n".join(methods) + "\n}"
                           for owner, methods in classes.items())
        changes = {path: ("" if path in new_paths else "before " + path,
                          source if path == scope.MEMORY_TEST_PATH else "after " + path)
                   for path in paths}
        if managed:
            for path, source in (
                ("NekoWidget/NekoWidget/Services/SharingRuntimeSelfTest.swift",
                 '\n'.join(f'runAsync("{case}") {{ boundary() }}' for case in scope.MANAGED_PRESERVATION_RUNTIME_CASES)),
                ("NekoWidget/ci/validate-sharing-runtime-self-test.py",
                 'REQUIRED_CASES = {' + ''.join(f'"{case}",' for case in scope.MANAGED_PRESERVATION_RUNTIME_CASES) + '}'),
            ):
                if path in changes:
                    changes[path] = (changes[path][0], source)
        project = "NekoWidget/NekoWidget.xcodeproj/project.pbxproj"
        if project in changes:
            frozen = "\t\tA00000000000000000000025 /* Sources */ = {\n\t\t\tfiles = (unchanged);\n\t\t};\n"
            frozen += "".join("/* Begin " + name + " section */\nfrozen\n/* End " + name + " section */\n"
                              for name in ("PBXNativeTarget", "XCBuildConfiguration", "XCConfigurationList",
                                           "PBXResourcesBuildPhase", "PBXFrameworksBuildPhase"))
            changes[project] = (frozen + "app before", frozen + "app after")
        product = {path: tuple(map(scope.source_digest, pair)) for path, pair in changes.items()}
        review = {"schemaVersion": 1, "scope": selected,
                  "purpose": "Reviewed explicit delivery support boundary", "visualReview": "native-ui-required",
                  "dataReview": getattr(scope, prefix + "_DATA_REVIEW"),
                  "files": {path: {"before": pair[0], "after": pair[1]} for path, pair in product.items()}}
        changes[scope.REVIEW_MANIFEST] = ("{}", json.dumps(review))
        changes.update({path: ("before " + path, "after " + path) for path in companion_paths})
        selector = "NekoWidget/ci/ios_ci_scope.py"
        empty = prefix + "_COMPANION_DIGESTS = {}\n"
        changes[selector] = ("old selector", empty + "# reviewed selector source\n")
        companions = {path: list(map(scope.source_digest, changes[path]))
                      for path in companion_paths | {scope.REVIEW_MANIFEST}}
        literal = prefix + "_COMPANION_DIGESTS = " + json.dumps(companions, indent=4, sort_keys=True) + "\n"
        changes[selector] = (changes[selector][0], changes[selector][1].replace(empty, literal))
        return changes, product, companions

    def test_managed_preservation_requires_frozen_integration_and_runtime_ui_cases(self):
        changes, product, companions = self.delivery_membership_changes(managed=True)
        with patch.object(scope, "MANAGED_PRESERVATION_DIGESTS", {}):
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        with patch.object(scope, "MANAGED_PRESERVATION_DIGESTS", product), \
                patch.object(scope, "MANAGED_PRESERVATION_COMPANION_DIGESTS", companions):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_MANAGED_PRESERVATION_SCOPE)
            for path in changes:
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(missing), scope.FULL_SCOPE)
                for side in (0, 1):
                    altered = list(changes[path]); altered[side] += " unreviewed change"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(altered)})), scope.FULL_SCOPE)
            for extra in (scope.CI_WORKFLOW, scope.CI_DIAGNOSTIC_MATRIX,
                          "NekoWidget/ci/ci-timing-baseline.json",
                          "NekoWidget/NekoWidget/Views/FamilyRecordView.swift",
                          "NekoWidget/NekoWidget/Services/ManagedPreservationSessionStore.swift",
                          "NekoWidget/NekoWidget.xcodeproj/project.pbxproj",
                          "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift",
                          "NekoWidget/NekoWidget/Services/PersonalArchiveStore.swift",
                          "NekoWidget/NekoWidget/Info.plist", "NekoWidget/Config.xcconfig",
                          "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                          "NekoWidget/Shared/Models/WidgetRenderPlan.swift",
                          "NekoWidget/PreservationService/src/index.ts"):
                if extra in scope.MANAGED_PRESERVATION_PATHS:
                    continue
                altered = dict(changes, **{extra: ("before", "after")})
                self.assertEqual(scope.select_scope(altered), scope.FULL_SCOPE)
                self.assertEqual(planner.required_jobs(list(altered), scope.REVIEWED_MANAGED_PRESERVATION_SCOPE), planner.FULL)
            tests = scope.REVIEWED_MANAGED_PRESERVATION_TESTS
            for incomplete in ((), tests[:1], tests[1:], (tests[0], tests[0]),
                               (tests[0], "NekoWidgetUITests/SoloMemoriesUITests/testMissingMembershipLink")):
                with patch.object(scope, "REVIEWED_MANAGED_PRESERVATION_TESTS", incomplete):
                    self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
            cases = scope.MANAGED_PRESERVATION_RUNTIME_CASES
            for incomplete in ((), cases[:1], cases[1:], (cases[0], cases[0]), (cases[0], 'missing-boundary')):
                with patch.object(scope, "MANAGED_PRESERVATION_RUNTIME_CASES", incomplete):
                    self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
            selector = "NekoWidget/ci/ios_ci_scope.py"
            source = changes[selector][1]
            self.assertEqual(scope.select_scope(dict(changes, **{selector: (changes[selector][0], source + source)})),
                             scope.FULL_SCOPE)
            # Changing the manifest to an old evidence namespace is not review.
            old_review = json.loads(changes[scope.REVIEW_MANIFEST][1]); old_review['scope'] = 'reviewed-managed-preservation-app-v2'
            self.assertEqual(scope.select_scope(dict(changes, **{scope.REVIEW_MANIFEST: ('{}', json.dumps(old_review))})), scope.FULL_SCOPE)
        tests = scope.native_tests(scope.REVIEWED_MANAGED_PRESERVATION_SCOPE)
        self.assertEqual(tests, (
            'NekoWidgetUITests/SoloMemoriesUITests/testManagedPreservationDisabledHidesEntries',
            'NekoWidgetUITests/SoloMemoriesUITests/testManagedPreservationLostCopyResultShowsConfirmationAndStoredState',
            'NekoWidgetUITests/SoloMemoriesUITests/testManagedPreservationMembershipLinkConsentAndRetry',
            'NekoWidgetUITests/SoloMemoriesUITests/testManagedPreservationAccountDeletionRetainsReceiptAndCompletes',
            'NekoWidgetUITests/SoloMemoriesUITests/testMembershipOfferExplainsExpiryWithoutChangingThePlan',
        ))
        self.assertEqual(scope.REVIEWED_MANAGED_PRESERVATION_SCOPE, 'reviewed-managed-preservation-app-v6')
        self.assertEqual(len(scope.MANAGED_PRESERVATION_PATHS), 9)
        self.assertFalse(scope.MANAGED_PRESERVATION_NEW_PATHS)
        self.assertNotIn("NekoWidget/NekoWidget/Services/BillingClientCore.swift", scope.MANAGED_PRESERVATION_PATHS)
        self.assertNotIn("NekoWidget/NekoWidget/NekoWidget.entitlements", scope.MANAGED_PRESERVATION_PATHS)
        self.assertIn("NekoWidget/NekoWidget/Views/FamilyRecordView.swift", scope.MANAGED_PRESERVATION_PATHS)
        self.assertEqual(len(scope.MANAGED_PRESERVATION_COMPANION_PATHS), 6)
        self.assertTrue(scope.memory_tests_available(scope.managed_validation_source(changes, scope.MEMORY_TEST_PATH), tests))
        with patch.object(scope, "managed_validation_source", return_value=""):
            with patch.object(scope, "MANAGED_PRESERVATION_DIGESTS", product), \
                 patch.object(scope, "MANAGED_PRESERVATION_COMPANION_DIGESTS", companions):
                self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)

    def test_managed_preservation_raw_modifications_and_four_safety_jobs(self):
        changes, product, companions = self.delivery_membership_changes(managed=True)
        base, paths = "b" * 40, sorted(changes)
        def selected(path=None, modes=":100644 100644", status="M", extra=False):
            raw = ""
            for item in paths:
                new = item in scope.MANAGED_PRESERVATION_NEW_PATHS
                raw += (f"{modes if item == path else ':000000 100644' if new else ':100644 100644'} "
                        f"{'c' * 40} {'d' * 40} {status if item == path else 'A' if new else 'M'}\0{item}\0")
            if extra:
                raw += f":100644 100644 {'c' * 40} {'d' * 40} M\0unreported.swift\0"
            def git(*args):
                if args[0] == "diff":
                    return raw
                if args[0] == "show":
                    revision, item = args[1].split(":", 1)
                    if revision == base and item in scope.MANAGED_PRESERVATION_NEW_PATHS:
                        raise AssertionError("A reviewed addition has no base blob")
                    return changes[item][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        with patch.object(scope, "MANAGED_PRESERVATION_DIGESTS", product), \
                patch.object(scope, "MANAGED_PRESERVATION_COMPANION_DIGESTS", companions):
            self.assertEqual(selected(), scope.REVIEWED_MANAGED_PRESERVATION_SCOPE)
            self.assertEqual(selected(extra=True), scope.FULL_SCOPE)
            for path in paths:
                invalid = [(":100644 000000", "D"), (":100644 100755", "M"), (":100644 120000", "T"),
                           (":100644 100644", "R100"), (":100644 100644", "C100"),
                           (":000000 100755", "A"), (":000000 120000", "A")]
                invalid.append((":100644 100644", "M") if path in scope.MANAGED_PRESERVATION_NEW_PATHS else (":000000 100644", "A"))
                for modes, status in invalid:
                    self.assertEqual(selected(path, modes, status), scope.FULL_SCOPE)
        selected_scope = scope.REVIEWED_MANAGED_PRESERVATION_SCOPE
        required = planner.required_jobs(paths, selected_scope)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected_scope))
        self.assertEqual(len(required), 4)
        self.assertEqual(scope.lanes(selected_scope), ("runtime", "app-ui"))
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, required, base))
        legacy_jobs = [dict(job, name=job['name'].replace('-app-v6]', '-app-v5]')) for job in jobs]
        self.assertFalse(planner.covers_jobs(legacy_jobs, required, self.sha))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            for state in ("skipped", "failure", "cancelled"):
                altered = copy.deepcopy(jobs); altered[index]["conclusion"] = state
                self.assertFalse(planner.covers_jobs(altered, required, self.sha))

    def test_record_portability_requires_complete_frozen_sources_and_two_ui_operations(self):
        changes, product, companions = self.delivery_membership_changes(exporting=True)
        with patch.object(scope, "RECORD_PORTABILITY_DIGESTS", {}):
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        with patch.object(scope, "RECORD_PORTABILITY_DIGESTS", product), \
                patch.object(scope, "RECORD_PORTABILITY_COMPANION_DIGESTS", companions):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_RECORD_PORTABILITY_SCOPE)
            for path in changes:
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(missing), scope.FULL_SCOPE)
                for side in (0, 1):
                    altered = list(changes[path]); altered[side] += " unreviewed change"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(altered)})), scope.FULL_SCOPE)
            for extra in (scope.CI_WORKFLOW, scope.CI_DIAGNOSTIC_MATRIX,
                          "NekoWidget/ci/plan-ios-ci.py", "NekoWidget/ci/preflight-ci.py",
                          "NekoWidget/NekoWidget.xcodeproj/project.pbxproj",
                          "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift",
                          "NekoWidget/NekoWidget/Services/PersonalArchiveStore.swift",
                          "NekoWidget/NekoWidget/Services/PersonalArchiveCloudClient.swift",
                          "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                          "NekoWidget/Shared/Models/WidgetRenderPlan.swift",
                          "NekoWidget/SharingService/src/index.ts"):
                altered = dict(changes, **{extra: ("before", "after")})
                self.assertEqual(scope.select_scope(altered), scope.FULL_SCOPE)
                self.assertEqual(planner.required_jobs(list(altered), scope.REVIEWED_RECORD_PORTABILITY_SCOPE), planner.FULL)
            with patch.object(scope, "REVIEWED_RECORD_PORTABILITY_TESTS", ()):
                self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
            selector = "NekoWidget/ci/ios_ci_scope.py"
            source = changes[selector][1]
            self.assertEqual(scope.select_scope(dict(changes, **{selector: (changes[selector][0], source + source)})),
                             scope.FULL_SCOPE)
        tests = scope.native_tests(scope.REVIEWED_RECORD_PORTABILITY_SCOPE)
        self.assertEqual(len(set(tests)), 2)
        self.assertTrue(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1], tests))
        for identifier in tests:
            self.assertFalse(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1].replace(
                identifier.split("/")[-1], "absent"), tests))

    def test_record_portability_raw_modifications_and_four_safety_jobs(self):
        changes, product, companions = self.delivery_membership_changes(exporting=True)
        base, paths = "b" * 40, sorted(changes)
        def selected(path=None, modes=":100644 100644", status="M", extra=False):
            raw = "".join(f"{modes if item == path else ':100644 100644'} {'c' * 40} {'d' * 40} "
                          f"{status if item == path else 'M'}\0{item}\0" for item in paths)
            if extra:
                raw += f":100644 100644 {'c' * 40} {'d' * 40} M\0unreported.swift\0"
            def git(*args):
                if args[0] == "diff":
                    return raw
                if args[0] == "show":
                    revision, item = args[1].split(":", 1)
                    return changes[item][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        with patch.object(scope, "RECORD_PORTABILITY_DIGESTS", product), \
                patch.object(scope, "RECORD_PORTABILITY_COMPANION_DIGESTS", companions):
            self.assertEqual(selected(), scope.REVIEWED_RECORD_PORTABILITY_SCOPE)
            self.assertEqual(selected(extra=True), scope.FULL_SCOPE)
            for path in paths:
                for modes, status in ((":100644 000000", "D"), (":100644 100755", "M"),
                                      (":100644 120000", "T"), (":100644 100644", "R100"),
                                      (":100644 100644", "C100"), (":000000 100644", "A")):
                    self.assertEqual(selected(path, modes, status), scope.FULL_SCOPE)
        selected_scope = scope.REVIEWED_RECORD_PORTABILITY_SCOPE
        required = planner.required_jobs(paths, selected_scope)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected_scope))
        self.assertEqual(len(required), 4)
        self.assertEqual(scope.lanes(selected_scope), ("runtime", "app-ui"))
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, required, base))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            for state in ("skipped", "failure", "cancelled"):
                altered = copy.deepcopy(jobs); altered[index]["conclusion"] = state
                self.assertFalse(planner.covers_jobs(altered, required, self.sha))

    @patch.object(scope, "REVIEWED_DELIVERY_MEMBERSHIP_TESTS", DELIVERY_TESTS)
    def test_delivery_membership_requires_complete_frozen_product_and_companions(self):
        changes, product, companions = self.delivery_membership_changes()
        with patch.object(scope, "DELIVERY_MEMBERSHIP_DIGESTS", {}):
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        with patch.object(scope, "DELIVERY_MEMBERSHIP_DIGESTS", product), \
                patch.object(scope, "DELIVERY_MEMBERSHIP_COMPANION_DIGESTS", companions):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_DELIVERY_MEMBERSHIP_SCOPE)
            with patch.object(scope, "REVIEWED_DELIVERY_MEMBERSHIP_TESTS", ()):
                self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
            for path in changes:
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(missing), scope.FULL_SCOPE)
                for side in (0, 1):
                    altered = list(changes[path]); altered[side] += " unreviewed change"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(altered)})), scope.FULL_SCOPE)
            for extra in (scope.CI_WORKFLOW, scope.CI_DIAGNOSTIC_MATRIX,
                          "NekoWidget/NekoWidget/Services/UnknownMembership.swift",
                          ".github/workflows/sharing-service.yml",
                          "NekoWidget/SharingService/package.json", "NekoWidget/SharingService/package-lock.json",
                          "NekoWidget/SharingService/wrangler.jsonc",
                          "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                          "NekoWidget/Shared/Models/WidgetRenderPlan.swift",
                          "NekoWidget/Config.xcconfig", "NekoWidget/NekoWidget/Info.plist",
                          "NekoWidget/NekoWidget/Services/FamilyRecordClient.swift",
                          "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift"):
                self.assertEqual(scope.select_scope(dict(changes, **{extra: ("old", "new")})), scope.FULL_SCOPE)
            selector = "NekoWidget/ci/ios_ci_scope.py"
            source = changes[selector][1]
            for altered in (source + source, source.replace("DIGESTS = ", "DIGESTS=", 1)):
                self.assertEqual(scope.select_scope(dict(changes, **{selector: (changes[selector][0], altered)})),
                                 scope.FULL_SCOPE)

    @patch.object(scope, "REVIEWED_DELIVERY_MEMBERSHIP_TESTS", DELIVERY_TESTS)
    def test_delivery_membership_raw_diff_and_safety_evidence_remain_required(self):
        changes, product, companions = self.delivery_membership_changes()
        base, paths = "b" * 40, sorted(changes)
        def selected(path=None, modes=":100644 100644", status="M", extra=False):
            raw = ""
            for item in paths:
                default_modes = ":000000 100644" if item in scope.DELIVERY_MEMBERSHIP_NEW_PATHS else ":100644 100644"
                default_status = "A" if item in scope.DELIVERY_MEMBERSHIP_NEW_PATHS else "M"
                raw += (f"{modes if item == path else default_modes} {'c' * 40} {'d' * 40} "
                        f"{status if item == path else default_status}\0{item}\0")
            if extra:
                raw += f":100644 100644 {'c' * 40} {'d' * 40} M\0unreported.swift\0"
            def git(*args):
                if args[0] == "diff":
                    return raw
                if args[0] == "show":
                    revision, item = args[1].split(":", 1)
                    if revision == base and item in scope.DELIVERY_MEMBERSHIP_NEW_PATHS:
                        raise AssertionError("An approved addition has no base blob")
                    return changes[item][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        with patch.object(scope, "DELIVERY_MEMBERSHIP_DIGESTS", product), \
                patch.object(scope, "DELIVERY_MEMBERSHIP_COMPANION_DIGESTS", companions):
            self.assertEqual(selected(), scope.REVIEWED_DELIVERY_MEMBERSHIP_SCOPE)
            self.assertEqual(selected(extra=True), scope.FULL_SCOPE)
            for path in paths:
                invalid = [(":100644 000000", "D"), (":100644 100755", "M"),
                           (":100644 120000", "T"), (":100644 100644", "R100"),
                           (":100644 100644", "C100"), (":000000 100755", "A"),
                           (":000000 120000", "A")]
                invalid.append((":100644 100644", "M") if path in scope.DELIVERY_MEMBERSHIP_NEW_PATHS
                               else (":000000 100644", "A"))
                for modes, status in invalid:
                    self.assertEqual(selected(path, modes, status), scope.FULL_SCOPE)
        selected_scope = scope.REVIEWED_DELIVERY_MEMBERSHIP_SCOPE
        required = planner.required_jobs(paths, selected_scope)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected_scope))
        self.assertTrue(scope.accepts_paths(selected_scope, paths))
        self.assertEqual(scope.lanes(selected_scope), ("runtime", "app-ui"))
        tests = scope.native_tests(selected_scope)
        self.assertEqual(len(tests), 3)
        self.assertEqual(len(set(tests)), 3)
        self.assertTrue(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1], tests))
        self.assertFalse(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1].replace(
            "testPhotoDeliveryProgressAllowsOtherActionsAndShowsTruthfulStates", "absent"), tests))
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, required, base))
        self.assertFalse(planner.covers_jobs(jobs, planner.required_jobs_from_scope(scope.REVIEWED_CAT_NOTE_SCOPE), self.sha))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            self.assertFalse(planner.covers_jobs(jobs + [jobs[index]], required, self.sha))
            for conclusion in ("failure", "skipped", "cancelled"):
                altered = copy.deepcopy(jobs); altered[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(altered, required, self.sha))

    def test_window_support_resume_requires_closed_sources_and_both_ui_operations(self):
        changes, product, companions = self.delivery_membership_changes(resuming=True)
        with patch.object(scope, "WINDOW_SUPPORT_DIGESTS", {}):
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        with patch.object(scope, "WINDOW_SUPPORT_DIGESTS", product), \
                patch.object(scope, "WINDOW_SUPPORT_COMPANION_DIGESTS", companions):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_WINDOW_SUPPORT_SCOPE)
            for path in changes:
                partial = dict(changes); del partial[path]
                self.assertEqual(scope.select_scope(partial), scope.FULL_SCOPE)
                for side in (0, 1):
                    pair = list(changes[path]); pair[side] += " unreviewed change"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(pair)})), scope.FULL_SCOPE)
            for extra in (scope.CI_WORKFLOW, scope.CI_DIAGNOSTIC_MATRIX,
                          "NekoWidget/ci/preflight-ci.py", "NekoWidget/ci/verify-app-icon.py",
                          "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                          "NekoWidget/Shared/PersonalWidgetMembershipStore.swift",
                          "NekoWidget/SharingService/src/unknown.ts",
                          "NekoWidget/SharingService/migrations/0029_unknown.sql",
                          ".github/workflows/sharing-service.yml"):
                self.assertEqual(scope.select_scope(dict(changes, **{extra: ("old", "new")})), scope.FULL_SCOPE)
            self.assertFalse(scope.reviewed_delivery_membership_changes(changes))
            with patch.object(scope, "REVIEWED_WINDOW_SUPPORT_TESTS", ()):
                self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
            selector = "NekoWidget/ci/ios_ci_scope.py"
            before, after = changes[selector]
            self.assertEqual(scope.select_scope(dict(changes, **{selector: (before, after + after)})), scope.FULL_SCOPE)
        tests = scope.native_tests(scope.REVIEWED_WINDOW_SUPPORT_SCOPE)
        self.assertEqual(len(tests), 2)
        self.assertEqual(len(set(tests)), 2)
        self.assertTrue(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1], tests))
        self.assertFalse(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1].replace(
            tests[0].split("/")[-1], "absent"), tests))

    def test_window_support_resume_raw_modes_and_four_safety_jobs(self):
        changes, product, companions = self.delivery_membership_changes(resuming=True)
        base, paths = "b" * 40, sorted(changes)
        def selected(altered_path=None, modes=":100644 100644", status="M", extra=False):
            records = []
            for path in paths:
                added = path in scope.WINDOW_SUPPORT_NEW_PATHS
                raw_modes, raw_status = (":000000 100644", "A") if added else (":100644 100644", "M")
                if path == altered_path: raw_modes, raw_status = modes, status
                records.extend([f"{raw_modes} {'c' * 40} {'d' * 40} {raw_status}", path])
            if extra: records.extend([f":100644 100644 {'c' * 40} {'d' * 40} M", "unreported.swift"])
            def git(*args):
                if args[0] == "diff": return "\0".join(records) + "\0"
                if args[0] == "show":
                    revision, path = args[1].split(":", 1)
                    if revision == base and path in scope.WINDOW_SUPPORT_NEW_PATHS:
                        raise AssertionError("Named additions have no base blob")
                    return changes[path][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        with patch.object(scope, "WINDOW_SUPPORT_DIGESTS", product), \
                patch.object(scope, "WINDOW_SUPPORT_COMPANION_DIGESTS", companions):
            self.assertEqual(selected(), scope.REVIEWED_WINDOW_SUPPORT_SCOPE)
            self.assertEqual(selected(extra=True), scope.FULL_SCOPE)
            for path in paths:
                for modes, status in ((":100644 000000", "D"), (":100644 100755", "M"),
                                      (":100644 120000", "T"), (":100644 100644", "R100"),
                                      (":000000 100755", "A"), (":000000 120000", "A")):
                    self.assertEqual(selected(path, modes, status), scope.FULL_SCOPE)
                wrong = (":100644 100644", "M") if path in scope.WINDOW_SUPPORT_NEW_PATHS else (":000000 100644", "A")
                self.assertEqual(selected(path, *wrong), scope.FULL_SCOPE)
        required = planner.required_jobs(paths, scope.REVIEWED_WINDOW_SUPPORT_SCOPE)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.REVIEWED_WINDOW_SUPPORT_SCOPE))
        self.assertEqual(len(required), 4)
        self.assertEqual(scope.lanes(scope.REVIEWED_WINDOW_SUPPORT_SCOPE), ("runtime", "app-ui"))
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            for state in ("skipped", "failure", "cancelled"):
                incomplete = copy.deepcopy(jobs); incomplete[index]["conclusion"] = state
                self.assertFalse(planner.covers_jobs(incomplete, required, self.sha))

    def test_delivery_gallery_exclusion_requires_unchanged_render_inputs_and_widget_project(self):
        for path in ("NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                     "NekoWidget/Shared/Models/WidgetRenderPlan.swift",
                     "NekoWidget/Shared/UI/CatPawMark.swift",
                     "NekoWidget/Shared/Storage/PersonalRediscoveryStore.swift",
                     "NekoWidget/NekoWidget/Services/CanonicalPreviewBuilder.swift"):
            self.assertFalse(scope.delivery_gallery_inputs_unchanged({path: ("old", "new")}))
        project = "NekoWidget/NekoWidget.xcodeproj/project.pbxproj"
        widget = "\t\tA00000000000000000000025 /* Sources */ = {\n\t\t\tfiles = (unchanged);\n\t\t};\n"
        sections = "".join("/* Begin " + name + " section */\nfrozen\n/* End " + name + " section */\n"
                           for name in ("PBXNativeTarget", "XCBuildConfiguration", "XCConfigurationList",
                                        "PBXResourcesBuildPhase", "PBXFrameworksBuildPhase"))
        before = widget + sections + "app sources before"
        after = widget + sections + "app sources after"
        self.assertTrue(scope.delivery_gallery_inputs_unchanged({project: (before, after)}))
        for bad in (after.replace("unchanged", "new-widget-source"), after.replace("frozen", "changed", 1),
                    after + "\n" + widget, "missing project sections"):
            self.assertFalse(scope.delivery_gallery_inputs_unchanged({project: (before, bad)}))

    @staticmethod
    def membership_offer_changes():
        classes = {}
        for identifier in scope.REVIEWED_MEMBERSHIP_OFFER_TESTS:
            _, owner, method = identifier.split("/")
            classes.setdefault(owner, []).append(f"    func {method}() {{}}")
        source = "\n".join(f"final class {owner}: XCTestCase {{\n" + "\n".join(methods) + "\n}"
                           for owner, methods in classes.items())
        changes = {path: ("" if path in scope.MEMBERSHIP_OFFER_NEW_PATHS else "before " + path,
                          source if path == scope.MEMORY_TEST_PATH else "after " + path)
                   for path in scope.MEMBERSHIP_OFFER_PATHS}
        product = {path: tuple(map(scope.source_digest, pair)) for path, pair in changes.items()}
        review = {"schemaVersion": 1, "scope": scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE,
                  "purpose": "Reviewed disabled membership offer", "visualReview": "native-ui-required",
                  "dataReview": scope.MEMBERSHIP_OFFER_DATA_REVIEW,
                  "files": {path: {"before": pair[0], "after": pair[1]} for path, pair in product.items()}}
        changes[scope.REVIEW_MANIFEST] = ("{}", json.dumps(review))
        changes.update({path: ("before " + path, "after " + path) for path in scope.MEMBERSHIP_OFFER_COMPANION_PATHS})
        selector = "NekoWidget/ci/ios_ci_scope.py"
        empty = "MEMBERSHIP_OFFER_COMPANION_DIGESTS = {}\n"
        changes[selector] = ("old selector", empty + "# reviewed selector source\n")
        companions = {path: list(map(scope.source_digest, changes[path]))
                      for path in scope.MEMBERSHIP_OFFER_COMPANION_PATHS | {scope.REVIEW_MANIFEST}}
        literal = "MEMBERSHIP_OFFER_COMPANION_DIGESTS = " + json.dumps(companions, indent=4, sort_keys=True) + "\n"
        changes[selector] = (changes[selector][0], changes[selector][1].replace(empty, literal))
        return changes, product, companions

    def test_membership_offer_requires_complete_frozen_product_and_companions(self):
        changes, product, companions = self.membership_offer_changes()
        with patch.object(scope, "MEMBERSHIP_OFFER_DIGESTS", {}):
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        with patch.object(scope, "MEMBERSHIP_OFFER_DIGESTS", product), \
                patch.object(scope, "MEMBERSHIP_OFFER_COMPANION_DIGESTS", companions):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE)
            for path in changes:
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(missing), scope.FULL_SCOPE)
                for side in (0, 1):
                    altered = list(changes[path]); altered[side] += " unreviewed change"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(altered)})), scope.FULL_SCOPE)
            for extra in (scope.CI_WORKFLOW, scope.CI_DIAGNOSTIC_MATRIX,
                          "NekoWidget/NekoWidget/Services/UnknownMembership.swift",
                          "NekoWidget/Config.xcconfig", "NekoWidget/NekoWidget/Info.plist",
                          "NekoWidget/NekoWidget/Services/FamilyRecordClient.swift",
                          "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift"):
                self.assertEqual(scope.select_scope(dict(changes, **{extra: ("old", "new")})), scope.FULL_SCOPE)
            selector = "NekoWidget/ci/ios_ci_scope.py"
            source = changes[selector][1]
            for altered in (source + source, source.replace("DIGESTS = ", "DIGESTS=", 1)):
                self.assertEqual(scope.select_scope(dict(changes, **{selector: (changes[selector][0], altered)})),
                                 scope.FULL_SCOPE)

    def test_membership_offer_raw_diff_and_safety_evidence_remain_required(self):
        changes, product, companions = self.membership_offer_changes()
        base, paths = "b" * 40, sorted(changes)
        def selected(path=None, modes=":100644 100644", status="M", extra=False):
            raw = ""
            for item in paths:
                default_modes = ":000000 100644" if item in scope.MEMBERSHIP_OFFER_NEW_PATHS else ":100644 100644"
                default_status = "A" if item in scope.MEMBERSHIP_OFFER_NEW_PATHS else "M"
                raw += (f"{modes if item == path else default_modes} {'c' * 40} {'d' * 40} "
                        f"{status if item == path else default_status}\0{item}\0")
            if extra:
                raw += f":100644 100644 {'c' * 40} {'d' * 40} M\0unreported.swift\0"
            def git(*args):
                if args[0] == "diff":
                    return raw
                if args[0] == "show":
                    revision, item = args[1].split(":", 1)
                    if revision == base and item in scope.MEMBERSHIP_OFFER_NEW_PATHS:
                        raise AssertionError("An approved addition has no base blob")
                    return changes[item][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        with patch.object(scope, "MEMBERSHIP_OFFER_DIGESTS", product), \
                patch.object(scope, "MEMBERSHIP_OFFER_COMPANION_DIGESTS", companions):
            self.assertEqual(selected(), scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE)
            self.assertEqual(selected(extra=True), scope.FULL_SCOPE)
            for path in paths:
                invalid = [(":100644 000000", "D"), (":100644 100755", "M"),
                           (":100644 120000", "T"), (":100644 100644", "R100"),
                           (":100644 100644", "C100"), (":000000 100755", "A"),
                           (":000000 120000", "A")]
                invalid.append((":100644 100644", "M") if path in scope.MEMBERSHIP_OFFER_NEW_PATHS
                               else (":000000 100644", "A"))
                for modes, status in invalid:
                    self.assertEqual(selected(path, modes, status), scope.FULL_SCOPE)
        selected_scope = scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE
        required = planner.required_jobs(paths, selected_scope)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected_scope))
        self.assertTrue(scope.accepts_paths(selected_scope, paths))
        self.assertEqual(scope.lanes(selected_scope), ("runtime", "app-ui"))
        tests = scope.native_tests(selected_scope)
        self.assertEqual(len(tests), 2)
        self.assertEqual(len(set(tests)), 2)
        self.assertTrue(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1], tests))
        self.assertFalse(scope.memory_tests_available(changes[scope.MEMORY_TEST_PATH][1].replace(
            "testMembershipOfferPreviewWaitingAndRestore", "absent"), tests))
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, required, base))
        self.assertFalse(planner.covers_jobs(jobs, planner.required_jobs_from_scope(scope.REVIEWED_CAT_NOTE_SCOPE), self.sha))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            self.assertFalse(planner.covers_jobs(jobs + [jobs[index]], required, self.sha))
            for conclusion in ("failure", "skipped", "cancelled"):
                altered = copy.deepcopy(jobs); altered[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(altered, required, self.sha))

    @staticmethod
    def photo_actions_changes():
        classes = {}
        for identifier in scope.REVIEWED_PHOTO_ACTIONS_TESTS:
            _, owner, method = identifier.split("/")
            classes.setdefault(owner, []).append(f"    func {method}() {{}}")
        source = "\n".join(f"final class {owner}: XCTestCase {{\n" + "\n".join(methods) + "\n}"
                           for owner, methods in classes.items())
        changes = {path: ("before " + path, source if path == scope.MEMORY_TEST_PATH else "after " + path)
                   for path in scope.PHOTO_ACTIONS_PATHS}
        product = {path: tuple(map(scope.source_digest, pair)) for path, pair in changes.items()}
        review = {"schemaVersion": 1, "scope": scope.REVIEWED_PHOTO_ACTIONS_SCOPE,
                  "purpose": "Reviewed photo actions and shared memo reading", "visualReview": "user-device",
                  "dataReview": scope.PHOTO_ACTIONS_DATA_REVIEW,
                  "files": {path: {"before": pair[0], "after": pair[1]} for path, pair in product.items()}}
        changes[scope.REVIEW_MANIFEST] = ("{}", json.dumps(review))
        changes.update({path: ("before " + path, "after " + path) for path in scope.PHOTO_ACTIONS_COMPANION_PATHS})
        selector = "NekoWidget/ci/ios_ci_scope.py"
        empty = "PHOTO_ACTIONS_COMPANION_DIGESTS = {}\n"
        changes[selector] = ("old selector", empty + "# reviewed selector source\n")
        companions = {path: list(map(scope.source_digest, changes[path]))
                      for path in scope.PHOTO_ACTIONS_COMPANION_PATHS | {scope.REVIEW_MANIFEST}}
        literal = "PHOTO_ACTIONS_COMPANION_DIGESTS = " + json.dumps(companions, indent=4, sort_keys=True) + "\n"
        changes[selector] = (changes[selector][0], changes[selector][1].replace(empty, literal))
        return changes, product, companions

    def test_photo_actions_requires_complete_frozen_product_and_companions(self):
        changes, product, companions = self.photo_actions_changes()
        with patch.object(scope, "PHOTO_ACTIONS_DIGESTS", {}):
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        with patch.object(scope, "PHOTO_ACTIONS_DIGESTS", product), \
                patch.object(scope, "PHOTO_ACTIONS_COMPANION_DIGESTS", companions):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_PHOTO_ACTIONS_SCOPE)
            for path in changes:
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(missing), scope.FULL_SCOPE)
                for side in (0, 1):
                    altered = list(changes[path]); altered[side] += " unreviewed change"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(altered)})), scope.FULL_SCOPE)
            for extra in (scope.CI_WORKFLOW, scope.CI_DIAGNOSTIC_MATRIX,
                          "NekoWidget/NekoWidget/Services/FamilyRecordClient.swift",
                          "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift"):
                self.assertEqual(scope.select_scope(dict(changes, **{extra: ("old", "new")})), scope.FULL_SCOPE)
            selector = "NekoWidget/ci/ios_ci_scope.py"
            source = changes[selector][1]
            for altered in (source + source, source.replace("DIGESTS = ", "DIGESTS=", 1)):
                self.assertEqual(scope.select_scope(dict(changes, **{selector: (changes[selector][0], altered)})),
                                 scope.FULL_SCOPE)

    def test_photo_actions_raw_diff_and_safety_evidence_remain_required(self):
        changes, product, companions = self.photo_actions_changes()
        base, paths = "b" * 40, sorted(changes)
        def selected(path=None, modes=":100644 100644", status="M", extra=False):
            raw = "".join(f"{modes if item == path else ':100644 100644'} {'c' * 40} {'d' * 40} "
                          f"{status if item == path else 'M'}\0{item}\0" for item in paths)
            if extra:
                raw += f":100644 100644 {'c' * 40} {'d' * 40} M\0unreported.swift\0"
            def git(*args):
                if args[0] == "diff":
                    return raw
                if args[0] == "show":
                    revision, item = args[1].split(":", 1)
                    return changes[item][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        with patch.object(scope, "PHOTO_ACTIONS_DIGESTS", product), \
                patch.object(scope, "PHOTO_ACTIONS_COMPANION_DIGESTS", companions):
            self.assertEqual(selected(), scope.REVIEWED_PHOTO_ACTIONS_SCOPE)
            self.assertEqual(selected(extra=True), scope.FULL_SCOPE)
            for path in paths:
                for modes, status in ((":000000 100644", "A"), (":100644 000000", "D"),
                                      (":100644 100755", "M"), (":100644 120000", "T"),
                                      (":100644 100644", "R100"), (":100644 100644", "C100")):
                    self.assertEqual(selected(path, modes, status), scope.FULL_SCOPE)
        selected_scope = scope.REVIEWED_PHOTO_ACTIONS_SCOPE
        required = planner.required_jobs(paths, selected_scope)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected_scope))
        self.assertTrue(scope.accepts_paths(selected_scope, paths))
        self.assertEqual(scope.lanes(selected_scope), ("runtime", "app-ui"))
        tests = scope.native_tests(selected_scope)
        self.assertEqual(len(tests), 8)
        self.assertEqual(len(set(tests)), 8)
        root = Path(__file__).resolve().parents[2]
        self.assertTrue(scope.memory_tests_available((root / scope.MEMORY_TEST_PATH).read_text(encoding="utf-8"), tests))
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, required, base))
        self.assertFalse(planner.covers_jobs(jobs, planner.required_jobs_from_scope(scope.REVIEWED_CAT_NOTE_SCOPE), self.sha))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            self.assertFalse(planner.covers_jobs(jobs + [jobs[index]], required, self.sha))
            for conclusion in ("failure", "skipped", "cancelled"):
                altered = copy.deepcopy(jobs); altered[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(altered, required, self.sha))

    @staticmethod
    def cat_note_changes(values=None, **overrides):
        if values is None:
            classes = {}
            for identifier in scope.REVIEWED_CAT_NOTE_TESTS:
                _, owner, method = identifier.split("/")
                classes.setdefault(owner, []).append(f"    func {method}() {{}}")
            source = "\n".join(f"final class {owner}: XCTestCase {{\n" + "\n".join(methods) + "\n}"
                               for owner, methods in classes.items())
            values = {path: ("before " + path, source if path == scope.MEMORY_TEST_PATH else "after " + path)
                      for path in scope.CAT_NOTE_PATHS}
        values = {path: pair for path, pair in values.items() if path != scope.REVIEW_MANIFEST}
        review = {"schemaVersion": 1, "scope": scope.REVIEWED_CAT_NOTE_SCOPE,
                  "purpose": "Independently reviewed explicit memo sharing", "visualReview": "user-device",
                  "dataReview": scope.CAT_NOTE_DATA_REVIEW,
                  "files": {path: {"before": scope.source_digest(pair[0]), "after": scope.source_digest(pair[1])}
                            for path, pair in values.items()}}
        review.update(overrides)
        return dict(values, **{scope.REVIEW_MANIFEST: ("{}", json.dumps(review))})

    def test_cat_note_scope_requires_frozen_complete_review_not_just_rehashed_manifest(self):
        changes = self.cat_note_changes()
        digests = {path: tuple(map(scope.source_digest, changes[path])) for path in scope.CAT_NOTE_PATHS}
        with patch.object(scope, "CAT_NOTE_DIGESTS", {}):
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        with patch.object(scope, "CAT_NOTE_DIGESTS", digests):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_CAT_NOTE_SCOPE)
            self.assertEqual(scope.select_scope(dict(changes, **{"handoffs/review.md": ("", "reviewed")})),
                             scope.REVIEWED_CAT_NOTE_SCOPE)
            for path in changes:
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(missing), scope.FULL_SCOPE)
            for path in scope.CAT_NOTE_PATHS:
                for side in (0, 1):
                    altered = list(changes[path]); altered[side] += " unreviewed change"
                    # An updated manifest cannot approve changed source independently.
                    self.assertEqual(scope.select_scope(self.cat_note_changes(
                        dict(changes, **{path: tuple(altered)}))), scope.FULL_SCOPE)
            for extra in ("NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift",
                          "NekoWidget/Shared/Sharing/PairingCore.swift",
                          "NekoWidget/Shared/Sharing/MomentSharingCore.swift",
                          "NekoWidget/NekoWidget.xcodeproj/project.pbxproj",
                          "NekoWidget/ci/ios_ci_scope.py", scope.CI_WORKFLOW):
                self.assertEqual(scope.select_scope(self.cat_note_changes(
                    dict(changes, **{extra: ("old", "new")}))), scope.FULL_SCOPE)
            for fields in ({"schemaVersion": True}, {"scope": scope.REVIEWED_MEMORY_FAMILY_SCOPE},
                           {"visualReview": "unchecked"}, {"dataReview": "read-only-projection"},
                           {"purpose": " "}, {"files": {}}, {"unexpected": True}):
                self.assertEqual(scope.select_scope(self.cat_note_changes(changes, **fields)), scope.FULL_SCOPE)
            for manifest in ("[]", "null", "{invalid", changes[scope.REVIEW_MANIFEST][1].replace(
                    '"schemaVersion": 1', '"schemaVersion": 1, "schemaVersion": 1')):
                self.assertEqual(scope.select_scope(dict(changes, **{scope.REVIEW_MANIFEST: ("{}", manifest)})),
                                 scope.FULL_SCOPE)
            for identifier in scope.REVIEWED_CAT_NOTE_TESTS:
                source = changes[scope.MEMORY_TEST_PATH][1]
                method = identifier.split("/")[-1]
                altered = dict(changes, **{scope.MEMORY_TEST_PATH: ("before", source.replace(method, "absent"))})
                # Even a separately reviewed hash table cannot select missing tests.
                revised = dict(digests, **{scope.MEMORY_TEST_PATH: tuple(map(scope.source_digest, altered[scope.MEMORY_TEST_PATH]))})
                with patch.object(scope, "CAT_NOTE_DIGESTS", revised):
                    self.assertEqual(scope.select_scope(self.cat_note_changes(altered)), scope.FULL_SCOPE)

    def test_cat_note_repair_accepts_only_the_frozen_complete_companion_sources(self):
        changes = self.cat_note_changes()
        product = {path: tuple(map(scope.source_digest, changes[path])) for path in scope.CAT_NOTE_PATHS}
        companions = {path: ("old " + path, "new " + path) for path in scope.CAT_NOTE_REPAIR_PATHS}
        selector = "NekoWidget/ci/ios_ci_scope.py"
        companions[selector] = ("old selector", "CAT_NOTE_REPAIR_DIGESTS = {}\n# frozen executable source\n")
        changes.update(companions)
        bindings = {path: list(map(scope.source_digest, changes[path]))
                    for path in scope.CAT_NOTE_REPAIR_PATHS | {scope.REVIEW_MANIFEST}}
        literal = "CAT_NOTE_REPAIR_DIGESTS = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
        changes[selector] = (companions[selector][0], companions[selector][1].replace(
            "CAT_NOTE_REPAIR_DIGESTS = {}\n", literal))
        with patch.object(scope, "CAT_NOTE_DIGESTS", product), patch.object(scope, "CAT_NOTE_REPAIR_DIGESTS", bindings):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_CAT_NOTE_SCOPE)
            self.assertTrue(scope.accepts_paths(scope.REVIEWED_CAT_NOTE_SCOPE, list(changes)))
            self.assertEqual(planner.required_jobs(list(changes), scope.REVIEWED_CAT_NOTE_SCOPE),
                             (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.REVIEWED_CAT_NOTE_SCOPE))
            for path in scope.CAT_NOTE_REPAIR_PATHS | {scope.REVIEW_MANIFEST}:
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(missing), scope.FULL_SCOPE)
                for side in (0, 1):
                    altered = list(changes[path]); altered[side] += " unreviewed"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(altered)})), scope.FULL_SCOPE)
            for source in (changes[selector][1] + literal,
                           changes[selector][1].replace(literal, literal.replace(" = ", "=", 1))):
                self.assertEqual(scope.select_scope(dict(changes, **{selector: (companions[selector][0], source)})),
                                 scope.FULL_SCOPE)
            self.assertEqual(scope.select_scope(dict(changes, **{scope.CI_WORKFLOW: ("old", "new")})), scope.FULL_SCOPE)

    def test_cat_note_planner_preserves_raw_diff_modes_status_and_complete_paths(self):
        changes = self.cat_note_changes()
        digests = {path: tuple(map(scope.source_digest, changes[path])) for path in scope.CAT_NOTE_PATHS}
        base = "b" * 40
        paths = sorted(changes)
        def selected(path=None, modes=":100644 100644", status="M", extra=False):
            raw = "".join(f"{modes if item == path else ':100644 100644'} {'c' * 40} {'d' * 40} "
                          f"{status if item == path else 'M'}\0{item}\0" for item in paths)
            if extra:
                raw += f":100644 100644 {'c' * 40} {'d' * 40} M\0unreported.swift\0"
            def git(*args):
                if args[0] == "diff":
                    return raw
                if args[0] == "show":
                    revision, item = args[1].split(":", 1)
                    return changes[item][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        with patch.object(scope, "CAT_NOTE_DIGESTS", digests):
            self.assertEqual(selected(), scope.REVIEWED_CAT_NOTE_SCOPE)
            self.assertEqual(selected(extra=True), scope.FULL_SCOPE)
            for path in paths:
                for modes, status in ((":000000 100644", "A"), (":100644 000000", "D"),
                                      (":100644 100755", "M"), (":100644 120000", "T"),
                                      (":100644 100644", "R100"), (":100644 100644", "C100")):
                    self.assertEqual(selected(path, modes, status), scope.FULL_SCOPE)
        # The same raw-diff gate covers every repair companion before content
        # approval; a source matcher cannot approve additions, links or renames.
        changes.update({path: ("before", "after") for path in scope.CAT_NOTE_REPAIR_PATHS})
        paths = sorted(changes)
        with patch.object(scope, "reviewed_cat_note_changes", return_value=True):
            self.assertEqual(selected(), scope.REVIEWED_CAT_NOTE_SCOPE)
            for path in scope.CAT_NOTE_REPAIR_PATHS:
                for modes, status in ((":000000 100644", "A"), (":100644 100755", "M"),
                                      (":100644 120000", "T"), (":100644 100644", "R100")):
                    self.assertEqual(selected(path, modes, status), scope.FULL_SCOPE)

    def test_cat_note_eleven_existing_operations_keep_safety_jobs_and_distinct_evidence(self):
        selected = scope.REVIEWED_CAT_NOTE_SCOPE
        tests = scope.native_tests(selected)
        self.assertEqual(len(tests), 11)
        self.assertEqual(len(set(tests)), 11)
        self.assertFalse(any("testAlbum" in test or "testPhotosOpenEachCats" in test for test in tests))
        root = Path(__file__).resolve().parents[2]
        self.assertTrue(scope.memory_tests_available((root / scope.MEMORY_TEST_PATH).read_text(encoding="utf-8"), tests))
        required = planner.required_jobs(list(self.cat_note_changes()), selected)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected))
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(scope.smoke_tests(selected),
                         ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",
                          "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary"))
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"}
                for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        self.assertTrue(planner.covers_jobs(self.jobs, required, self.sha))
        for other in (scope.FULL_SCOPE, scope.REVIEWED_MEMORY_FAMILY_SCOPE):
            self.assertFalse(planner.covers_jobs(jobs, planner.required_jobs_from_scope(other), self.sha))
        self.assertFalse(planner.covers_jobs(jobs, required, "b" * 40))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            self.assertFalse(planner.covers_jobs(jobs + [jobs[index]], required, self.sha))
            for conclusion in ("failure", "skipped", "cancelled"):
                altered = copy.deepcopy(jobs); altered[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(altered, required, self.sha))

    @staticmethod
    def memory_changes():
        classes = {}
        for identifier in scope.REVIEWED_MEMORY_TESTS:
            _, owner, method = identifier.split("/")
            classes.setdefault(owner, []).append(f"    func {method}() {{}}")
        source = "\n".join(f"final class {owner}: XCTestCase {{\n" + "\n".join(methods) + "\n}"
                           for owner, methods in classes.items())
        changes = {path: ("before", source if path == scope.MEMORY_TEST_PATH else "after")
                   for path in scope.REVIEWABLE_MEMORY_PATHS}
        review = {"schemaVersion": 1, "scope": scope.REVIEWED_MEMORY_SCOPE,
                  "purpose": "Reviewed personal memory reading experience", "visualReview": "user-device",
                  "dataReview": "read-only-projection",
                  "files": {path: {"before": scope.source_digest(pair[0]), "after": scope.source_digest(pair[1])}
                            for path, pair in changes.items()}}
        changes[scope.REVIEW_MANIFEST] = ("{}", json.dumps(review))
        return changes

    def test_diagnostic_extension_hashes_preserve_normal_execution_and_reject_unreviewed_commands(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / scope.CI_DIAGNOSTIC_WORKFLOW).read_text(encoding="utf-8")
        matrix = (root / scope.CI_DIAGNOSTIC_MATRIX).read_text(encoding="utf-8")
        self.assertEqual(scope.source_digest(workflow), scope.DIAGNOSTIC_WORKFLOW_DIGEST)
        changes = {scope.CI_DIAGNOSTIC_WORKFLOW: (workflow, workflow),
                   scope.CI_DIAGNOSTIC_MATRIX: (matrix, matrix)}
        self.assertTrue(scope.ci_selection_only(changes))
        for path, token in ((scope.CI_DIAGNOSTIC_WORKFLOW, "timeout-minutes: 30"),
                            (scope.CI_DIAGNOSTIC_MATRIX, "DIAGNOSTIC_REQUESTED=false"),
                            (scope.CI_DIAGNOSTIC_MATRIX, 'COMPOSER_TEST_ARGUMENTS=()')):
            changed = dict(changes)
            source = changes[path][1]
            changed[path] = (source, source.replace(token, token + " # unreviewed", 1))
            self.assertFalse(scope.ci_selection_only(changed))

    def test_family_companion_is_exact_reviewed_presentation_and_keeps_every_memory_operation(self):
        changes = self.memory_changes()
        # Synthetic full sources exercise the hash boundary; production hashes
        # remain fixed to the independently reviewed FamilyRecordView pair.
        family_pair = ("existing family view", "reviewed family presentation")
        changes[scope.FAMILY_PRESENTATION_PATH] = family_pair
        changes[scope.PAIRING_EXPLANATION_PATH] = (
            "existing\n" + scope.PAIRING_EXPLANATION_BEFORE + "\nunchanged revocation",
            "existing\n" + scope.PAIRING_EXPLANATION_AFTER + "\nunchanged revocation")
        classes = {}
        for identifier in scope.REVIEWED_MEMORY_FAMILY_TESTS:
            _, owner, method = identifier.split("/")
            classes.setdefault(owner, []).append(f"    func {method}() {{}}")
        source = "\n".join(f"final class {owner}: XCTestCase {{\n" + "\n".join(methods) + "\n}"
                           for owner, methods in classes.items())
        changes[scope.MEMORY_TEST_PATH] = ("before", source)
        def reviewed(values, **overrides):
            review = {"schemaVersion": 1, "scope": scope.REVIEWED_MEMORY_FAMILY_SCOPE,
                      "purpose": "Reviewed presentation", "visualReview": "user-device",
                      "dataReview": "read-only-projection",
                      "files": {path: {"before": scope.source_digest(pair[0]), "after": scope.source_digest(pair[1])}
                                for path, pair in values.items() if path != scope.REVIEW_MANIFEST}}
            return dict(values, **{scope.REVIEW_MANIFEST: ("{}", json.dumps(dict(review, **overrides)))})
        with patch.object(scope, "FAMILY_PRESENTATION_DIGESTS", tuple(map(scope.source_digest, family_pair))):
            valid = reviewed(changes)
            self.assertEqual(scope.select_scope(valid), scope.REVIEWED_MEMORY_FAMILY_SCOPE)
            self.assertEqual(scope.native_tests(scope.REVIEWED_MEMORY_FAMILY_SCOPE)[:len(scope.REVIEWED_MEMORY_TESTS)],
                             scope.REVIEWED_MEMORY_TESTS)
            self.assertEqual(len(scope.native_tests(scope.REVIEWED_MEMORY_FAMILY_SCOPE)), 10)
            self.assertEqual(scope.lanes(scope.REVIEWED_MEMORY_FAMILY_SCOPE), scope.lanes(scope.REVIEWED_MEMORY_SCOPE))
            self.assertEqual(planner.required_jobs(list(valid), scope.REVIEWED_MEMORY_FAMILY_SCOPE),
                             planner.required_jobs_from_scope(scope.REVIEWED_MEMORY_FAMILY_SCOPE))
            # Removing a test, mutating a protected body, or falsifying dataReview
            # stays full even with a freshly recalculated manifest.
            for path in scope.FAMILY_COMPANION_PATHS:
                for side in (0, 1):
                    pair = list(changes[path]); pair[side] += "\nchanged write or permission"
                    self.assertEqual(scope.select_scope(reviewed(dict(changes, **{path: tuple(pair)}))), scope.FULL_SCOPE)
                missing = dict(changes); del missing[path]
                self.assertEqual(scope.select_scope(reviewed(missing)), scope.FULL_SCOPE)
            self.assertEqual(scope.select_scope(reviewed(changes, dataReview="unchecked")), scope.FULL_SCOPE)
            self.assertEqual(scope.select_scope(reviewed(changes, scope=scope.REVIEWED_MEMORY_SCOPE)), scope.FULL_SCOPE)
            for identifier in scope.REVIEWED_MEMORY_FAMILY_TESTS:
                altered = dict(changes)
                altered[scope.MEMORY_TEST_PATH] = ("before", source.replace(identifier.split("/")[-1], "absent"))
                self.assertEqual(scope.select_scope(reviewed(altered)), scope.FULL_SCOPE)
            for extra in ("NekoWidget/NekoWidget/Services/FamilyRecordClient.swift",
                          "NekoWidget/Shared/Sharing/FamilyRecordCore.swift"):
                self.assertEqual(scope.select_scope(reviewed(dict(changes, **{extra: ("old", "new")}))), scope.FULL_SCOPE)
            no_test_change = dict(changes); del no_test_change[scope.MEMORY_TEST_PATH]
            self.assertEqual(scope.select_scope(reviewed(no_test_change), memory_test_source=source), scope.REVIEWED_MEMORY_FAMILY_SCOPE)
            self.assertEqual(scope.select_scope(reviewed(no_test_change)), scope.FULL_SCOPE)
            editor_pair = ("existing editor", "reviewed local account guard and DEBUG regression hook")
            with patch.object(scope, "LOCAL_EDITOR_DIGESTS", tuple(map(scope.source_digest, editor_pair))):
                editor = dict(changes, **{scope.LOCAL_EDITOR_PATH: editor_pair})
                valid_editor = reviewed(editor, dataReview=scope.LOCAL_EDITOR_DATA_REVIEW)
                self.assertEqual(scope.select_scope(valid_editor), scope.REVIEWED_MEMORY_FAMILY_SCOPE)
                self.assertEqual(planner.required_jobs(list(valid_editor), scope.REVIEWED_MEMORY_FAMILY_SCOPE),
                                 planner.required_jobs_from_scope(scope.REVIEWED_MEMORY_FAMILY_SCOPE))
                self.assertEqual(len(scope.native_tests(scope.REVIEWED_MEMORY_FAMILY_SCOPE)), 10)
                # Both the whole-source hashes and specific data review are
                # mandatory. Rehashing an unknown editor cannot approve it.
                self.assertEqual(scope.select_scope(reviewed(editor)), scope.FULL_SCOPE)
                self.assertEqual(scope.select_scope(reviewed(editor, dataReview=scope.LOCAL_EDITOR_DATA_REVIEW,
                                                             scope=scope.REVIEWED_MEMORY_SCOPE)), scope.FULL_SCOPE)
                for side in (0, 1):
                    altered = list(editor_pair); altered[side] += " changed account or storage action"
                    unknown = dict(editor, **{scope.LOCAL_EDITOR_PATH: tuple(altered)})
                    self.assertEqual(scope.select_scope(reviewed(unknown, dataReview=scope.LOCAL_EDITOR_DATA_REVIEW)), scope.FULL_SCOPE)
                stale = copy.deepcopy(valid_editor)
                manifest = json.loads(stale[scope.REVIEW_MANIFEST][1])
                manifest["files"][scope.LOCAL_EDITOR_PATH]["after"] = "0" * 64
                stale[scope.REVIEW_MANIFEST] = ("{}", json.dumps(manifest))
                self.assertEqual(scope.select_scope(stale), scope.FULL_SCOPE)
                self.assertEqual(scope.select_scope(reviewed({scope.LOCAL_EDITOR_PATH: editor_pair},
                    dataReview=scope.LOCAL_EDITOR_DATA_REVIEW)), scope.FULL_SCOPE)
                # The planner still rejects added/symlink/executable editor
                # files before the exact reviewed source pair is considered.
                paths = sorted(valid_editor)
                base = "b" * 40
                for old_mode, new_mode, status, allowed in (
                        ("100644", "100644", "M", True), ("000000", "100644", "A", False),
                        ("100644", "120000", "T", False), ("100644", "100755", "M", False)):
                    raw = "".join(f":{old_mode if path == scope.LOCAL_EDITOR_PATH else '100644'} "
                        f"{new_mode if path == scope.LOCAL_EDITOR_PATH else '100644'} {'c' * 40} {'d' * 40} "
                        f"{status if path == scope.LOCAL_EDITOR_PATH else 'M'}\0{path}\0" for path in paths)
                    def git(*args):
                        if args[0] == "diff":
                            return raw
                        if args[0] == "show":
                            revision, path = args[1].split(":", 1)
                            return valid_editor[path][0 if revision == base else 1]
                        return self.sha
                    with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                        self.assertEqual(planner.runtime_scope(paths, {}, self.env),
                                         scope.REVIEWED_MEMORY_FAMILY_SCOPE if allowed else scope.FULL_SCOPE)
        self.assertNotIn(scope.FAMILY_PRESENTATION_PATH, scope.REVIEWABLE_MEMORY_PATHS)
        self.assertNotIn(scope.PAIRING_EXPLANATION_PATH, scope.REVIEWABLE_APP_PATHS)
        self.assertNotIn(scope.LOCAL_EDITOR_PATH, scope.REVIEWABLE_MEMORY_PATHS)
        self.assertNotIn(scope.LOCAL_EDITOR_PATH, scope.REVIEWABLE_APP_PATHS)

    def test_memory_review_requires_exact_complete_batch_and_known_profile(self):
        changes = self.memory_changes()
        self.assertEqual(scope.select_scope(changes), scope.REVIEWED_MEMORY_SCOPE)
        for path in changes:
            with self.subTest(missing=path):
                altered = dict(changes)
                del altered[path]
                self.assertEqual(scope.select_scope(altered), scope.FULL_SCOPE)
        for path in scope.REVIEWABLE_MEMORY_PATHS:
            for index in (0, 1):
                with self.subTest(path=path, side=index):
                    pair = list(changes[path])
                    pair[index] += "unreviewed"
                    self.assertEqual(scope.select_scope(dict(changes, **{path: tuple(pair)})), scope.FULL_SCOPE)
        for extra in ("NekoWidget/NekoWidget/App/AppRootView.swift",
                      "NekoWidget/Shared/Storage/PhotoStore.swift",
                      "NekoWidget/NekoWidget/Services/PersonalArchiveCloudClient.swift",
                      "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift",
                      "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                      "NekoWidget/NekoWidget/Views/FamilyWindowView.swift", scope.CI_WORKFLOW,
                      "NekoWidget/ci/ios_ci_scope.py", "unknown.swift", "../MainTabView.swift"):
            with self.subTest(extra=extra):
                self.assertEqual(scope.select_scope(dict(changes, **{extra: ("before", "after")})), scope.FULL_SCOPE)
                self.assertEqual(planner.required_jobs(list(changes) + [extra], scope.REVIEWED_MEMORY_SCOPE), planner.FULL)
        self.assertEqual(scope.select_scope({path: changes[path] for path in scope.REVIEWABLE_MEMORY_PATHS}),
                         scope.FULL_SCOPE)
        self.assertEqual(scope.select_scope(dict(changes, **{"handoffs/review.md": ("", "review")})),
                         scope.REVIEWED_MEMORY_SCOPE)

    def test_memory_review_rejects_malformed_stale_and_duplicate_manifests(self):
        changes = self.memory_changes()
        review = json.loads(changes[scope.REVIEW_MANIFEST][1])
        malformed = ["[]", "null", "{", json.dumps(dict(review, scope="unknown-v1")),
                     json.dumps(dict(review, scope=scope.REVIEWED_APP_SCOPE)),
                     json.dumps(dict(review, scope="reviewed-memory-read-ui-v1")),
                     json.dumps(dict(review, schemaVersion=2)), json.dumps(dict(review, schemaVersion=True)),
                     json.dumps(dict(review, purpose=" ")), json.dumps(dict(review, visualReview="none")),
                     json.dumps(dict(review, dataReview="unchecked")),
                     json.dumps({k: v for k, v in review.items() if k != "dataReview"}),
                     json.dumps(dict(review, files={})), json.dumps(dict(review, tests=[])),
                     changes[scope.REVIEW_MANIFEST][1][:-1] + ', "purpose": "duplicate"}']
        path = next(iter(scope.REVIEWABLE_MEMORY_PATHS))
        stale = copy.deepcopy(review)
        stale["files"][path]["after"] = "f" * 64
        malformed.append(json.dumps(stale))
        for manifest in malformed:
            with self.subTest(manifest=manifest):
                self.assertEqual(scope.select_scope(dict(changes, **{scope.REVIEW_MANIFEST: ("{}", manifest)})),
                                 scope.FULL_SCOPE)

    def test_memory_review_requires_all_selected_test_methods_in_head(self):
        changes = self.memory_changes()
        for test in scope.REVIEWED_MEMORY_TESTS:
            for duplicate in (False, True):
                altered = copy.deepcopy(changes)
                path = scope.MEMORY_TEST_PATH
                before, after = altered[path]
                method = test.rsplit("/", 1)[1]
                declaration = f"    func {method}() {{}}"
                after = after.replace(declaration, declaration * 2 if duplicate else "")
                altered[path] = (before, after)
                review = json.loads(altered[scope.REVIEW_MANIFEST][1])
                review["files"][path]["after"] = scope.source_digest(after)
                altered[scope.REVIEW_MANIFEST] = ("{}", json.dumps(review))
                with self.subTest(test=test, duplicate=duplicate):
                    self.assertEqual(scope.select_scope(altered), scope.FULL_SCOPE)

    def test_memory_single_file_review_reads_fixed_test_dependency_from_head(self):
        full = self.memory_changes()
        source = full[scope.MEMORY_TEST_PATH][1]
        for path in scope.REVIEWABLE_MEMORY_PATHS - scope.MEMORY_PROJECTION_PATHS:
            review = json.loads(full[scope.REVIEW_MANIFEST][1])
            review["files"] = {path: review["files"][path]}
            changes = {path: full[path], scope.REVIEW_MANIFEST: ("{}", json.dumps(review))}
            self.assertEqual(scope.select_scope(changes, memory_test_source=source),
                             scope.REVIEWED_MEMORY_SCOPE)
            if path == scope.MEMORY_TEST_PATH:
                continue
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
            paths = sorted(changes)
            base = "b" * 40
            raw = "".join(f":100644 100644 {'c' * 40} {'d' * 40} M\0{item}\0" for item in paths)
            for dependency in (source, source.replace("testMemoryLibraryEntryReadsEditsAndOpensTheOriginalPhoto", "absent"), None):
                def git(*args):
                    if args[0] == "diff":
                        return raw
                    if args[0] == "show":
                        revision, item = args[1].split(":", 1)
                        if item == scope.MEMORY_TEST_PATH:
                            self.assertEqual(revision, self.sha)
                            if dependency is None:
                                raise subprocess.CalledProcessError(1, ["git", *args])
                            return dependency
                        return changes[item][0 if revision == base else 1]
                    return self.sha
                with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                    self.assertEqual(planner.runtime_scope(paths, {}, self.env),
                                     scope.REVIEWED_MEMORY_SCOPE if dependency == source else scope.FULL_SCOPE)

    def test_memory_projection_requires_the_exact_store_and_existing_verifier_together(self):
        full = self.memory_changes()
        source = full[scope.MEMORY_TEST_PATH][1]
        review = json.loads(full[scope.REVIEW_MANIFEST][1])
        for paths in (scope.MEMORY_PROJECTION_PATHS, *({p} for p in scope.MEMORY_PROJECTION_PATHS)):
            manifest = dict(review, files={p: review["files"][p] for p in paths})
            changes = {p: full[p] for p in paths}
            changes[scope.REVIEW_MANIFEST] = ("{}", json.dumps(manifest))
            self.assertEqual(scope.select_scope(changes, memory_test_source=source),
                             scope.REVIEWED_MEMORY_SCOPE if paths == scope.MEMORY_PROJECTION_PATHS else scope.FULL_SCOPE)
        # An unknown named profile with only a legacy-allowed UI path must not
        # silently downgrade to the older four-test profile.
        path = "NekoWidget/NekoWidget/Views/MainTabView.swift"
        for claimed in (scope.REVIEWED_MEMORY_SCOPE, "unknown-v1", scope.REVIEWED_APP_SCOPE):
            manifest = dict(review, scope=claimed, files={path: review["files"][path]})
            manifest.pop("dataReview")
            self.assertEqual(scope.select_scope({path: full[path], scope.REVIEW_MANIFEST: ("{}", json.dumps(manifest))},
                                               memory_test_source=source), scope.FULL_SCOPE)

    def test_memory_allowlist_and_current_test_declarations_are_explicit(self):
        self.assertEqual(scope.REVIEWABLE_MEMORY_PATHS, {
            "NekoWidget/NekoWidget/Views/PhotoMemoryNoteLibraryView.swift",
            "NekoWidget/NekoWidget/Views/PersonalArchiveView.swift",
            "NekoWidget/NekoWidget/Views/LikedPhotosView.swift",
            "NekoWidget/NekoWidget/Views/MainTabView.swift",
            "NekoWidget/NekoWidget/Views/HomeView.swift",
            "NekoWidget/NekoWidget/Views/SettingsView.swift",
            "NekoWidget/NekoWidget/App/AppStoreScreenshotFixture.swift",
            "NekoWidget/NekoWidgetUITests/AppStoreScreenshotUITests.swift",
            "NekoWidget/ci/test-family-window-widget-boundaries.py",
            "NekoWidget/ci/test-app-store-screenshot-workflow.py",
            "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift",
            "NekoWidget/NekoWidget/Services/PersonalArchiveStore.swift",
            "NekoWidget/ci/verify-personal-archive.swift",
        })
        root = Path(__file__).resolve().parents[2]
        source = (root / scope.MEMORY_TEST_PATH).read_text(encoding="utf-8")
        self.assertTrue(scope.memory_tests_available(source))

    def test_memory_test_names_in_comments_and_strings_do_not_count(self):
        changes = self.memory_changes()
        path = scope.MEMORY_TEST_PATH
        before, source = changes[path]
        declaration = "func testMemoryLibraryEntryReadsEditsAndOpensTheOriginalPhoto() {}"
        class_declaration = "final class MomentDeliveryComposerUITests: XCTestCase {"
        hidden = (
            source.replace(declaration, "// " + declaration),
            source.replace(declaration, "/* " + declaration + " */"),
            source.replace(declaration, "/* outer /* nested */ " + declaration + " */"),
            source.replace(declaration, 'let text = "' + declaration + '"'),
            source.replace(declaration, 'let text = "value \\(flag ? "' + declaration + '" : "b")"'),
            source.replace(declaration, 'let text = """\n' + declaration + '\n"""'),
            source.replace(declaration, 'let text = #"' + declaration + '"#'),
            source.replace(class_declaration, "// " + class_declaration),
            source.replace(class_declaration, "/* " + class_declaration + " */"),
            source.replace(class_declaration, 'let text = "' + class_declaration + '"'),
            'let text = """\n' + source + '\n"""',
            'let text = #"""\n' + source + '\n"""#',
            "#if false\n" + source + "\n#endif",
            source + "\n/* unterminated",
            source + '\nlet text = "unterminated',
        )
        for after in hidden:
            altered = copy.deepcopy(changes)
            altered[path] = (before, after)
            review = json.loads(altered[scope.REVIEW_MANIFEST][1])
            review["files"][path]["after"] = scope.source_digest(after)
            altered[scope.REVIEW_MANIFEST] = ("{}", json.dumps(review))
            with self.subTest(source=after):
                self.assertFalse(scope.memory_tests_available(after))
                self.assertEqual(scope.select_scope(altered), scope.FULL_SCOPE)
        # Decoys beside real declarations must not become duplicate methods.
        decoys = ('\n// ' + declaration + '\n/* ' + class_declaration + ' */\n'
                  + 'let text = "' + declaration + '"\n'
                  + 'let interpolation = "value \\(flag ? "' + declaration + '" : "b")"\n')
        self.assertTrue(scope.memory_tests_available(source + decoys))

    def test_memory_planner_rejects_added_deleted_renamed_and_nonregular_files(self):
        changes = self.memory_changes()
        paths = sorted(changes)
        base = "b" * 40
        def selected(headers):
            raw = "".join(f"{headers.get(path, ':100644 100644')} {'c' * 40} {'d' * 40} M\0{path}\0"
                          for path in paths)
            def git(*args):
                if args[0] == "diff":
                    return raw
                if args[0] == "show":
                    revision, path = args[1].split(":", 1)
                    return changes[path][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        self.assertEqual(selected({}), scope.REVIEWED_MEMORY_SCOPE)
        for path in paths:
            for modes in (":000000 100644", ":100644 000000", ":100644 100755", ":100644 120000"):
                self.assertEqual(selected({path: modes}), scope.FULL_SCOPE)
        # Status is checked independently of modes, including copy/rename.
        for status in ("A", "D", "R100", "C100", "T"):
            raw = "".join(f":100644 100644 {'c' * 40} {'d' * 40} {status}\0{path}\0" for path in paths)
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", return_value=raw):
                self.assertEqual(planner.runtime_scope(paths, {}, self.env), scope.FULL_SCOPE)
        self.assertEqual(planner.runtime_scope(paths, {}, dict(self.env, GITHUB_EVENT_NAME="workflow_dispatch")),
                         scope.FULL_SCOPE)

    def test_memory_selection_keeps_safety_jobs_and_cannot_supply_full_evidence(self):
        selected = scope.REVIEWED_MEMORY_SCOPE
        changes = self.memory_changes()
        required = planner.required_jobs(list(changes), selected)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected))
        self.assertEqual(scope.smoke_tests(selected),
                         ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",
                          "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary"))
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(scope.matrix_lanes(selected), ("runtime",))
        tests = scope.lane_tests(selected, "app-ui")
        self.assertEqual(len(tests), 8)
        self.assertEqual(len(set(tests)), 8)
        self.assertIn("NekoWidgetUITests/SoloMemoriesUITests/testPhotosOpenEachCatsPhotosDirectlyAndKeepManagementInSettings", tests)
        self.assertIn("NekoWidgetUITests/SoloMemoriesUITests/testEmptyAndSingleFavoriteRemainReachableIncludingDeniedAccess", tests)
        full = scope.native_tests(scope.FULL_SCOPE)
        for test in tests:
            self.assertTrue(any(test.startswith(suite + "/") for suite in full), test)
        for gallery in scope.LANES[2:]:
            with self.assertRaises(ValueError):
                scope.lane_tests(selected, gallery)
        jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success"}
                for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        self.assertTrue(planner.covers_jobs(self.jobs, required, self.sha))
        old_jobs = [dict(job, name=job["name"].replace("reviewed-memory-read-ui-v2", "reviewed-memory-read-ui-v1"))
                    for job in jobs]
        self.assertFalse(planner.covers_jobs(old_jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, planner.FULL, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, planner.required_jobs_from_scope(scope.REVIEWED_APP_SCOPE), self.sha))
        self.assertFalse(planner.covers_jobs(jobs, required, "b" * 40))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            self.assertFalse(planner.covers_jobs(jobs + [jobs[index]], required, self.sha))
            for conclusion in ("failure", "skipped", "cancelled"):
                altered = copy.deepcopy(jobs)
                altered[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(altered, required, self.sha))

    def archive_picker_batch(self):
        changes = {path: ("before " + path, "after " + path)
                   for path in scope.ARCHIVE_PICKER_PATHS}
        manifest = {"schemaVersion": 1, "scope": scope.ARCHIVE_PICKER_SCOPE,
                    "purpose": "Reviewed screen-owned picker and seeded real-picker regression",
                    "files": {path: {"before": scope.source_digest(pair[0]),
                                     "after": scope.source_digest(pair[1])}
                              for path, pair in changes.items()}}
        changes[scope.ARCHIVE_PICKER_MANIFEST] = ("{}", json.dumps(manifest))
        return changes

    def test_archive_picker_requires_exact_review_of_complete_batch(self):
        changes = self.archive_picker_batch()
        self.assertEqual(scope.select_scope(changes), scope.ARCHIVE_PICKER_SCOPE)
        for path in changes:
            self.assertEqual(scope.select_scope({p: v for p, v in changes.items() if p != path}),
                             scope.FULL_SCOPE)
        for path in scope.ARCHIVE_PICKER_PATHS:
            for pair in ((changes[path][0] + "stale", changes[path][1]),
                         (changes[path][0], changes[path][1] + "extra")):
                self.assertEqual(scope.select_scope(dict(changes, **{path: pair})), scope.FULL_SCOPE)
        for path in (scope.REVIEW_MANIFEST, "NekoWidget/ci/ios_ci_scope.py",
                     "NekoWidget/NekoWidget/Services/PersonalArchiveStore.swift",
                     "NekoWidget/NekoWidget/App/AppRootView.swift", "../unsafe.swift"):
            self.assertEqual(scope.select_scope(dict(changes, **{path: ("a", "b")})), scope.FULL_SCOPE)
        for malformed in ("[]", "null", "{", "{}", changes[scope.ARCHIVE_PICKER_MANIFEST][1]
                          .replace(scope.ARCHIVE_PICKER_SCOPE, scope.REVIEWED_APP_SCOPE)):
            self.assertEqual(scope.select_scope(dict(changes, **{
                scope.ARCHIVE_PICKER_MANIFEST: ("{}", malformed)})), scope.FULL_SCOPE)

    def test_archive_picker_keeps_build_photo_scan_and_two_os_runtime(self):
        selected = scope.ARCHIVE_PICKER_SCOPE
        required = (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(selected)
        self.assertEqual(planner.required_jobs(list(self.archive_picker_batch()), selected), required)
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(scope.lane_tests(selected, "app-ui"), (
            "NekoWidgetUITests/SoloMemoriesUITests/testPersonalArchiveRestoresPhotoAndTextAndExplicitlySavesNewText",))
        self.assertEqual(scope.smoke_tests(selected),
            ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",
                          "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary"))
        # Existing metadata test iterates every scope and requires both runtime OSes.
        jobs = [dict(name=name, head_sha=self.sha, status="completed", conclusion="success")
                for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, planner.FULL, self.sha))
        self.assertFalse(planner.covers_jobs(jobs, planner.required_jobs_from_scope(scope.REVIEWED_APP_SCOPE), self.sha))
        self.assertFalse(planner.covers_jobs(jobs, required, "b" * 40))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, self.sha))
            for conclusion in ("skipped", "failure", "cancelled"):
                altered = copy.deepcopy(jobs)
                altered[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(altered, required, self.sha))
        self.assertFalse(planner.covers_jobs(jobs + [jobs[-1]], required, self.sha))

    def test_archive_picker_raw_modes_and_manual_dispatch_fail_closed(self):
        changes = self.archive_picker_batch()
        paths = sorted(changes)
        base = "b" * 40
        def select(header=":100644 100644", status="M", event_name="push"):
            def git(*args):
                if args[0] == "diff":
                    return "".join(f"{header if i == 0 else ':100644 100644'} {base} {self.sha} "
                                   f"{status if i == 0 else 'M'}\0{p}\0" for i, p in enumerate(paths))
                if args[0] == "show":
                    revision, path = args[1].split(":", 1)
                    return changes[path][0 if revision == base else 1]
                return self.sha
            env = dict(self.env, GITHUB_EVENT_NAME=event_name)
            with patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {"before": base}, env)
        self.assertEqual(select(), scope.ARCHIVE_PICKER_SCOPE)
        for header, status in ((":000000 100644", "A"), (":100644 000000", "D"),
                               (":100644 100755", "M"), (":100644 120000", "T")):
            self.assertEqual(select(header, status), scope.FULL_SCOPE)
        self.assertEqual(select(event_name="workflow_dispatch"), scope.FULL_SCOPE)

    def test_empty_archive_manifest_allows_ci_candidate_but_not_product_exemption(self):
        manifest = json.dumps({"schemaVersion": 1, "scope": scope.ARCHIVE_PICKER_SCOPE,
                               "purpose": "Inactive CI candidate", "files": {}})
        self.assertEqual(scope.select_scope({scope.ARCHIVE_PICKER_MANIFEST: ("", manifest),
            "NekoWidget/ci/ios_ci_scope.py": ("old selection", "new selection")}), scope.CI_SELECTION_SCOPE)
        self.assertEqual(scope.select_scope(dict(self.archive_picker_batch(), **{
            scope.ARCHIVE_PICKER_MANIFEST: ("{}", manifest)})), scope.FULL_SCOPE)

    def test_reviewed_app_batch_requires_exact_contents_and_entire_change_set(self):
        path = "NekoWidget/NekoWidget/Views/MainTabView.swift"
        pair = ("old app body\n", "new app body\n")
        manifest = json.dumps({"schemaVersion": 1, "purpose": "User reviews visual layout on device",
            "visualReview": "user-device", "files": {
                path: {"before": scope.source_digest(pair[0]), "after": scope.source_digest(pair[1])}}})
        changes = {path: pair, scope.REVIEW_MANIFEST: ("{}", manifest)}
        self.assertEqual(scope.select_scope(changes), scope.REVIEWED_APP_SCOPE)
        # Without a visual-review manifest, app-only views retain every app UI
        # suite and smoke check, while Widget Gallery does not run.
        self.assertEqual(scope.select_scope({path: pair}), scope.APP_VIEW_SCOPE)
        for altered in (
            dict(changes, **{path: (pair[0] + "unreviewed", pair[1])}),
            dict(changes, **{path: (pair[0], pair[1] + "unreviewed")}),
            dict(changes, **{"NekoWidget/Shared/Storage/AtomicJSON.swift": ("a", "b")}),
            dict(changes, **{"NekoWidget/NekoWidget/Views/HomeView.swift": ("a", "b")}),
            dict(changes, **{"NekoWidget/ci/ios_ci_scope.py": ("a", "b")}),
            dict(changes, **{scope.REVIEW_MANIFEST: ("{}", "[]")}),
            dict(changes, **{scope.REVIEW_MANIFEST: ("{}", manifest.replace("user-device", "none"))}),
        ):
            self.assertEqual(scope.select_scope(altered), scope.FULL_SCOPE)
        self.assertEqual(planner.required_jobs(list(changes), scope.REVIEWED_APP_SCOPE),
            (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.REVIEWED_APP_SCOPE))
        self.assertEqual(scope.lanes(scope.REVIEWED_APP_SCOPE), ("runtime", "app-ui"))
        self.assertEqual(len(scope.native_tests(scope.REVIEWED_APP_SCOPE)), 4)

    def test_reviewed_evidence_does_not_cover_full_or_missing_checks(self):
        jobs = [{"name": name, "head_sha": "a" * 40, "status": "completed", "conclusion": "success"}
                for name in planner.required_jobs_from_scope(scope.REVIEWED_APP_SCOPE)]
        self.assertTrue(planner.covers_jobs(jobs, tuple(j["name"] for j in jobs), "a" * 40))
        self.assertFalse(planner.covers_jobs(jobs, planner.FULL, "a" * 40))
        self.assertFalse(planner.covers_jobs(jobs[:-1], tuple(j["name"] for j in jobs), "a" * 40))

    @staticmethod
    def cat_entry_changes(companion=None):
        before = ('func configure() {\n'
                  '        bar.placeholder = "言葉・猫の名前で探す"\n'
                  '        bar.delegate = context.coordinator\n}\n')
        changes = {
            scope.CAT_ENTRY_PATH: ("old cat list", "new cat list"),
            scope.CAT_ENTRY_SEARCH_COMPANION: companion or (
                before, before.replace('"言葉・猫の名前で探す"', '"メモを検索"')),
        }
        review = {"schemaVersion": 1, "purpose": "Cat list and exact search placeholder",
                  "visualReview": "user-device",
                  "files": {path: {"before": scope.source_digest(pair[0]), "after": scope.source_digest(pair[1])}
                            for path, pair in changes.items()}}
        changes[scope.REVIEW_MANIFEST] = ("{}", json.dumps(review))
        return changes

    def test_cat_entry_exact_placeholder_keeps_existing_four_operations_and_safety_jobs(self):
        changes = self.cat_entry_changes()
        self.assertEqual(scope.select_scope(changes), scope.REVIEWED_APP_SCOPE)
        self.assertNotIn(scope.CAT_ENTRY_SEARCH_COMPANION, scope.REVIEWABLE_APP_PATHS)
        self.assertNotIn(scope.CAT_ENTRY_SEARCH_COMPANION, scope.PHOTO_VIEWS)
        self.assertEqual(planner.required_jobs(list(changes), scope.REVIEWED_APP_SCOPE),
                         (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.REVIEWED_APP_SCOPE))
        self.assertEqual(len(scope.native_tests(scope.REVIEWED_APP_SCOPE)), 4)
        self.assertEqual(scope.lanes(scope.REVIEWED_APP_SCOPE), ("runtime", "app-ui"))

    def test_cat_entry_companion_rejects_other_changes_even_with_matching_hashes(self):
        before, after = self.cat_entry_changes()[scope.CAT_ENTRY_SEARCH_COMPANION]
        for pair in (
            (before, after.replace('"メモを検索"', '"別の検索"')),
            (before, after.replace("bar.delegate = context.coordinator", "bar.delegate = nil")),
            (before, after + "// another changed line\n"),
            (before + before, after + after),
            (before.replace('        bar.placeholder = "言葉・猫の名前で探す"\n',
                            '        bar.placeholder = "言葉・猫の名前で探す"\n' * 2),
             after.replace('        bar.placeholder = "メモを検索"\n',
                           '        bar.placeholder = "メモを検索"\n'
                           '        bar.placeholder = "言葉・猫の名前で探す"\n')),
            (after, before),
            (before, before),
        ):
            with self.subTest(pair=pair):
                self.assertEqual(scope.select_scope(self.cat_entry_changes(pair)), scope.FULL_SCOPE)
        changes = self.cat_entry_changes()
        for missing in (scope.CAT_ENTRY_PATH, scope.REVIEW_MANIFEST):
            altered = dict(changes)
            del altered[missing]
            if missing != scope.REVIEW_MANIFEST:
                review = json.loads(altered[scope.REVIEW_MANIFEST][1])
                del review["files"][missing]
                altered[scope.REVIEW_MANIFEST] = ("{}", json.dumps(review))
            self.assertEqual(scope.select_scope(altered),
                             scope.APP_VIEW_SCOPE if missing == scope.REVIEW_MANIFEST else scope.FULL_SCOPE)
        self.assertFalse(scope.accepts_paths(scope.REVIEWED_APP_SCOPE,
                                            {scope.CAT_ENTRY_SEARCH_COMPANION, scope.REVIEW_MANIFEST}))
        for side in (0, 1):
            altered = dict(changes)
            pair = list(altered[scope.CAT_ENTRY_SEARCH_COMPANION])
            pair[side] += "unreviewed"
            altered[scope.CAT_ENTRY_SEARCH_COMPANION] = tuple(pair)
            self.assertEqual(scope.select_scope(altered), scope.FULL_SCOPE)
        for side in ("before", "after"):
            review = json.loads(changes[scope.REVIEW_MANIFEST][1])
            review["files"][scope.CAT_ENTRY_SEARCH_COMPANION][side] = "f" * 64
            altered = dict(changes, **{scope.REVIEW_MANIFEST: ("{}", json.dumps(review))})
            self.assertEqual(scope.select_scope(altered), scope.FULL_SCOPE)

    def test_cat_entry_companion_still_requires_existing_regular_files(self):
        changes = self.cat_entry_changes()
        paths = sorted(changes)
        base = "b" * 40
        def selected(header=":100644 100644", status="M"):
            raw = "".join(
                f"{header if path == scope.CAT_ENTRY_SEARCH_COMPANION else ':100644 100644'} "
                f"{'c' * 40} {'d' * 40} {status if path == scope.CAT_ENTRY_SEARCH_COMPANION else 'M'}\0{path}\0"
                for path in paths)
            def git(*args):
                if args[0] == "diff":
                    return raw
                if args[0] == "show":
                    revision, path = args[1].split(":", 1)
                    return changes[path][0 if revision == base else 1]
                return self.sha
            with patch.object(planner, "comparison_base", return_value=base), patch.object(planner, "git", side_effect=git):
                return planner.runtime_scope(paths, {}, self.env)
        self.assertEqual(selected(), scope.REVIEWED_APP_SCOPE)
        for header, status in ((":000000 100644", "A"), (":100644 000000", "D"),
                               (":100644 100755", "M"), (":100644 120000", "T"),
                               (":100644 100644", "R100")):
            with self.subTest(header=header, status=status):
                self.assertEqual(selected(header, status), scope.FULL_SCOPE)

    def setUp(self):
        self.sha = "a" * 40
        self.now = dt.datetime(2026, 9, 7, 12, tzinfo=dt.timezone.utc)
        self.env = {
            "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main",
            "GITHUB_SHA": self.sha, "GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "20",
        }
        self.current = {"id": 20, "workflow_id": 5, "head_sha": self.sha}
        self.run = dict(self.current, id=10, event="push", head_branch="codex/movie",
                        status="completed", conclusion="success", updated_at="2026-09-07T11:00:00Z",
                        repository={"full_name": "owner/repo"}, head_repository={"full_name": "owner/repo"})
        self.jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success",
                      "completed_at": "2026-09-07T11:00:00Z"}
                     for name in planner.FULL]
        checkout = patch.object(planner, "git", return_value=self.sha)
        checkout.start()
        self.addCleanup(checkout.stop)

    def test_movie_screen_keeps_build_and_boundary_tests(self):
        for paths in ([planner.MOVIE_VIEW], [planner.MOVIE_ADR, planner.MOVIE_VIEW]):
            self.assertEqual(planner.required_jobs(paths), (planner.BUILD,))

    def test_unknown_mixed_deleted_or_policy_paths_keep_full_checks(self):
        for extra in (
            "NekoWidget/NekoWidget/Services/SeasonalMovieExportService.swift",
            "NekoWidget/NekoWidget/Views/OnboardingView.swift",
            "NekoWidget/Shared/Storage/AtomicJSON.swift",
            ".github/workflows/ios-build.yml", "NekoWidget/Config.xcconfig",
            "NekoWidget/NekoWidget/Info.plist", "NekoWidget/ci/plan-ios-ci.py",
            "AGENTS.md", "unknown.swift",
        ):
            with self.subTest(extra=extra):
                self.assertEqual(planner.required_jobs([planner.MOVIE_VIEW, extra]), planner.FULL)
        for paths in (None, [], [planner.MOVIE_ADR]):
            self.assertEqual(planner.required_jobs(paths), planner.FULL)

    def test_run_identity_event_freshness_and_completion_are_required(self):
        self.assertTrue(planner.reusable_run(self.run, self.current, "owner/repo", self.now))
        for field, value in (
            ("id", 20), ("workflow_id", 9), ("head_sha", "b" * 40),
            ("event", "pull_request"), ("head_branch", "main"),
            ("head_repository", {"full_name": "outsider/fork"}),
            ("repository", {"full_name": "outsider/fork"}),
            ("status", "in_progress"), ("conclusion", "cancelled"),
            ("conclusion", "failure"), ("updated_at", "2026-09-05T11:00:00Z"),
            ("updated_at", "2026-09-08T11:00:00Z"), ("updated_at", "invalid"),
            ("updated_at", None), ("head_branch", None),
            ("head_sha", "invalid"), ("head_sha", None),
        ):
            with self.subTest(field=field, value=value):
                self.assertFalse(planner.reusable_run(dict(self.run, **{field: value}), self.current, "owner/repo", self.now))
        self.assertFalse(planner.reusable_run({}, self.current, "owner/repo", self.now))

    def test_required_jobs_must_have_actually_executed(self):
        self.assertTrue(planner.covers_jobs(self.jobs, planner.FULL, self.sha))
        for conclusion in ("skipped", "failure", "cancelled", None):
            jobs = copy.deepcopy(self.jobs)
            jobs[0]["conclusion"] = conclusion
            self.assertFalse(planner.covers_jobs(jobs, planner.FULL, self.sha))
        self.assertFalse(planner.covers_jobs(self.jobs[1:], planner.FULL, self.sha))
        self.assertFalse(planner.covers_jobs(self.jobs + self.jobs, planner.FULL, self.sha))
        self.assertFalse(planner.covers_jobs(self.jobs, planner.FULL, "b" * 40))
        self.assertFalse(planner.covers_jobs(self.jobs[:1], planner.FULL, self.sha))
        self.assertTrue(planner.covers_jobs(self.jobs[:1], (planner.BUILD,), self.sha))

    def api(self, path):
        if path.endswith("/runs/20"):
            return self.current
        if "/workflows/ios-build.yml/runs?" in path:
            return {"workflow_runs": [self.run]}
        if "/runs/10/jobs?filter=latest" in path:
            return {"total_count": len(self.jobs), "jobs": self.jobs}
        self.fail(f"Unexpected API endpoint: {path}")

    def test_resolution_main_reuse_also_requires_same_candidate_backends(self):
        required = planner.required_jobs_from_scope(planner.MODERATION_RESOLUTION_SCOPE)
        self.jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success",
                      "completed_at": "2026-09-07T11:00:00Z"} for name in required]
        with patch.object(planner, "moderation_resolution_backend_evidence", return_value={}) as backend:
            self.assertEqual(planner.find_evidence(self.env, required, self.api, self.now), (10, self.sha))
            self.assertEqual(backend.call_args.args[:2], (self.sha, "owner/repo"))
            self.assertEqual(backend.call_args.kwargs, {"branch": "codex/movie"})
        with patch.object(planner, "moderation_resolution_backend_evidence", side_effect=ValueError("missing")), self.assertRaises(ValueError):
            planner.find_evidence(self.env, required, self.api, self.now)

    def test_tool_preservation_main_reuse_requires_its_own_candidate_backend(self):
        required = planner.required_jobs_from_scope(planner.TOOL_PRESERVATION_SCOPE)
        self.assertFalse(any(planner.required_jobs_from_scope(selected) == required
                             for selected in planner.SCOPES if selected != planner.TOOL_PRESERVATION_SCOPE))
        self.assertIsNone(planner.test_correction_scope(required))
        self.jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success",
                      "completed_at": "2026-09-07T11:00:00Z"} for name in required]
        with patch.object(planner, "tool_preservation_backend_evidence", return_value={}) as backend:
            self.assertIsNone(planner.find_evidence(self.env, required, self.api, self.now))
            backend.assert_not_called()
        with patch.object(planner, "tool_preservation_backend_evidence", side_effect=AssertionError("unrelated scope")):
            self.jobs = [{"name": name, "head_sha": self.sha, "status": "completed", "conclusion": "success",
                          "completed_at": "2026-09-07T11:00:00Z"} for name in planner.FULL]
            self.assertEqual(planner.find_evidence(self.env, planner.FULL, self.api, self.now), (10, self.sha))

    def test_main_uses_exact_commit_evidence(self):
        self.assertEqual(planner.find_evidence(self.env, planner.FULL, self.api, self.now), (10, self.sha))
        # A prior narrow check cannot stand in for newly required full coverage.
        self.jobs = self.jobs[:1]
        self.assertIsNone(planner.find_evidence(self.env, planner.FULL, self.api, self.now))

    def test_ancestor_evidence_still_requires_candidate_job_sha_and_provenance(self):
        candidate = "b" * 40
        self.run["head_sha"] = candidate
        with patch.object(planner, "equivalent_inputs", return_value=True):
            # Jobs for the current SHA cannot impersonate execution on candidate.
            self.assertIsNone(planner.find_evidence(self.env, planner.FULL, self.api, self.now))
            for job in self.jobs:
                job["head_sha"] = candidate
            self.assertEqual(planner.find_evidence(self.env, planner.FULL, self.api, self.now), (10, candidate))
            for field, value in (("workflow_id", 9), ("event", "pull_request"),
                                 ("head_branch", "main"), ("conclusion", "failure"),
                                 ("head_repository", {"full_name": "outsider/fork"}),
                                 ("updated_at", "2026-09-05T11:00:00Z")):
                with self.subTest(field=field):
                    run = dict(self.run, **{field: value})
                    self.assertFalse(planner.reusable_run(run, self.current, "owner/repo", self.now))

    def test_checkout_mismatch_prevents_even_exact_sha_reuse(self):
        with patch.object(planner, "git", return_value="b" * 40):
            with self.assertRaises(ValueError):
                planner.find_evidence(self.env, planner.FULL, self.api, self.now)

    def test_manual_candidate_and_pr_never_reuse(self):
        for event, ref in (("workflow_dispatch", "refs/heads/main"),
                           ("push", "refs/heads/codex/movie"), ("pull_request", "refs/pull/1/merge")):
            env = dict(self.env, GITHUB_EVENT_NAME=event, GITHUB_REF=ref)
            self.assertIsNone(planner.find_evidence(env, planner.FULL, lambda _: self.fail("Unexpected API call"), self.now))

    def test_incomplete_job_response_does_not_allow_reuse(self):
        def api(path):
            result = self.api(path)
            if "jobs" in result:
                result["total_count"] = 101
            return result
        with self.assertRaises(ValueError):
            planner.find_evidence(self.env, planner.FULL, api, self.now)

    def test_evidence_lookup_failure_stops_before_authorizing_mac_jobs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "event.json").write_text("{}")
            env = dict(self.env, GITHUB_EVENT_PATH=str(root / "event.json"),
                       GITHUB_OUTPUT=str(root / "output"), GITHUB_STEP_SUMMARY=str(root / "summary"))
            for error in (OSError, AttributeError, TypeError, ValueError,
                          planner.CorrectionEvidenceUnavailable,
                          subprocess.CalledProcessError(1, "git")):
                with self.subTest(error=error), patch.dict(os.environ, env), \
                        patch.object(planner, "changed_paths", side_effect=ValueError), \
                        patch.object(planner, "find_evidence", side_effect=error):
                    (root / "output").write_text("")
                    with self.assertRaises(SystemExit):
                        planner.main()
                    self.assertEqual((root / "output").read_text(), "")
            # Main must not silently restart the expensive candidate suite.
            with patch.dict(os.environ, env), \
                    patch.object(planner, "changed_paths", side_effect=ValueError), \
                    patch.object(planner, "find_evidence", return_value=None):
                with self.assertRaises(SystemExit):
                    planner.main()
                self.assertEqual((root / "output").read_text(), "")
            # The candidate branch still performs its required validation.
            with patch.dict(os.environ, dict(env, GITHUB_REF="refs/heads/codex/candidate")), \
                    patch.object(planner, "changed_paths", side_effect=ValueError), \
                    patch.object(planner, "find_evidence", return_value=None):
                planner.main()
                outputs = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
                self.assertEqual(outputs, {"build": "true", "build_name": planner.BUILD, "smoke": "true", "sharing": "true",
                    "smoke_name": planner.SMOKE, "app_ui": "true", "matrix_parallelism": "2",
                    "runtime_scope": scope.FULL_SCOPE,
                    "lanes": json.dumps(scope.lanes(scope.FULL_SCOPE), separators=(",", ":")),
                    "app_ui_lanes": json.dumps(scope.app_ui_lanes(scope.FULL_SCOPE), separators=(",", ":")),
                    "matrix_lanes": ('["runtime","gallery-normal","gallery-variants"]'
                                     if "gallery-variants" in scope.lanes(scope.FULL_SCOPE)
                                     else '["runtime","gallery-normal","gallery-white","gallery-no-caption"]')})

    def test_same_sha_lookup_does_not_depend_on_unrelated_old_candidate_api(self):
        calls = []
        def api(path):
            calls.append(path)
            if "/workflows/" in path:
                self.assertIn("head_sha=" + self.sha, path)
                return {"workflow_runs": [dict(self.run, id=9, head_sha="b" * 40), self.run]}
            return self.api(path)
        self.assertEqual(planner.find_evidence(self.env, planner.FULL, api, self.now), (10, self.sha))
        self.assertFalse(any("/runs/9/" in path for path in calls))

    def test_unavailable_candidate_does_not_hide_another_verified_candidate(self):
        def api(path):
            if "/workflows/" in path:
                return {"workflow_runs": [dict(self.run, id=11), self.run]}
            if "/runs/11/jobs" in path:
                raise OSError("private error body")
            return self.api(path)
        output = io.StringIO()
        with patch("sys.stdout", output):
            self.assertEqual(planner.find_evidence(self.env, planner.FULL, api, self.now), (10, self.sha))
        self.assertIn('"stage":"candidate_unavailable"', output.getvalue())
        self.assertIn('"stage":"evidence_selected"', output.getvalue())
        self.assertNotIn("private error body", output.getvalue())

    def test_evidence_api_logs_status_without_credentials_or_response_bodies(self):
        path = "/repos/owner/repo/actions/runs/20"
        env = dict(self.env, GH_TOKEN="private-token")
        for error in (urllib.error.HTTPError("https://private.invalid/private-token", 403,
                                            "private response body", {}, None),
                      TimeoutError("private-token"), ValueError("private response body")):
            output = io.StringIO()
            with self.subTest(error=type(error).__name__), patch("sys.stdout", output), \
                    patch.object(planner.urllib.request, "urlopen", side_effect=error):
                with self.assertRaises(ValueError):
                    planner.github_api(env, path)
            self.assertIn('"stage":"api_error"', output.getvalue())
            self.assertNotIn("private-token", output.getvalue())
            self.assertNotIn("private response body", output.getvalue())
            if isinstance(error, urllib.error.HTTPError):
                self.assertIn('"status":403', output.getvalue())
        response = io.BytesIO(b'{"id":20}'); response.status = 200
        with patch("sys.stdout", io.StringIO()) as output, \
                patch.object(planner.urllib.request, "urlopen", return_value=response):
            self.assertEqual(planner.github_api(env, path), {"id": 20})
        self.assertIn('"stage":"api_complete"', output.getvalue())

    def test_diagnosis_never_writes_release_plan_or_job_outputs(self):
        current = dict(self.current, event="push", head_branch="main",
                       repository={"full_name": "owner/repo"}, path=".github/workflows/ios-build.yml")
        output = io.StringIO()
        with patch.dict(os.environ, self.env), patch("sys.stdout", output), \
                patch.object(planner, "github_api", return_value=current), \
                patch.object(planner, "find_evidence", return_value=(10, self.sha)) as find:
            planner.diagnose_reuse(20, scope.FULL_SCOPE)
        self.assertEqual(find.call_args.args[0]["GITHUB_SHA"], self.sha)
        self.assertIn('"release_evidence":false', output.getvalue())
        self.assertNotIn("IOS_CI_PLAN_JSON", output.getvalue())
        with patch.dict(os.environ, self.env), \
                patch.object(planner, "github_api", return_value=dict(current, head_branch="codex/other")), \
                patch.object(planner, "find_evidence") as find:
            with self.assertRaises(ValueError):
                planner.diagnose_reuse(20, scope.FULL_SCOPE)
            find.assert_not_called()

    def test_mapped_photo_and_official_ui_keep_build_smoke_and_core_runtime(self):
        change = ('Text("before")\n', 'Text("after")\n')
        for path in scope.PHOTO_VIEWS:
            self.assertEqual(scope.select_scope({path: change}), scope.PHOTO_SCOPE)
        self.assertEqual(scope.select_scope({scope.OFFICIAL_VIEW: change}), scope.OFFICIAL_SCOPE)
        home = "NekoWidget/NekoWidget/Views/HomeView.swift"
        selected = scope.select_scope({home: change, scope.OFFICIAL_VIEW: change})
        self.assertEqual(selected, scope.COMBINED_SCOPE)
        self.assertEqual(planner.required_jobs([home], scope.PHOTO_SCOPE),
                         (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.PHOTO_SCOPE))
        self.assertEqual(set(scope.native_tests(selected)), set(scope.PHOTO_TESTS + scope.OFFICIAL_TESTS))
        self.assertEqual(set(scope.native_tests(scope.FULL_SCOPE)),
                         set(scope.PHOTO_TESTS + scope.OFFICIAL_TESTS + ("NekoWidgetUITests/PersonalRediscoveryUITests", scope.GALLERY_TEST)))
        for selected in (scope.PHOTO_SCOPE, scope.OFFICIAL_SCOPE, scope.COMBINED_SCOPE):
            self.assertNotIn(scope.GALLERY_TEST, scope.native_tests(selected))

    def test_unknown_sensitive_and_inline_fixture_changes_force_full(self):
        home = "NekoWidget/NekoWidget/Views/HomeView.swift"
        change = ('Text("before")\n', 'Text("after")\n')
        for extra in (
            "NekoWidget/NekoWidget/Views/FamilyWindowView.swift",
            "NekoWidget/NekoWidget/Views/PairingView.swift",
            "NekoWidget/NekoWidget/Views/MainTabView.swift",
            "NekoWidget/NekoWidget/Views/SettingsView.swift",
            "NekoWidget/Shared/Models/WidgetManifest.swift",
            "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
            "NekoWidget/NekoWidget/Info.plist", "NekoWidget/NekoWidget/NekoWidget.entitlements",
            "NekoWidget/NekoWidget/App/AppStoreScreenshotFixture.swift",
            "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift",
            "NekoWidget/ci/ios_ci_scope.py", "NekoWidget/ci/run-sharing-runtime-matrix.sh",
            ".github/workflows/ios-build.yml", "docs/scope.md", "unknown.swift",
        ):
            with self.subTest(extra=extra):
                expected = scope.APP_VIEW_SCOPE if extra in scope.APP_ONLY_VIEWS | scope.APP_VIEW_PATHS else scope.FULL_SCOPE
                self.assertEqual(scope.select_scope({home: change, extra: change}), expected)
                self.assertEqual(planner.required_jobs([home, extra], scope.PHOTO_SCOPE), planner.FULL)
        protected = '#if DEBUG\n#if targetEnvironment(simulator)\nText("fixture")\n#endif\n#else\nText("shipping")\n#endif\n'
        self.assertEqual(scope.select_scope({home: (protected + change[0], protected + change[1])}), scope.PHOTO_SCOPE)
        for after in (protected.replace('"fixture"', '"changed"'),
                      protected.replace('"shipping"', '"changed"'),
                      protected.replace("#if DEBUG", "#if NEW")):
            self.assertEqual(scope.select_scope({home: (protected, after)}), scope.APP_VIEW_SCOPE)
        for after in (protected + "#if DEBUG\n", protected + "#endif\n"):
            self.assertEqual(scope.select_scope({home: (protected, after)}), scope.FULL_SCOPE)
        for text in ('requestAuthorization()', 'hasPhotoPermission = true', 'consent = nil',
                     'privacyURL = changed', 'fixtureTitle = "x"', '"--new-launch-switch"'):
            self.assertEqual(scope.select_scope({home: (change[0], text)}), scope.APP_VIEW_SCOPE)

    def test_app_owned_stores_keep_app_checks_without_widget_gallery(self):
        main = "NekoWidget/NekoWidget/Views/MainTabView.swift"
        presentation = "NekoWidget/NekoWidget/Views/ShowcasePhotoView.swift"
        tests = "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift"
        pair = ("import Foundation\nstruct Before {}\n", "import Foundation\nstruct After {}\n")
        root = "NekoWidget/NekoWidget/App/AppRootView.swift"
        for store in ("NekoWidget/NekoWidget/Services/ShowcasePhotoStore.swift",
                      "NekoWidget/NekoWidget/Services/CatPreparednessStore.swift"):
            with self.subTest(store=store):
                changes = {path: pair for path in (root, store, main, presentation, tests)}
                self.assertEqual(scope.select_scope({store: pair}), scope.APP_VIEW_SCOPE)
                self.assertEqual(scope.select_scope(changes), scope.APP_VIEW_SCOPE)
                self.assertEqual(scope.lanes(scope.APP_VIEW_SCOPE),
                                 ("runtime", "app-ui-solo-1", "app-ui-solo-2", "app-ui-other"))
                self.assertTrue(any("Build disabled app" in job for job in
                                    planner.required_jobs(list(changes), scope.APP_VIEW_SCOPE)))
                self.assertFalse(any("gallery" in job.lower() for job in
                                     planner.required_jobs(list(changes), scope.APP_VIEW_SCOPE)))
                for unrelated in (
                    "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                    "NekoWidget/Shared/Storage/AtomicJSON.swift",
                    "NekoWidget/NekoWidget/Services/PhotoLibraryScanner.swift",
                    "NekoWidget/NekoWidget.xcodeproj/project.pbxproj",
                ):
                    self.assertEqual(scope.select_scope(dict(changes, **{unrelated: pair})), scope.FULL_SCOPE)

    def test_family_window_scope_keeps_owning_class_and_photo_links_without_widget_rendering(self):
        window = "NekoWidget/NekoWidget/Views/FamilyWindowView.swift"
        record = "NekoWidget/NekoWidget/Views/FamilyRecordView.swift"
        owned = sorted(scope.FAMILY_WINDOW_TEST_NAMES)
        source = ('import XCTest\n'
                  'final class OtherTests: XCTestCase {\n    func testOther() {}\n}\n'
                  'final class MomentDeliveryComposerUITests: XCTestCase {\n'
                  + ''.join(f'    func {name}() {{ print("before") }}\n' for name in owned)
                  + '    func testUnrelated() { print("unchanged") }\n}\n')
        changes = {window: ('let x = 1', 'let x = 2'),
                   record: ('#if DEBUG\nlet x = 1\n#endif', '#if DEBUG\nlet x = 2\n#endif'),
                   scope.MEMORY_TEST_PATH: (source, source.replace('"before"', '"after"')),
                   'handoffs/design.md': ('a', 'b')}
        self.assertEqual(scope.select_scope(changes), scope.FAMILY_WINDOW_UI_SCOPE)
        added_helper = (source.replace('    func ' + owned[0],
            '    @MainActor\n    private func exerciseCollection() { print("collection") }\n'
            '    func ' + owned[0], 1).replace('print("before")', 'exerciseCollection()', 1))
        self.assertEqual(scope.select_scope(dict(changes, **{
            scope.MEMORY_TEST_PATH: (source, added_helper)})), scope.FAMILY_WINDOW_UI_SCOPE)
        shadowed = source.replace('print("unchanged")', 'exerciseCollection()')
        shadowed_after = shadowed.replace('    func ' + owned[0],
            '    @MainActor\n    private func exerciseCollection() { print("collection") }\n'
            '    func ' + owned[0], 1).replace('print("before")', 'exerciseCollection()', 1)
        self.assertNotEqual(scope.select_scope(dict(changes, **{
            scope.MEMORY_TEST_PATH: (shadowed, shadowed_after)})), scope.FAMILY_WINDOW_UI_SCOPE)
        for invalid in (source.replace('print("unchanged")', 'print("changed")'),
                        source.replace('testUnrelated()', 'testRenamed()'),
                        source.replace('import XCTest', 'import UIKit'),
                        source + '\nprivate func outsideHelper() {}'):
            self.assertNotEqual(scope.select_scope(dict(changes, **{
                scope.MEMORY_TEST_PATH: (source, invalid)})), scope.FAMILY_WINDOW_UI_SCOPE)
        contract = ('import unittest\nclass Contract(unittest.TestCase):\n'
                    '    def test_family_window_combines_photos_without_exposing_report_only_sends(self) -> None:\n'
                    '        self.assertIn("old view", "view")\n\n'
                    '    def test_widget_boundary(self):\n        self.assertTrue(True)\n')
        revised = contract.replace('"old view"', '"new view"')
        companion = dict(changes, **{scope.FAMILY_WINDOW_CONTRACT_TEST: (contract, revised)})
        self.assertEqual(scope.select_scope(companion), scope.FAMILY_WINDOW_UI_SCOPE)
        self.assertTrue(scope.accepts_paths(scope.FAMILY_WINDOW_UI_SCOPE, companion))
        for invalid in (revised.replace('import unittest', 'import os'),
                        revised.replace('self.assertTrue(True)', 'pass'),
                        revised.replace('    def test_widget_boundary', '    @unittest.skip("no")\n    def test_widget_boundary'),
                        revised.replace('    def test_widget_boundary', '    skip = True\n    def test_widget_boundary'),
                        revised + '\nhelper = 1\n',
                        revised.replace('test_family_window_combines_photos_without_exposing_report_only_sends', 'test_other')):
            companion[scope.FAMILY_WINDOW_CONTRACT_TEST] = (contract, invalid)
            self.assertNotEqual(scope.select_scope(companion), scope.FAMILY_WINDOW_UI_SCOPE)
        for broken in ('#if DEBUG\n#else\n#else\n#endif',
                       '#if DEBUG\n#else\n#elseif MORE\n#endif', '#if\n#endif'):
            modified = dict(changes)
            modified[record] = ('let x = 1', broken)
            self.assertNotEqual(scope.select_scope(modified), scope.FAMILY_WINDOW_UI_SCOPE)
        self.assertTrue(scope.accepts_paths(scope.FAMILY_WINDOW_UI_SCOPE, changes))
        self.assertEqual(scope.lanes(scope.FAMILY_WINDOW_UI_SCOPE), ('runtime', 'app-ui'))
        tests = scope.native_tests(scope.FAMILY_WINDOW_UI_SCOPE)
        self.assertEqual(tests[:len(owned)], scope.FAMILY_WINDOW_NATIVE_TESTS)
        self.assertNotIn('NekoWidgetUITests/MomentDeliveryComposerUITests', tests)
        self.assertEqual(sum('OfficialWindowUITests/testWidgetURLs' in name for name in tests), 3)
        self.assertNotIn(scope.GALLERY_TEST, tests)
        self.assertEqual(scope.smoke_tests(scope.FAMILY_WINDOW_UI_SCOPE),
                         ('NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess',
                          'NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary'))
        for path in ('NekoWidget/Shared/Models/WidgetManifest.swift',
                     'NekoWidget/NekoWidgetWidget/NekoWidgetView.swift',
                     'NekoWidget/NekoWidget.xcodeproj/project.pbxproj',
                     '.github/workflows/ios-build.yml'):
            self.assertEqual(scope.select_scope(dict(changes, **{path: ('before', 'after')})), scope.FULL_SCOPE)
        for after in (source.replace('import XCTest', 'import UIKit'),
                      source.replace('testOther()', 'testOtherChanged()'),
                      source + '\nprivate func outsideHelper() {}',
                      source.replace('MomentDeliveryComposerUITests', 'DifferentTests'),
                      source + '#if DEBUG\n'):
            modified = dict(changes)
            modified[scope.MEMORY_TEST_PATH] = (source, after)
            self.assertNotEqual(scope.select_scope(modified), scope.FAMILY_WINDOW_UI_SCOPE)

    def test_app_only_record_export_keeps_sharing_runtime_without_widget_gallery(self):
        change = ('let before = 1\n', 'let after = 2\n')
        album = "NekoWidget/NekoWidget/Views/FamilyRecordView.swift"
        ui_test = "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift"
        changes = {path: change for path in scope.APP_ONLY_RECORD_EXPORT_PATHS}
        self.assertIn(album, changes)
        self.assertIn(ui_test, changes)
        digests = {path: tuple(map(scope.source_digest, pair)) for path, pair in changes.items()}
        with patch.object(scope, "APP_ONLY_RECORD_EXPORT_DIGESTS", digests):
            self.assertEqual(scope.select_scope(changes), scope.REVIEWED_FAMILY_EXPORT_SCOPE)
            self.assertTrue(scope.accepts_paths(scope.REVIEWED_FAMILY_EXPORT_SCOPE, changes))
            selected = planner.required_jobs(list(changes), scope.REVIEWED_FAMILY_EXPORT_SCOPE)
            self.assertEqual(selected, planner.required_jobs_from_scope(scope.REVIEWED_FAMILY_EXPORT_SCOPE))
            self.assertEqual(scope.lanes(scope.REVIEWED_FAMILY_EXPORT_SCOPE), ("runtime", "app-ui"))
            self.assertIn(scope.lane_job(scope.REVIEWED_FAMILY_EXPORT_SCOPE, "runtime"), selected)
            self.assertEqual(len(scope.native_tests(scope.REVIEWED_FAMILY_EXPORT_SCOPE)), 1)
            self.assertIn("testFamilyRecordKeepsOtherAuthorsWordsWhenPhotoIsWithdrawnAndRevokesAccess",
                          scope.native_tests(scope.REVIEWED_FAMILY_EXPORT_SCOPE)[0])
            self.assertNotIn(scope.GALLERY_TEST, scope.native_tests(scope.REVIEWED_FAMILY_EXPORT_SCOPE))
            for path in changes:
                with self.subTest(missing=path):
                    self.assertEqual(scope.select_scope({key: value for key, value in changes.items() if key != path}),
                                     scope.FULL_SCOPE)
                with self.subTest(tampered=path):
                    edited = dict(changes)
                    edited[path] = (change[0], change[1] + "unreviewed\n")
                    self.assertEqual(scope.select_scope(edited), scope.FULL_SCOPE)
            for unrelated in (
                "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                "NekoWidget/Shared/Models/WidgetManifest.swift",
                "NekoWidget/NekoWidget.xcodeproj/project.pbxproj",
                "NekoWidget/NekoWidget/Services/WidgetCacheBuilder.swift",
            ):
                with self.subTest(unrelated=unrelated):
                    self.assertEqual(scope.select_scope(changes | {unrelated: change}), scope.FULL_SCOPE)

    def test_only_literal_copy_and_known_literal_style_lines_can_use_ui_scope(self):
        home = "NekoWidget/NekoWidget/Views/HomeView.swift"
        for before, after in (
            ('Text("Before")', 'Text("After")'),
            ('.font(.title3.bold())', '.font(.headline)'),
            ('.font(.system(size: 18, weight: .semibold))', '.font(.system(size: 17, weight: .regular))'),
            ('.padding(.horizontal, 12)', '.padding(.horizontal, 16)'),
            ('.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)',
             '.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)'),
            ('.foregroundStyle(.secondary)', '.foregroundStyle(Color.primary)'),
            ('.multilineTextAlignment(.center)', '.multilineTextAlignment(.leading)'),
            ('Text("Before").font(.body)', 'Text("After").font(.headline)'),
        ):
            with self.subTest(after=after):
                self.assertEqual(scope.select_scope({home: (before, after)}), scope.PHOTO_SCOPE)
        for before, after in (
            ('save(photo)', 'remove(photo)'),
            ('isSaved = true', 'isSaved = false'),
            ('if mayDisplay {', 'if true {'),
            ('HStack(spacing: 12) {', 'VStack(spacing: 12) {'),
            ('.font(existingFont)', '.font(.body)'),
            ('Text("Before")', 'Text("Value \\(helper())")'),
            ('Text("Before")', 'Text(changedValue)'),
            ('.padding(12)', '.padding(helper())'),
            ('.frame(height: 44)', '.frame(height: model.value)'),
            ('.foregroundStyle(.secondary)', '.foregroundStyle(computeColor())'),
            ('.font(.body)', '.font(.body); save()'),
            ('.disabled(true)', '.disabled(false)'),
            ('@State var value = 1', '@State var value = 2'),
            ('Text("Before")', '// Text("After")'),
            ('"""\nText("Before")\n"""', '"""\nText("After")\n"""'),
            ('Text(#"Before"#)', 'Text(#"After"#)'),
        ):
            with self.subTest(after=after):
                self.assertEqual(scope.select_scope({home: (before, after)}), scope.APP_VIEW_SCOPE)

    def test_reuse_requires_scope_version_and_exact_subset_or_full_execution(self):
        required = planner.required_jobs_from_scope(scope.PHOTO_SCOPE)
        # Full executed coverage can serve a narrower main diff.
        self.assertTrue(planner.covers_jobs(self.jobs, required, self.sha))
        photo_jobs = [{"name": name, "status": "completed", "conclusion": "success", "head_sha": self.sha,
                       "completed_at": "2026-09-07T11:00:00Z"}
                      for name in required]
        self.assertTrue(planner.covers_jobs(photo_jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(photo_jobs, planner.FULL, self.sha))
        for name in (scope.lane_job(scope.OFFICIAL_SCOPE, "app-ui"),
                     scope.SHARING_JOB_PREFIX, required[-1].replace("v1", "v0")):
            jobs = copy.deepcopy(photo_jobs)
            jobs[-1]["name"] = name
            self.assertFalse(planner.covers_jobs(jobs, required, self.sha))
        for conclusion in ("skipped", "failure", "cancelled"):
            jobs = copy.deepcopy(photo_jobs)
            jobs[-1]["conclusion"] = conclusion
            self.assertFalse(planner.covers_jobs(jobs, required, self.sha))
        self.assertFalse(planner.covers_jobs(photo_jobs + [self.jobs[3]], required, self.sha))
        self.jobs = photo_jobs
        self.assertEqual(planner.find_evidence(self.env, required, self.api, self.now), (10, self.sha))
        self.assertIsNone(planner.find_evidence(self.env, planner.FULL, self.api, self.now))

    def test_scope_metadata_and_arguments_are_generated_from_same_validated_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            metadata, tests = Path(directory) / "scope.json", Path(directory) / "tests.txt"
            for selected in scope.SCOPES:
                with patch("sys.argv", ["ios_ci_scope.py", "--scope", selected,
                                        "--metadata", str(metadata), "--tests", str(tests)]):
                    scope.main()
                result = json.loads(metadata.read_text())
                self.assertEqual(result["scope"], selected)
                self.assertEqual(result["sharingRuntime"], ["ios-18-5", "ios-26-2"])
                self.assertEqual(result["widgetGallery"], "gallery-normal" in scope.lanes(selected))
                self.assertEqual(tests.read_text().splitlines(),
                                 ["-only-testing:" + name for name in result["nativeTests"]])
        with self.assertRaises(ValueError):
            scope.native_tests("unknown")

    def test_selected_native_suites_still_exist_and_workflow_carries_scope_identity(self):
        project = Path(__file__).resolve().parents[1]
        sources = [path.read_text(encoding="utf-8") for path in (project / "NekoWidgetUITests").glob("*.swift")]
        for identifier in scope.native_tests(scope.FULL_SCOPE):
            parts = identifier.split("/")
            self.assertEqual(parts[0], "NekoWidgetUITests")
            found = [text for text in sources if re.search(r"class " + re.escape(parts[1]) + r"\s*:\s*XCTestCase", text)]
            self.assertEqual(len(found), 1, identifier)
            if len(parts) == 3:
                self.assertIn("func " + parts[2] + "(", found[0])
        workflow = (project.parent / ".github/workflows/ios-build.yml").read_text(encoding="utf-8")
        self.assertIn("name: " + scope.LANE_JOB_PREFIX + " [${{ matrix.lane }}; scope ${{ needs.plan.outputs.runtime_scope }}]", workflow)
        self.assertIn("runtime_scope: ${{ steps.scope.outputs.runtime_scope }}", workflow)
        self.assertIn("NEKO_IOS_RUNTIME_SCOPE: ${{ needs.plan.outputs.runtime_scope }}", workflow)

    def test_independent_jobs_start_after_plan_without_removing_release_evidence(self):
        project = Path(__file__).resolve().parents[1]
        workflow = (project.parent / ".github/workflows/ios-build.yml").read_text(encoding="utf-8")
        for identifier, output in (("build-without-signing", "build"),
                                   ("simulator-smoke-test", "smoke"),
                                   ("sharing-app-ui", "app_ui"),
                                   ("sharing-runtime-matrix", "sharing"),
                                   ("sharing-runtime-deferred", "sharing"),
                                   ("sharing-gallery-early", "sharing")):
            body = re.split(r"\n  (?=\S)", workflow.split("\n  " + identifier + ":", 1)[1], maxsplit=1)[0]
            if identifier == "sharing-gallery-early":
                self.assertIn("    needs: [plan, simulator-smoke-test]\n", body)
                self.assertIn("    if: always() && needs.plan.result == 'success' && needs.plan.outputs.sharing == 'true'", body)
                self.assertIn("needs.plan.outputs.runtime_scope == 'full-v1'", body)
                self.assertNotIn("needs.build-without-signing", body)
            elif identifier == "sharing-runtime-deferred":
                self.assertIn("    needs: [plan, build-without-signing, simulator-smoke-test]\n", body)
                self.assertIn("    if: always() && needs.plan.result == 'success' && needs.plan.outputs.sharing == 'true'", body)
            else:
                self.assertIn("    needs: plan\n", body)
                self.assertIn("    if: needs.plan.outputs." + output + " == 'true'", body)
            self.assertNotIn("continue-on-error:", body)
        # Parallel runtime success cannot stand in for a failed/skipped Release.
        for result in ("failure", "skipped", "cancelled"):
            jobs = copy.deepcopy(self.jobs)
            jobs[0]["conclusion"] = result
            self.assertFalse(planner.covers_jobs(jobs, planner.FULL, self.sha))

    def test_real_git_ui_test_and_release_note_select_app_view_without_widget_gallery(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ui_test = scope.MEMORY_TEST_PATH
            note = "NekoWidget/ci/release-candidates/2026-09-25-review.md"
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], text=True,
                                               encoding="utf-8", stderr=subprocess.PIPE).rstrip("\n")
            def commit():
                git("add", ".")
                git("-c", "user.name=CI", "-c", "user.email=ci@example.invalid", "commit", "-qm", "fixture")
                return git("rev-parse", "HEAD")
            git("init", "-q")
            target = root / ui_test
            target.parent.mkdir(parents=True)
            target.write_text("before\n")
            base = commit()
            git("update-ref", "refs/remotes/origin/main", base)
            target.write_text("after\n")
            release_note = root / note
            release_note.parent.mkdir(parents=True)
            release_note.write_text("Reviewed release candidate.\n")
            head = commit()
            env = dict(self.env, GITHUB_REF="refs/heads/codex/ui-test", GITHUB_SHA=head)
            with patch.object(planner, "git", side_effect=git):
                paths = planner.changed_paths({}, env)
                self.assertEqual(set(paths), {ui_test, note})
                selected = planner.runtime_scope(paths, {}, env)
                self.assertEqual(selected, scope.APP_VIEW_SCOPE)
                self.assertEqual(planner.required_jobs(paths, selected),
                                 planner.required_jobs_from_scope(scope.APP_VIEW_SCOPE))

    def test_real_git_ui_selection_rejects_moves_additions_deletions_and_mode_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = "NekoWidget/NekoWidget/Views/HomeView.swift"
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], text=True,
                                               encoding="utf-8", stderr=subprocess.PIPE).rstrip("\n")
            def commit(stage=True):
                if stage:
                    git("add", ".")
                git("-c", "user.name=CI", "-c", "user.email=ci@example.invalid", "commit", "--allow-empty", "-qm", "fixture")
                return git("rev-parse", "HEAD")
            git("init", "-q")
            git("config", "core.filemode", "false")
            target = root / home
            target.parent.mkdir(parents=True)
            target.write_text('Text("before")\n')
            base = commit()
            git("update-ref", "refs/remotes/origin/main", base)
            def selected():
                env = dict(self.env, GITHUB_REF="refs/heads/codex/ui", GITHUB_SHA=git("rev-parse", "HEAD"))
                paths = planner.changed_paths({}, env)
                return planner.runtime_scope(paths, {}, env)
            with patch.object(planner, "git", side_effect=git):
                target.write_text('Text("after")\n')
                commit()
                self.assertEqual(selected(), scope.PHOTO_SCOPE)
                handoff = root / "handoffs/change.md"
                handoff.parent.mkdir()
                handoff.write_text("The source change is described here.\n")
                commit()
                self.assertEqual(selected(), scope.PHOTO_SCOPE)
                git("update-index", "--chmod=+x", "handoffs/change.md")
                commit(stage=False)
                self.assertEqual(selected(), scope.FULL_SCOPE)
                git("update-index", "--chmod=-x", "handoffs/change.md")
                commit(stage=False)
                release_note = root / "NekoWidget/ci/release-candidates/2026-09-25-review.md"
                release_note.parent.mkdir(parents=True)
                release_note.write_text("Release evidence is reviewed separately.\n")
                commit()
                self.assertEqual(selected(), scope.PHOTO_SCOPE)
                git("update-index", "--chmod=+x", "NekoWidget/ci/release-candidates/2026-09-25-review.md")
                commit(stage=False)
                self.assertEqual(selected(), scope.FULL_SCOPE)
                env = dict(self.env, GITHUB_SHA=git("rev-parse", "HEAD"), GITHUB_EVENT_NAME="workflow_dispatch")
                self.assertEqual(planner.runtime_scope([home], {}, env), scope.FULL_SCOPE)
                git("checkout", "--detach", "-q", base)
                git("mv", home, scope.OFFICIAL_VIEW)
                commit()
                self.assertEqual(selected(), scope.FULL_SCOPE)
                git("checkout", "--detach", "-q", base)
                (target.parent / "MonthlyWindowView.swift").write_text('Text("new")\n')
                commit()
                self.assertEqual(selected(), scope.FULL_SCOPE)
                git("checkout", "--detach", "-q", base)
                git("rm", "-q", home)
                commit()
                self.assertEqual(selected(), scope.FULL_SCOPE)
                git("checkout", "--detach", "-q", base)
                git("update-index", "--chmod=+x", home)
                commit(stage=False)
                self.assertEqual(selected(), scope.FULL_SCOPE)
                git("checkout", "--detach", "-q", base)
                blob = git("rev-parse", base + ":" + home)
                git("update-index", "--cacheinfo", f"120000,{blob},{home}")
                commit(stage=False)
                self.assertEqual(selected(), scope.FULL_SCOPE)
        with patch.object(planner, "git", side_effect=OSError):
            self.assertEqual(planner.runtime_scope([home], {}, self.env), scope.FULL_SCOPE)

    def test_real_git_research_exception_is_narrow_and_ancestor_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], text=True,
                                               encoding="utf-8", stderr=subprocess.PIPE).rstrip("\n")
            def write(path, text):
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(text, encoding="utf-8")
            def commit(stage=True):
                if stage:
                    git("add", ".")
                git("-c", "user.name=CI", "-c", "user.email=ci@example.invalid", "commit", "--allow-empty", "-qm", "fixture")
                return git("rev-parse", "HEAD")
            git("init", "-q")
            # The mode case below changes the index deliberately; do not let
            # host filesystem permissions create an unrelated dirty checkout.
            git("config", "core.filemode", "false")
            app = "NekoWidget/NekoWidget/App.swift"
            research = planner.INDEPENDENT_RESEARCH + "Sources/Probe.swift"
            workflow = ".github/workflows/ios-build.yml"
            for path in (app, research, workflow, "docs/release.md", "AGENTS.md"):
                write(path, "base")
            base = commit()
            with patch.object(planner, "git", side_effect=git):
                write(research, "research update")
                head = commit()
                self.assertTrue(planner.equivalent_inputs(base, head))
                # Exercise discovery and job validation with real git, not only
                # the helper. API must search beyond the current head_sha.
                self.env["GITHUB_SHA"] = self.current["head_sha"] = head
                self.run["head_sha"] = base
                for job in self.jobs:
                    job["head_sha"] = base
                def api(path):
                    if "/workflows/" in path and "head_sha=" in path:
                        return {"workflow_runs": []}
                    return self.api(path)
                self.assertEqual(planner.find_evidence(self.env, planner.FULL, api, self.now), (10, base))
                self.assertFalse(planner.equivalent_inputs(head, base))  # Checkout mismatch.
                for candidate in ("invalid", "f" * 40, None):
                    self.assertFalse(planner.equivalent_inputs(candidate, head))
                for path in (app, workflow, "NekoWidget/ci/plan-ios-ci.py", "docs/release.md", "AGENTS.md",
                             "experiments/PetIdentityProbe-other/Probe.swift", "unknown.txt"):
                    with self.subTest(path=path):
                        git("checkout", "--detach", "-q", base)
                        write(path, "changed")
                        self.assertFalse(planner.equivalent_inputs(base, commit()))
                git("checkout", "--detach", "-q", base)
                git("rm", "-q", app)
                self.assertFalse(planner.equivalent_inputs(base, commit()))
                git("checkout", "--detach", "-q", base)
                git("mv", app, planner.INDEPENDENT_RESEARCH + "Moved.swift")
                self.assertFalse(planner.equivalent_inputs(base, commit()))
                git("checkout", "--detach", "-q", base)
                git("mv", research, "NekoWidget/Moved.swift")
                self.assertFalse(planner.equivalent_inputs(base, commit()))
                git("checkout", "--detach", "-q", base)
                git("update-index", "--chmod=+x", app)
                self.assertFalse(planner.equivalent_inputs(base, commit(stage=False)))
                git("checkout", "--detach", "-q", base)
                git("rm", "-qr", planner.INDEPENDENT_RESEARCH)
                write(planner.INDEPENDENT_RESEARCH.rstrip("/"), "replaced by file")
                self.assertFalse(planner.equivalent_inputs(base, commit()))
                # Identical files on divergent branches are not ancestry proof.
                git("checkout", "--detach", "-q", base)
                write(research, "research update")
                git("add", ".")
                git("-c", "user.name=CI", "-c", "user.email=ci@example.invalid", "commit", "-qm", "divergent")
                divergent = git("rev-parse", "HEAD")
                self.assertEqual(git("rev-parse", head + "^{tree}"), git("rev-parse", divergent + "^{tree}"))
                self.assertFalse(planner.equivalent_inputs(head, divergent))

    def test_git_failure_cannot_claim_equivalent_inputs(self):
        for error in (OSError, subprocess.CalledProcessError(1, "git"), UnicodeError):
            with patch.object(planner, "git", side_effect=error):
                self.assertFalse(planner.equivalent_inputs("b" * 40, self.sha))

    def test_branch_diff_includes_earlier_commits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], text=True).strip()
            def commit():
                git("add", ".")
                git("-c", "user.name=CI", "-c", "user.email=ci@example.invalid", "commit", "-qm", "fixture")
                return git("rev-parse", "HEAD")
            git("init", "-q")
            (root / "baseline.txt").write_text("base")
            base = commit()
            git("update-ref", "refs/remotes/origin/main", base)
            (root / "storage.swift").write_text("earlier change")
            commit()
            movie = root / planner.MOVIE_VIEW
            movie.parent.mkdir(parents=True)
            movie.write_text("latest change")
            head = commit()
            env = dict(self.env, GITHUB_SHA=head, GITHUB_REF="refs/heads/codex/movie")
            with patch.object(planner, "git", side_effect=git):
                paths = planner.changed_paths({}, env)
                self.assertIn("storage.swift", paths)
                self.assertIn(planner.MOVIE_VIEW, paths)
                self.assertEqual(planner.required_jobs(paths), planner.FULL)
                self.assertIsNone(planner.changed_paths({}, dict(env, GITHUB_EVENT_NAME="workflow_dispatch")))


class TestCorrectionReuseTests(unittest.TestCase):
    def test_split_full_graph_cannot_reuse_historical_pinned_correction(self):
        required = planner.required_jobs_from_scope(scope.FULL_SCOPE)
        self.assertNotEqual(required, planner.ALBUM_CORRECTION_REQUIRED)
        self.assertIsNone(planner.test_correction_scope(required))
        def forbidden_api(path):
            self.fail("Graph mismatch must be rejected before fetching evidence")
        self.assertIsNone(planner.correction_source({}, "a" * 40, planner.ALBUM_CORRECTION_BRANCH,
                          "soso-so-27/neko-widget", 1, required, forbidden_api,
                          dt.datetime.now(dt.timezone.utc)))
        self.assertFalse(planner.covers_corrected_full_graph({}, "a" * 40, required,
                         forbidden_api, dt.datetime.now(dt.timezone.utc), []))
        self.assertIn("Sharing checks [app-ui-solo; scope full-v1]", planner.ALBUM_CORRECTION_REQUIRED)
        self.assertNotIn("Sharing checks [app-ui-solo; scope full-v1]", required)

    def test_signed_log_redirect_strips_token_and_rejects_other_origins(self):
        request = urllib.request.Request("https://api.github.com/repos/o/r/actions/jobs/1/logs",
                                         headers={"Authorization": "Bearer private-test-token"})
        handler = planner.EvidenceLogRedirect()
        target = "https://productionresultssa13.blob.core.windows.net/log?sig=private-test-signature"
        redirected = handler.redirect_request(request, None, 302, "Found", {}, target)
        self.assertFalse(redirected.has_header("Authorization"))
        self.assertTrue(request.has_header("Authorization"))
        for url in ("http://api.github.com/repos/o/r/actions/jobs/1/logs",
                    "http://productionresultssa13.blob.core.windows.net/log", "https://example.invalid/log",
                    "https://productionresultssa13.blob.core.windows.net.example.invalid/log",
                    "https://user@productionresultssa13.blob.core.windows.net/log"):
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):
                handler.redirect_request(request, None, 302, "Found", {}, url)

    def test_album_correction_pins_whole_test_file_and_merged_controls(self):
        head = "a" * 40
        source = planner.ALBUM_CORRECTION_SOURCE
        row = ":100644 100644 " + " ".join(planner.ALBUM_CORRECTION_BLOBS) + " M\0" + scope.MEMORY_TEST_PATH + "\0"
        def check(raw=row, *, approval=True, current=head):
            def git(*args):
                if args[0] == "rev-parse": return current
                if args[0] == "diff": return raw
                if args[0] == "merge-base": return "c" * 40
                if args[0] == "show":
                    return "approved" if approval or not args[1].startswith(head + ":") else "unmerged"
                raise AssertionError(args)
            with patch.object(planner, "git", side_effect=git):
                return planner.album_correction_inputs(source, head)
        self.assertTrue(check())
        self.assertFalse(check(approval=False))
        self.assertFalse(check(current="b" * 40))
        for raw in (row + row, "", row.replace("100644 100644", "100644 100755"),
                    row.replace(" M\0", " T\0"), row.replace(planner.ALBUM_CORRECTION_BLOBS[1], "d" * 40),
                    row + row.replace(scope.MEMORY_TEST_PATH, "NekoWidget/Shared/Models/Photo.swift"),
                    row + row.replace(scope.MEMORY_TEST_PATH, ".github/workflows/ios-build.yml"),
                    row + row.replace(scope.MEMORY_TEST_PATH, "NekoWidget/NekoWidget/Views/TestFixture.swift")):
            self.assertFalse(check(raw), raw)
        with patch.object(planner, "git", side_effect=OSError):
            self.assertFalse(planner.album_correction_inputs(source, head))
        self.assertFalse(planner.album_correction_inputs("b" * 40, head))

    def test_unrelated_full_branches_do_not_query_correction_history(self):
        api = unittest.mock.Mock(side_effect=AssertionError("unrelated history lookup"))
        for branch, repository in (("codex/other", "soso-so-27/neko-widget"),
                                    (planner.ALBUM_CORRECTION_BRANCH, "owner/repo")):
            self.assertIsNone(planner.find_test_correction_evidence("a" * 40, branch, repository,
                              planner.ALBUM_CORRECTION_REQUIRED, api, dt.datetime.now(dt.timezone.utc)))
        api.assert_not_called()

    def test_known_full_correction_missing_history_stops_instead_of_restarting_full(self):
        def api(path):
            return {"id": 5} if path.endswith("ios-build.yml") else {"workflow_runs": [], "total_count": 0}
        with patch.object(planner, "album_correction_inputs", return_value=True):
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):
                planner.find_test_correction_evidence("a" * 40, planner.ALBUM_CORRECTION_BRANCH,
                    "soso-so-27/neko-widget", planner.ALBUM_CORRECTION_REQUIRED, api, dt.datetime.now(dt.timezone.utc))

    def test_album_source_requires_exact_graph_plan_identity_and_every_success(self):
        now = dt.datetime.now(dt.timezone.utc)
        repo, branch, source = "soso-so-27/neko-widget", planner.ALBUM_CORRECTION_BRANCH, planner.ALBUM_CORRECTION_SOURCE
        required = planner.ALBUM_CORRECTION_REQUIRED
        run = {"id": planner.ALBUM_CORRECTION_RUN, "workflow_id": 5, "head_sha": source,
               "head_branch": branch, "event": "push", "status": "completed", "conclusion": "failure",
               "updated_at": now.isoformat(), "repository": {"full_name": repo}, "head_repository": {"full_name": repo}}
        ui = planner.correction_ui_job(scope.FULL_SCOPE)
        jobs = [{"id": 100, "name": planner.PLAN_JOB, "head_sha": source, "status": "completed", "conclusion": "success"}]
        jobs += [{"id": 101 + index, "name": name, "head_sha": source, "status": "completed",
                  "conclusion": "failure" if name == ui else "success", "completed_at": now.isoformat()}
                 for index, name in enumerate(required)]
        record = {"schema_version": 1, "repository": repo, "head_sha": source, "scope": scope.FULL_SCOPE,
                  "required_jobs": list(required), "evidence_run_id": None, "evidence_sha": None}
        def check(*, selected_jobs=jobs, selected_run=run, selected_record=record, double=False, error=None, response="auto"):
            fixture = "IOS_CI_PLAN_JSON=" + json.dumps({**record, "repository": "owner/repo", "head_sha": "b" * 40})
            log = "IOS_CI_PLAN_JSON=" + json.dumps(selected_record)
            with patch.object(planner, "test_correction_inputs", return_value=True), \
                    patch.object(planner, "executed_jobs", return_value=selected_jobs):
                def api(_):
                    if error is not None: raise error
                    if response != "auto": return response
                    return fixture + "\n" + log + ("\n" + log if double else "")
                return planner.correction_source(selected_run, "a" * 40, branch, repo, 5, required,
                                                   api, now)
        self.assertEqual([entry["name"] for entry in check()["jobs"]], [name for name in required if name != ui])
        for index, job in enumerate(jobs):
            for status in ("skipped", "failure"):
                if job["name"] == ui and status == "failure": continue
                broken = copy.deepcopy(jobs); broken[index]["conclusion"] = status
                self.assertIsNone(check(selected_jobs=broken))
        self.assertIsNone(check(selected_jobs=jobs + [jobs[-1]]))
        for key, value in (("id", 1), ("head_sha", "b" * 40), ("event", "workflow_dispatch"),
                           ("run_attempt", 2),
                           ("updated_at", (now - dt.timedelta(hours=25)).isoformat()), ("head_branch", "codex/other")):
            self.assertIsNone(check(selected_run={**run, key: value}))
        for key, value in (("required_jobs", list(required[:-1])), ("scope", "app-view-ui-v1"),
                           ("head_sha", "b" * 40), ("evidence_run_id", 11), ("test_correction_evidence", {})):
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):
                check(selected_record={**record, key: value})
        with self.assertRaises(planner.CorrectionEvidenceUnavailable): check(double=True)
        for error in (OSError("unavailable"), ValueError("unavailable")):
            with self.assertRaises(planner.CorrectionEvidenceUnavailable): check(error=error)
        for response in (None, b"invalid type", "", "IOS_CI_PLAN_JSON={broken"):
            with self.assertRaises(planner.CorrectionEvidenceUnavailable): check(response=response)

    def test_full_correction_runs_solo_only_while_retaining_seven_required_jobs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "event.json").write_text("{}")
            env = {"GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "outputs"),
                   "GITHUB_STEP_SUMMARY": str(root / "summary"), "GITHUB_EVENT_NAME": "push",
                   "GITHUB_REF": "refs/heads/" + planner.ALBUM_CORRECTION_BRANCH, "GITHUB_SHA": "a" * 40,
                   "GITHUB_REPOSITORY": "soso-so-27/neko-widget", "GITHUB_SERVER_URL": "https://github.com"}
            with patch.dict(os.environ, env), patch.object(planner, "changed_paths", return_value=[]), \
                    patch.object(planner, "runtime_scope", return_value=scope.FULL_SCOPE), \
                    patch.object(planner, "required_jobs", return_value=planner.ALBUM_CORRECTION_REQUIRED), \
                    patch.object(planner, "find_evidence", return_value=None), \
                    patch.object(planner, "find_test_correction_evidence", return_value={"run_id": 1, "sha": "b" * 40, "jobs": [{}] * 6}), \
                    contextlib.redirect_stdout(io.StringIO()) as printed:
                planner.main()
            values = dict(line.split("=", 1) for line in (root / "outputs").read_text().splitlines())
            self.assertEqual(values["app_ui_lanes"], '["app-ui-solo"]')
            self.assertEqual((values["build"], values["smoke"], values["sharing"], values["app_ui"]), ("false", "false", "false", "true"))
            record = next(json.loads(line.split("IOS_CI_PLAN_JSON=", 1)[1]) for line in printed.getvalue().splitlines() if line.startswith("IOS_CI_PLAN_JSON="))
            self.assertEqual(record["required_jobs"], list(planner.ALBUM_CORRECTION_REQUIRED))

    def test_candidate_plan_runs_only_normal_app_ui_after_verified_correction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            event = root / "event.json"
            event.write_text("{}", encoding="utf-8")
            output = root / "outputs"
            summary = root / "summary"
            head = "a" * 40
            env = {"GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(output),
                   "GITHUB_STEP_SUMMARY": str(summary), "GITHUB_EVENT_NAME": "push",
                   "GITHUB_REF": "refs/heads/codex/lost-cat", "GITHUB_SHA": head,
                   "GITHUB_REPOSITORY": "owner/repo", "GITHUB_SERVER_URL": "https://github.com"}
            correction = {"run_id": 10, "sha": "b" * 40, "jobs": []}
            printed = io.StringIO()
            with patch.dict(os.environ, env), patch.object(planner, "changed_paths", return_value=[scope.LOST_CAT_PHOTO_PATH]), \
                    patch.object(planner, "runtime_scope", return_value=planner.LOST_CAT_UX_SCOPE), \
                    patch.object(planner, "required_jobs", return_value=planner.required_jobs_from_scope(planner.LOST_CAT_UX_SCOPE)), \
                    patch.object(planner, "find_evidence", return_value=None), \
                    patch.object(planner, "find_test_correction_evidence", return_value=correction), \
                    contextlib.redirect_stdout(printed):
                planner.main()
            values = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
            self.assertEqual((values["build"], values["smoke"], values["sharing"], values["app_ui"]),
                             ("false", "false", "false", "true"))
            self.assertEqual(values["app_ui_lanes"], '["app-ui"]')
            record = next(json.loads(line.split("IOS_CI_PLAN_JSON=", 1)[1]) for line in printed.getvalue().splitlines()
                          if line.startswith("IOS_CI_PLAN_JSON="))
            self.assertEqual(record["test_correction_evidence"], correction)
            self.assertEqual(record["required_jobs"], list(planner.required_jobs_from_scope(planner.LOST_CAT_UX_SCOPE)))

    def test_managed_pilot_correction_excludes_product_and_fixture_changes(self):
        self.test_only_existing_owned_test_bodies_and_ci_controls_may_change(scope.REVIEWED_MANAGED_PRESERVATION_SCOPE)

    def test_managed_deletion_correction_excludes_product_and_fixture_changes(self):
        self.test_only_existing_owned_test_bodies_and_ci_controls_may_change(
            scope.REVIEWED_MANAGED_PRESERVATION_SCOPE, "testManagedPreservationAccountDeletionRetainsReceiptAndCompletes")

    def test_vet_correction_excludes_product_fixture_other_methods_and_unmerged_controls(self):
        self.test_only_existing_owned_test_bodies_and_ci_controls_may_change(scope.VET_SAVED_CAT_SCOPE)

    def test_only_existing_owned_test_bodies_and_ci_controls_may_change(self, selected_scope=scope.LOST_CAT_UX_SCOPE, body_method=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], text=True,
                                               encoding="utf-8", stderr=subprocess.PIPE).rstrip("\n")
            def write(path, value):
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(value, encoding="utf-8")
            def commit():
                git("add", ".")
                git("-c", "user.name=CI", "-c", "user.email=ci@example.invalid",
                    "commit", "-qm", "fixture")
                return git("rev-parse", "HEAD")
            git("init", "-q")
            names = (["testManagedPreservationLostCopyResultShowsConfirmationAndStoredState",
                      "testManagedPreservationAccountDeletionRetainsReceiptAndCompletes"]
                     if selected_scope == scope.REVIEWED_MANAGED_PRESERVATION_SCOPE else
                     ["testVeterinarySelectionIsExplicitAndRemovalKeepsSource"] if selected_scope == scope.VET_SAVED_CAT_SCOPE else
                     sorted(scope.LOST_CAT_PHOTO_TEST_NAMES))
            before = ("final class SoloMemoriesUITests: XCTestCase {\n"
                      + "".join(f"    func {name}() {{\n        XCTAssertTrue(true)\n    }}\n"
                                for name in names) + "}\n")
            needle = f"func {body_method or names[0]}() {{\n        XCTAssertTrue(true)"
            after = before.replace(needle, needle.replace("XCTAssertTrue(true)", "XCTAssertTrue(false)"), 1)
            test_path = scope.MEMORY_TEST_PATH
            control = "NekoWidget/ci/plan-ios-ci.py"
            product = "NekoWidget/NekoWidget/Views/CatPreparednessView.swift"
            workflow = ".github/workflows/ios-build.yml"
            for path, value in ((test_path, before), (control, "old\n"),
                                (product, "old\n"), (workflow, "old\n")):
                write(path, value)
            source = commit()
            with patch.object(planner, "git", side_effect=git):
                write(test_path, after)
                write(control, "new\n")
                head = commit()
                if selected_scope == scope.VET_SAVED_CAT_SCOPE:
                    git("update-ref", "refs/remotes/origin/main", head)
                self.assertTrue(planner.test_correction_inputs(source, head, selected_scope))
                if selected_scope == scope.VET_SAVED_CAT_SCOPE:
                    # A later already-main backend control registration does
                    # not revoke the candidate's prior merged control inputs.
                    write(control, "later main control\n")
                    later_main = commit()
                    git("update-ref", "refs/remotes/origin/main", later_main)
                    git("checkout", "--detach", "-q", head)
                    self.assertTrue(planner.test_correction_inputs(source, head, selected_scope))
                    write(control, "unmerged control\n")
                    self.assertFalse(planner.test_correction_inputs(source, commit(), selected_scope))
                    for replacement in (after.replace("\n}\n", "\n    func testUnrelated() {}\n}\n", 1),
                                        after.replace("\n}\n", "\n    private func helper() {}\n}\n", 1)):
                        git("checkout", "--detach", "-q", source)
                        write(test_path, replacement)
                        self.assertFalse(planner.test_correction_inputs(source, commit(), selected_scope))
                forbidden = (product, workflow) + (("NekoWidget/NekoWidget/Views/EvacuationFixtureView.swift",
                    "NekoWidget/NekoWidget/Views/VeterinaryVisitView.swift") if selected_scope == scope.VET_SAVED_CAT_SCOPE else ())
                for path in forbidden:
                    git("checkout", "--detach", "-q", source)
                    write(test_path, after)
                    write(path, "new\n")
                    self.assertFalse(planner.test_correction_inputs(source, commit(), selected_scope))
                git("checkout", "--detach", "-q", source)
                write(test_path, before.replace("final class", "public final class"))
                self.assertFalse(planner.test_correction_inputs(source, commit(), selected_scope))

    def test_managed_pilot_failed_source_requires_each_successful_native_job(self):
        self.test_failed_source_reuses_only_three_successful_jobs(scope.REVIEWED_MANAGED_PRESERVATION_SCOPE)

    def test_vet_failed_source_requires_each_successful_native_job(self):
        self.test_failed_source_reuses_only_three_successful_jobs(scope.VET_SAVED_CAT_SCOPE)

    def test_failed_source_reuses_only_three_successful_jobs(self, selected_scope=scope.LOST_CAT_UX_SCOPE):
        now = dt.datetime.now(dt.timezone.utc)
        head, source = "a" * 40, "b" * 40
        required = planner.required_jobs_from_scope(selected_scope)
        run = {"id": 10, "workflow_id": 5, "head_sha": source, "head_branch": "codex/lost-cat",
               "event": "push", "status": "completed", "conclusion": "failure",
               "updated_at": now.isoformat(), "repository": {"full_name": "owner/repo"},
               "head_repository": {"full_name": "owner/repo"}}
        jobs = [{"id": 100, "name": planner.PLAN_JOB, "head_sha": source,
                 "status": "completed", "conclusion": "success"}]
        jobs += [{"id": 101 + index, "name": name, "head_sha": source, "status": "completed",
                  "conclusion": "failure" if name == required[-1] else "success",
                  "completed_at": now.isoformat()} for index, name in enumerate(required)]
        with patch.object(planner, "test_correction_inputs", return_value=True), \
                patch.object(planner, "executed_jobs", return_value=jobs):
            evidence = planner.correction_source(run, head, "codex/lost-cat", "owner/repo", 5,
                                                 required, None, now)
            self.assertEqual([entry["name"] for entry in evidence["jobs"]], list(required[:3]))
            for index in range(1, 4):
                broken = copy.deepcopy(jobs)
                broken[index]["conclusion"] = "skipped"
                with patch.object(planner, "executed_jobs", return_value=broken):
                    self.assertIsNone(planner.correction_source(run, head, "codex/lost-cat", "owner/repo", 5,
                                                                 required, None, now))
            self.assertIsNone(planner.correction_source({**run, "head_branch": "codex/other"}, head,
                                                        "codex/lost-cat", "owner/repo", 5, required, None, now))


class PhotoSmokeCorrectionTests(unittest.TestCase):
    def setUp(self):
        self.now = dt.datetime.now(dt.timezone.utc)
        self.head = "a" * 40
        self.source = planner.PHOTO_SMOKE_CORRECTION_SOURCE
        self.required = planner.ALBUM_CORRECTION_REQUIRED
        self.solo_job = planner.PHOTO_SMOKE_CORRECTION_SOLO_JOB
        self.other_job = scope.lane_job(scope.FULL_SCOPE, "app-ui-other")
        self.owning = (planner.SMOKE, self.other_job, self.solo_job)
        self.run = {"id": planner.PHOTO_SMOKE_CORRECTION_RUN, "workflow_id": 5,
                    "head_sha": self.source, "head_branch": planner.PHOTO_SMOKE_CORRECTION_BRANCH,
                    "event": "push", "status": "completed", "conclusion": "failure", "run_attempt": 1,
                    "updated_at": self.now.isoformat(),
                    "repository": {"full_name": "soso-so-27/neko-widget"},
                    "head_repository": {"full_name": "soso-so-27/neko-widget"}}
        self.jobs = [{"id": 100, "name": planner.PLAN_JOB, "head_sha": self.source,
                      "status": "completed", "conclusion": "success"}]
        source_outcomes = {planner.SMOKE: "failure", self.other_job: "failure", self.solo_job: "cancelled"}
        for index, name in enumerate(self.required):
            job = {"id": 101 + index, "name": name, "head_sha": self.source, "status": "completed",
                   "conclusion": source_outcomes.get(name, "success"), "completed_at": self.now.isoformat()}
            if name == self.solo_job:
                job["id"] = planner.PHOTO_SMOKE_CORRECTION_SOLO_JOB_ID
                job["steps"] = [
                    {"name": "Run sharing runtime matrix", "status": "completed", "conclusion": "cancelled"},
                    {"name": "Upload sharing runtime matrix artifacts", "status": "completed", "conclusion": "failure"},
                ]
            self.jobs.append(job)
        self.plan = {"schema_version": 1, "repository": "soso-so-27/neko-widget", "head_sha": self.source,
                     "scope": scope.FULL_SCOPE, "required_jobs": list(self.required),
                     "evidence_run_id": None, "evidence_sha": None}
        self.failures = "\n".join("Test Case '-[NekoWidgetUITests." + case.replace("/", " ") + "]' failed"
                                  for case in sorted(planner.PHOTO_SMOKE_CORRECTION_CASES))
        self.solo_log = ("Test Suite 'SoloMemoriesUITests' passed at 2026-10-05 01:13:21.029.\n"
                         + "Executed 46 tests, with 0 failures (0 unexpected) in 3676.850 (3676.913) seconds\n" * 3
                         + "** TEST SUCCEEDED **\n"
                         + "Sharing checks [app-ui-solo; scope full-v1]\tUpload sharing runtime matrix artifacts\n"
                         + "Error: ENOENT: no such file or directory, open '/Users/runner/work/_temp/MomentComposer.xcresult/Staging/1_Test/Diagnostics/session.log'\n"
                         + "Error: An error has occurred during zip creation for the artifact\n")

    def source_check(self, jobs=None, run=None, failures=None, plan=None, solo_log=None):
        def api(path):
            if path.endswith("/jobs/100/logs"):
                return "IOS_CI_PLAN_JSON=" + json.dumps(self.plan if plan is None else plan)
            if path.endswith(f"/jobs/{planner.PHOTO_SMOKE_CORRECTION_SOLO_JOB_ID}/logs"):
                return self.solo_log if solo_log is None else solo_log
            return self.failures if failures is None else failures
        with patch.object(planner, "test_correction_inputs", return_value=True), \
                patch.object(planner, "executed_jobs", return_value=self.jobs if jobs is None else jobs):
            return planner.correction_source(self.run if run is None else run, self.head,
                planner.PHOTO_SMOKE_CORRECTION_BRANCH, "soso-so-27/neko-widget", 5,
                self.required, api, self.now)

    def test_pin_rejects_other_bodies_product_modes_and_unapproved_controls(self):
        workflow_before = ("  sharing-app-ui:\n" + planner.PHOTO_SMOKE_CORRECTION_OLD_BUDGET)
        workflow_after = workflow_before.replace(
            planner.PHOTO_SMOKE_CORRECTION_OLD_BUDGET, planner.PHOTO_SMOKE_CORRECTION_NEW_BUDGET, 1)
        memory_row = ":100644 100644 " + " ".join(planner.PHOTO_SMOKE_CORRECTION_BLOBS) + " M\0" + scope.MEMORY_TEST_PATH + "\0"
        workflow_row = ":100644 100644 " + "e" * 40 + " " + "f" * 40 + " M\0" + planner.PHOTO_SMOKE_CORRECTION_WORKFLOW_PATH + "\0"
        row = memory_row + workflow_row
        def check(raw=row, approval=True, source_workflow=workflow_before, candidate_workflow=workflow_after):
            def git(*args):
                if args[0] == "rev-parse": return self.head
                if args[0] == "diff": return raw
                if args[0] == "merge-base": return "c" * 40
                if args[0] == "show":
                    revision, path = args[1].split(":", 1)
                    if path == planner.PHOTO_SMOKE_CORRECTION_WORKFLOW_PATH:
                        if revision == self.source: return source_workflow
                        if revision == self.head: return candidate_workflow
                        return candidate_workflow if approval else "unmerged"
                    return "approved" if approval or not revision.startswith(self.head) else "unmerged"
                raise AssertionError(args)
            with patch.object(planner, "git", side_effect=git):
                return planner.photo_smoke_correction_inputs(self.source, self.head)
        self.assertTrue(check())
        self.assertFalse(check(approval=False))
        self.assertFalse(check(raw=memory_row))
        self.assertFalse(check(source_workflow=workflow_before.replace("timeout-minutes: 75", "timeout-minutes: 60")))
        self.assertFalse(check(candidate_workflow=workflow_after.replace("timeout-minutes: 90", "timeout-minutes: 95")))
        self.assertFalse(check(candidate_workflow=workflow_after + "extra\n"))
        for path in ("NekoWidget/ci/test-ci-lanes.py", "NekoWidget/ci/test-release-flow.py"):
            control_row = f":100644 100644 {'c' * 40} {'d' * 40} M\0{path}\0"
            self.assertTrue(check(raw=row + control_row))
            self.assertFalse(check(raw=row + control_row, approval=False))
        for raw in ("", row + row, row.replace("100644 100644", "100644 100755"),
                    row.replace(" M\0", " T\0"), row.replace(planner.PHOTO_SMOKE_CORRECTION_BLOBS[1], "d" * 40),
                    row + row.replace(scope.MEMORY_TEST_PATH, "NekoWidget/NekoWidget/Views/LikedPhotosView.swift"),
                    row + row.replace(scope.MEMORY_TEST_PATH, ".github/workflows/ios-build.yml")):
            self.assertFalse(check(raw), raw)

    def test_source_reuses_only_four_successes_and_reruns_every_failed_or_incomplete_lane(self):
        result = self.source_check()
        self.assertEqual({item["name"] for item in result["jobs"]}, set(self.required) - set(self.owning))
        self.assertEqual(len(result["jobs"]), 4)
        for index, job in enumerate(self.jobs):
            for conclusion in ("skipped", "failure", "success", "cancelled"):
                if conclusion == job["conclusion"]: continue
                broken = copy.deepcopy(self.jobs); broken[index]["conclusion"] = conclusion
                if job["name"] not in self.owning and conclusion == "success": continue
                self.assertIsNone(self.source_check(jobs=broken))
        self.assertIsNone(self.source_check(jobs=self.jobs + [self.jobs[-1]]))
        for failures in ("", self.failures.splitlines()[0], self.failures + "\n" + self.failures,
                         self.failures + "\nTest Case '-[NekoWidgetUITests.SoloMemoriesUITests testOther]' failed"):
            self.assertIsNone(self.source_check(failures=failures))
        for invalid_log in (self.solo_log.replace("Executed 46 tests, with 0 failures", "Executed 46 tests, with 1 failure", 1),
                            self.solo_log.replace("** TEST SUCCEEDED **", "** TEST FAILED **", 1),
                            self.solo_log.replace("ENOENT: no such file or directory", "EACCES: permission denied", 1),
                            self.solo_log.replace("Error: An error has occurred during zip creation for the artifact\n", "")):
            self.assertIsNone(self.source_check(solo_log=invalid_log))
        for key, value in (("id", 1), ("head_sha", "b" * 40), ("event", "workflow_dispatch"),
                           ("run_attempt", 2), ("head_branch", "codex/other"),
                           ("updated_at", (self.now - dt.timedelta(hours=25)).isoformat())):
            self.assertIsNone(self.source_check(run={**self.run, key: value}))
        for key, value in (("required_jobs", list(self.required[:-1])), ("head_sha", "b" * 40),
                           ("evidence_run_id", 4), ("test_correction_evidence", {})):
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):
                self.source_check(plan={**self.plan, key: value})

    def test_new_candidate_selects_complete_smoke_and_both_ui_lanes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / "event.json").write_text("{}")
            env = {"GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_OUTPUT": str(root / "output"),
                   "GITHUB_STEP_SUMMARY": str(root / "summary"), "GITHUB_EVENT_NAME": "push",
                   "GITHUB_REF": "refs/heads/" + planner.PHOTO_SMOKE_CORRECTION_BRANCH,
                   "GITHUB_SHA": self.head, "GITHUB_REPOSITORY": "soso-so-27/neko-widget",
                   "GITHUB_SERVER_URL": "https://github.com"}
            with patch.dict(os.environ, env), patch.object(planner, "changed_paths", return_value=[]), \
                    patch.object(planner, "runtime_scope", return_value=scope.FULL_SCOPE), \
                    patch.object(planner, "required_jobs", return_value=self.required), \
                    patch.object(planner, "find_evidence", return_value=None), \
                    patch.object(planner, "find_test_correction_evidence", return_value=self.source_check()), \
                    contextlib.redirect_stdout(io.StringIO()) as printed:
                planner.main()
            values = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            self.assertEqual((values["build"], values["smoke"], values["sharing"], values["app_ui"]),
                             ("false", "true", "false", "true"))
            self.assertEqual(values["app_ui_lanes"], '["app-ui-other","app-ui-solo"]')
            record = next(json.loads(line.split("IOS_CI_PLAN_JSON=", 1)[1]) for line in printed.getvalue().splitlines()
                          if line.startswith("IOS_CI_PLAN_JSON="))
            self.assertEqual(record["required_jobs"], list(self.required))

    def test_main_and_release_qualify_new_three_and_revalidate_original_four(self):
        evidence = self.source_check()
        candidate = {**self.run, "id": 20, "head_sha": self.head, "conclusion": "success"}
        current_jobs = [{**job, "id": job["id"] + 100, "head_sha": self.head,
                         "conclusion": "success" if job["name"] in {planner.PLAN_JOB, *self.owning} else "skipped"}
                        for job in self.jobs]
        record = {**self.plan, "head_sha": self.head, "test_correction_evidence": evidence}
        def check(jobs=current_jobs, original=self.jobs, selected_record=record):
            def api(path):
                if path.endswith("/runs/" + str(self.run["id"])): return self.run
                if path.endswith("/jobs/200/logs"): return "IOS_CI_PLAN_JSON=" + json.dumps(selected_record)
                if path.endswith("/jobs/100/logs"): return "IOS_CI_PLAN_JSON=" + json.dumps(self.plan)
                if path.endswith(f"/jobs/{planner.PHOTO_SMOKE_CORRECTION_SOLO_JOB_ID}/logs"): return self.solo_log
                return self.failures
            with patch.object(planner, "test_correction_inputs", return_value=True), \
                    patch.object(planner, "executed_jobs", return_value=original):
                return planner.covers_corrected_full_graph(candidate, "c" * 40, self.required, api, self.now, jobs)
        self.assertTrue(check())
        for index, job in enumerate(current_jobs):
            if job["name"] not in self.owning: continue
            for outcome in ("skipped", "failure"):
                broken = copy.deepcopy(current_jobs); broken[index]["conclusion"] = outcome
                self.assertFalse(check(jobs=broken))
            self.assertFalse(check(jobs=current_jobs + [job]))
        for index, job in enumerate(self.jobs):
            if job["name"] in self.owning: continue
            broken = copy.deepcopy(self.jobs); broken[index]["conclusion"] = "skipped"
            self.assertFalse(check(original=broken))
        self.assertFalse(check(selected_record={**record, "head_sha": "b" * 40}))
        self.assertFalse(check(selected_record={**record, "evidence_run_id": 7}))
        self.assertFalse(check(selected_record={**record, "test_correction_evidence": {**evidence, "run_id": 7}}))


class ToolReleaseReadinessInputTests(unittest.TestCase):
    def setUp(self):
        self.head, self.approval = "c"*40, "d"*40
        self.before = {path: f"100644 blob {pair[0]}\t{path}" for path, pair in planner.TOOL_RELEASE_BLOBS.items()}
        self.after = {path: f"100644 blob {pair[1]}\t{path}" for path, pair in planner.TOOL_RELEASE_BLOBS.items()}
        for path in planner.TOOL_RELEASE_CONTROLS:
            self.before[path] = f"100644 blob {'a'*40}\t{path}"
            self.after[path] = f"100644 blob {'b'*40}\t{path}"
        for path in ("NekoWidget/Shared/native.swift", ".github/workflows/ios-build.yml"):
            self.before[path] = self.after[path] = f"100644 blob {'e'*40}\t{path}"
        self.before["handoffs/old.md"] = self.after["handoffs/old.md"] = f"100644 blob {'f'*40}\thandoffs/old.md"
        self.after["handoffs/new.md"] = f"100644 blob {'f'*40}\thandoffs/new.md"
        inputs = [row for path, row in sorted(self.before.items()) if path not in planner.TOOL_RELEASE_BLOBS and not planner.is_handoff(path)]
        self.count = len(inputs)
        self.digest = planner.hashlib.sha256(("\0".join(inputs)+"\0").encode()).hexdigest()

    def verify(self, *, after=None, approved=True, ancestor=True, current=False, dirty=False, signature=True, marker=True):
        after = self.after if after is None else after
        def git(*args):
            if args[0] == "merge-base":
                if "--is-ancestor" in args and not ancestor: raise subprocess.CalledProcessError(1,args)
                return self.approval
            if args[0] == "ls-tree":
                if "-r" in args:
                    rows = self.before if args[-1] == planner.TOOL_RELEASE_BASE else after
                    return "\0".join(rows[path] for path in sorted(rows))+"\0"
                return after[args[-1]] if approved else self.before[args[-1]]
            if args[0] == "show":
                if args[1].endswith("plan-ios-ci.py"):
                    return f'TOOL_RELEASE_BASE = "{planner.TOOL_RELEASE_BASE}"' if marker else "not_approved"
                return "{}"
            if args[0] == "rev-parse": return self.head
            if args[0] == "status": return " M changed" if dirty else ""
            raise AssertionError(args)
        result = subprocess.CompletedProcess([],0 if signature else 1,stdout=json.dumps({"purpose":"testflight-owner-report-ui-continuation"}))
        with patch.object(planner,"git",side_effect=git), patch.object(planner,"TOOL_RELEASE_INPUT_COUNT",self.count), \
             patch.object(planner,"TOOL_RELEASE_INPUT_SHA256",self.digest), patch.object(planner.subprocess,"run",return_value=result) as check:
            valid=planner.tool_release_readiness_inputs(self.head,current=current)
            if current and valid:
                self.assertEqual(check.call_args.args[0],["node","NekoWidget/ci/verify-moderation-readiness.mjs"])
                self.assertNotIn("now",json.loads(check.call_args.kwargs["input"]))
            return valid

    def test_exact_three_pairs_full_input_closure_and_current_clock_signature(self):
        self.assertTrue(self.verify())
        self.assertTrue(self.verify(current=True))
        for kwargs in ({"approved":False},{"ancestor":False},{"marker":False},
                       {"current":True,"dirty":True},{"current":True,"signature":False}):
            self.assertFalse(self.verify(**kwargs),kwargs)
        for path in planner.TOOL_RELEASE_BLOBS:
            for metadata in (f"100644 blob {'0'*40}",f"100755 blob {planner.TOOL_RELEASE_BLOBS[path][1]}",f"120000 blob {planner.TOOL_RELEASE_BLOBS[path][1]}"):
                changed=dict(self.after);changed[path]=metadata+"\t"+path
                self.assertFalse(self.verify(after=changed))
        for path in ("NekoWidget/Shared/native.swift",".github/workflows/ios-build.yml"):
            changed=dict(self.after);changed[path]=f"100644 blob {'0'*40}\t{path}"
            self.assertFalse(self.verify(after=changed))
        for path in ("NekoWidget/ci/unknown.py","NekoWidget/ci/new-test.py"):
            changed=dict(self.after);changed[path]=f"100644 blob {'e'*40}\t{path}"
            self.assertFalse(self.verify(after=changed))
        changed=dict(self.after);del changed["handoffs/old.md"]
        self.assertFalse(self.verify(after=changed))

    def test_registered_closure_matches_the_actual_successful_source_tree(self):
        result=subprocess.run(["git","ls-tree","-r","-z",planner.TOOL_RELEASE_BASE],
            cwd=Path(__file__).parents[2],capture_output=True,text=True,encoding="utf-8",check=True)
        rows=[]
        for row in result.stdout.split("\0"):
            if not row:continue
            metadata,path=row.split("\t",1)
            self.assertRegex(metadata,r"^100644 blob [0-9a-f]{40}$")
            if path not in planner.TOOL_RELEASE_BLOBS and not (path.startswith("handoffs/") and path.endswith(".md")):rows.append(row)
        rows.sort(key=lambda row:row.split("\t",1)[1])
        self.assertEqual(len(rows),planner.TOOL_RELEASE_INPUT_COUNT)
        self.assertEqual(planner.hashlib.sha256(("\0".join(rows)+"\0").encode()).hexdigest(),planner.TOOL_RELEASE_INPUT_SHA256)

    def test_owning_branch_failure_stops_before_native_and_success_keeps_existing_tuple(self):
        env={"GITHUB_REF":"refs/heads/"+planner.TOOL_RELEASE_BRANCH,"GITHUB_SHA":self.head}
        paths=list(planner.TOOL_RELEASE_BLOBS)
        with patch.object(planner,"tool_release_readiness_inputs",return_value=True):
            self.assertEqual(planner.runtime_scope(paths,{},env),planner.TOOL_PRESERVATION_SCOPE)
            self.assertEqual(planner.required_jobs(paths,planner.TOOL_PRESERVATION_SCOPE),planner.required_jobs_from_scope(planner.TOOL_PRESERVATION_SCOPE))
        with patch.object(planner,"tool_release_readiness_inputs",return_value=False),self.assertRaises(ValueError):
            planner.runtime_scope(paths,{},env)


class ToolReleaseReadinessGraphTests(unittest.TestCase):
    def setUp(self):
        self.old=ToolBuildRecoveryTests();self.old.setUp()
        f=self.old
        self.head,self.main="c"*40,"d"*40
        self.run=dict(f.candidate,id=2001,head_sha=self.head,head_branch=planner.TOOL_RELEASE_BRANCH)
        self.jobs=copy.deepcopy(f.candidate_jobs)
        for index,job in enumerate(self.jobs):job.update(id=20011+index,run_id=2001,head_sha=self.head)
        self.log=None
        self.extra_backend=False
        self.extra_native=False

    def api(self,path):
        prefix=f"/repos/{self.old.repo}/actions/"
        for head in (self.head,self.main):
            if f"head_sha={head}" in path:
                if "/workflows/ios-build.yml/" in path:
                    return {"total_count":2 if self.extra_native else 1,"workflow_runs":[self.run,self.run] if self.extra_native else [self.run]}
                return {"total_count":1,"workflow_runs":[{"status":"in_progress"}]} if self.extra_backend else {"total_count":0,"workflow_runs":[]}
        if path==prefix+"jobs/20011/logs":return self.log
        if path==prefix+"runs/2001":return self.run
        if path==prefix+"runs/2001/jobs?filter=latest&per_page=100&page=1":return {"total_count":len(self.jobs),"jobs":self.jobs}
        return self.old.api(path)

    @contextlib.contextmanager
    def mocks(self):
        with self.old.mocks(),patch.object(planner,"TOOL_RELEASE_BASE",self.old.head), \
             patch.object(planner,"TOOL_RELEASE_BASE_RUN",self.old.candidate["id"]), \
             patch.object(planner,"tool_release_readiness_inputs",return_value=True):
            if self.log is None:
                proof=planner.tool_release_readiness_source(self.head,self.old.repo,self.api,self.old.now)
                record=self.old.record(self.old.head)
                record.update(head_sha=self.head,test_correction_evidence=proof,required_backend_runs=[proof["backend_evidence"]])
                self.log="IOS_CI_PLAN_JSON="+json.dumps(record)
            yield

    def covers(self):
        return planner.covers_corrected_full_graph(self.run,self.main,self.old.required,self.api,self.old.now,self.jobs)

    def test_new_full_build_old_three_native_fixed_backend_and_failure_history_are_one_proof(self):
        with self.mocks():
            self.assertTrue(self.covers())
            proof=json.loads(self.log.split("=",1)[1])["test_correction_evidence"]
            self.assertEqual(proof["kind"],planner.TOOL_RELEASE_KIND)
            self.assertEqual(len(proof["jobs"]),3)
            self.assertFalse(proof["source_build_success"])
            self.assertFalse(proof["backend_evidence"]["push_evidence"])
            self.assertTrue(proof["new_build_required"])
            self.assertEqual(planner.find_test_correction_evidence(self.head,planner.TOOL_RELEASE_BRANCH,self.old.repo,self.old.required,self.api,self.old.now),proof)
            for step in self.jobs[1]["steps"]:
                step["conclusion"]="skipped";self.assertFalse(self.covers(),step["name"]);step["conclusion"]="success"
            self.extra_backend=True;self.assertFalse(self.covers());self.extra_backend=False
            self.extra_native=True;self.assertFalse(self.covers());self.extra_native=False
            with patch.object(planner,"tool_release_readiness_inputs",return_value=False):self.assertFalse(self.covers())
            for field,value in (("run_attempt",True),("status","in_progress"),("head_branch","codex/other"),("updated_at","2026-10-12T06:00:00Z")):
                original=self.run[field];self.run[field]=value;self.assertFalse(self.covers());self.run[field]=original

    def test_unknown_decl_changed_old_native_and_bad_backend_fail_without_rerun(self):
        with self.mocks():
            original=self.log
            for field,value in (("required_backend_runs",[]),("evidence_run_id",1),("test_correction_evidence",{})):
                record=json.loads(original.split("=",1)[1]);record[field]=value;self.log="IOS_CI_PLAN_JSON="+json.dumps(record)
                self.assertFalse(self.covers(),field)
            self.log=original
            self.old.pr_jobs[0]["steps"][0]["conclusion"]="skipped";self.assertFalse(self.covers())
            self.old.pr_jobs[0]["steps"][0]["conclusion"]="success"
            native=next(job for job in self.old.source_jobs if job["name"]==planner.BOOTSTRAP_SMOKE)
            native["conclusion"]="failure";self.assertFalse(self.covers())



class ToolStorageCompletionScopeTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40
    def setUp(self):
        self.common = f"100644 blob {'f' * 40}\tNekoWidget/Shared/unchanged.swift"
        binding = patch.object(planner, "TOOL_STORAGE_READINESS_PAIR", None)
        binding.start(); self.addCleanup(binding.stop)
        for name, value in (("TOOL_STORAGE_CLOSURE_COUNT", 1), ("TOOL_STORAGE_CLOSURE_SHA256",
                hashlib.sha256((self.common + "\0").encode()).hexdigest())):
            binding = patch.object(planner, name, value); binding.start(); self.addCleanup(binding.stop)
    def rows(self, fresh=False):
        pairs = dict(planner.TOOL_STORAGE_BLOBS)
        if fresh: pairs[planner.TOOL_STORAGE_READINESS_PATH] = (planner.TOOL_STORAGE_READINESS_BEFORE, "d" * 40)
        return {p: [":000000" if before == "0" * 40 else ":100644", "100644", before, after,
                    "A" if before == "0" * 40 else "M"] for p, (before, after) in pairs.items()}
    def test_none_and_unknown_path_inputs_reject_before_iteration(self):
        for paths in (None, [], (), "path", True, 1, [None], [["path"]], {"path": "blob"}):
            self.assertFalse(planner.tool_storage_paths_only(paths))
            self.assertFalse(planner.tool_storage_control_paths_only(paths))
    def select(self, rows=None, *, raw=None, paths=None, override=None, event="push", ref="refs/heads/codex/tool-storage-completion-20261014"):
        rows = self.rows() if rows is None else rows
        paths = list(rows) if paths is None else paths
        def git(*args):
            if override and args in override: return override[args]
            if args[0] == "merge-base": return self.base
            if args[0] == "rev-parse": return self.head if args[1] == "HEAD" else "0" * 40
            if args[0] == "show": return 'TOOL_STORAGE_SCOPE = "reviewed-tool-storage-completion-v1"'
            if args[0] == "diff": return raw if raw is not None else "".join(" ".join(v)+"\0"+p+"\0" for p,v in rows.items())
            if args[0] == "ls-tree" and "-r" in args:
                pos = 0 if args[-1] == self.base else 1
                entries = [self.common]
                for p, pair in planner.TOOL_STORAGE_BLOBS.items():
                    if pair[pos] != "0" * 40: entries.append(f"100644 blob {pair[pos]}\t{p}")
                blob = (rows.get(planner.TOOL_STORAGE_READINESS_PATH) or
                        ["", "", planner.TOOL_STORAGE_READINESS_BEFORE, planner.TOOL_STORAGE_READINESS_BEFORE])[2+pos]
                entries.append(f"100644 blob {blob}\t{planner.TOOL_STORAGE_READINESS_PATH}")
                entries += [f"100644 blob {'e' * 40}\t{p}" for p in planner.TOOL_STORAGE_CONTROLS]
                return "\0".join(entries)+"\0"
            if args[0] == "ls-tree":
                revision,p=args[1],args[3]
                if p in planner.TOOL_STORAGE_CONTROLS: return f"100644 blob {'e' * 40}\t{p}"
                if p not in planner.TOOL_STORAGE_BLOBS: return ""
                pair=planner.TOOL_STORAGE_BLOBS[p];blob=pair[0 if revision==self.base else 1]
                return "" if blob=="0"*40 else f"100644 blob {blob}\t{p}"
            raise AssertionError(args)
        with patch.object(planner,"git",side_effect=git):
            payload = {"pull_request": {"base": {"sha": self.base}}} if event=="pull_request" else {"before":self.base}
            return planner.runtime_scope(paths,payload,{"GITHUB_SHA":self.head,"GITHUB_EVENT_NAME":event,"GITHUB_REF":ref})
    def test_exact_twenty_two_inputs_select_fresh_four_and_nine_ui_cases(self):
        selected=planner.TOOL_STORAGE_SCOPE
        self.assertEqual(self.select(),selected)
        self.assertEqual(self.select(ref="refs/heads/main"),selected)
        self.assertEqual(self.select(event="pull_request",ref="refs/pull/310/merge"),selected)
        jobs=planner.required_jobs(list(self.rows()),selected)
        self.assertEqual(jobs,planner.required_jobs_from_scope(selected));self.assertEqual(len(jobs),4)
        self.assertEqual(scope.lanes(selected),("runtime","app-ui"))
        self.assertEqual(len(scope.native_tests(selected)),9)
        self.assertEqual(len(planner.tool_storage_requirements(self.head)[0]["required_steps"]),8)
        self.assertIsNone(planner.test_correction_scope(jobs))
    def test_partial_unknown_mode_rename_duplicate_and_truncated_are_rejected(self):
        original=self.rows()
        for p,row in original.items():
            self.assertNotEqual(self.select({k:v for k,v in original.items() if k!=p}),planner.TOOL_STORAGE_SCOPE)
            for index,value in ((0,":100755"),(1,"120000"),(2,"c"*40),(3,"d"*40),(4,"D"),(4,"R100")):
                changed=copy.deepcopy(original);changed[p][index]=value
                self.assertEqual(self.select(changed),scope.FULL_SCOPE,(p,index,value))
        for p in [planner.PRESERVATION_WORKFLOW,"NekoWidget/Shared/MembershipAccessPolicy.swift",*planner.TOOL_STORAGE_CONTROLS]:
            changed=original|{p:[":100644","100644","c"*40,"d"*40,"M"]}
            self.assertEqual(self.select(changed),scope.FULL_SCOPE,p)
        raw="".join(" ".join(v)+"\0"+p+"\0" for p,v in original.items())
        for bad in ("",raw+raw,raw.rsplit("\0",2)[0]): self.assertEqual(self.select(raw=bad),scope.FULL_SCOPE)
        self.assertEqual(self.select(paths=list(original)+[next(iter(original))]),scope.FULL_SCOPE)
    def test_all_controls_and_nonhandoff_input_closure_are_bound(self):
        for ref in (self.base,self.head):
            for p in planner.TOOL_STORAGE_CONTROLS:
                self.assertEqual(self.select(override={("ls-tree",ref,"--",p):f"100644 blob {'c'*40}\t{p}"}),scope.FULL_SCOPE)
            self.assertEqual(self.select(override={("ls-tree","-r","-z",ref):self.common+"\0"}),scope.FULL_SCOPE)
        self.assertEqual(self.select(override={("show",f"{self.base}:NekoWidget/ci/ios_ci_scope.py"):""}),scope.FULL_SCOPE)
        note="NekoWidget/ci/release-candidates/2026-10-14-tool-preservation.md"
        self.assertTrue(planner.is_handoff(note));self.assertFalse(planner.tool_storage_handoff(note))
        with patch.object(planner,"git",return_value=self.common+"\0"+f"100644 blob {'f'*40}\t{note}\0"):
            with self.assertRaises(ValueError):planner.tool_storage_tree(self.head)
    def test_fresh_artifact_requires_separate_exact_pair_and_handoffs_do_not_hide_inputs(self):
        rows=self.rows(fresh=True)
        self.assertEqual(self.select(rows),scope.FULL_SCOPE)
        with patch.object(planner,"TOOL_STORAGE_READINESS_PAIR",(planner.TOOL_STORAGE_READINESS_BEFORE,"d"*40)):
            self.assertEqual(self.select(rows),planner.TOOL_STORAGE_SCOPE)
            rows[planner.TOOL_STORAGE_READINESS_PATH][3]="c"*40
            self.assertEqual(self.select(rows),scope.FULL_SCOPE)
        row=[":000000","100644","0"*40,"c"*40,"A"]
        self.assertEqual(self.select(self.rows()|{"handoffs/storage-completion.md":row}),planner.TOOL_STORAGE_SCOPE)
        self.assertEqual(self.select(self.rows()|{"NekoWidget/ci/release-candidates/new.md":row}),scope.FULL_SCOPE)
    def test_signature_uses_real_current_clock_and_never_accepts_verifier_failure(self):
        def git(*args):
            if args[0]=="rev-parse":return self.head
            if args[0]=="status":return ""
            if args[0]=="show":return "{}"
            if args[0]=="ls-tree":return f"100644 blob {'d'*40}\t{planner.TOOL_STORAGE_READINESS_PATH}"
            raise AssertionError(args)
        with patch.object(planner,"tool_storage_inputs",return_value=True),patch.object(planner,"git",side_effect=git), \
                patch.object(planner,"TOOL_STORAGE_READINESS_PAIR",(planner.TOOL_STORAGE_READINESS_BEFORE,"d"*40)):
            for returncode,stdout in ((1,'{"verified":true,"purpose":"testflight-owner-report-ui-continuation"}'),
                    (0,'{}'),(0,'{"verified":false,"purpose":"testflight-owner-report-ui-continuation"}'),(0,'bad')):
                result=type("Process",(),{"returncode":returncode,"stdout":stdout})()
                with patch.object(planner.subprocess,"run",return_value=result):self.assertFalse(planner.tool_storage_readiness(self.head))
            result=type("Process",(),{"returncode":0,"stdout":'{"verified":true,"purpose":"testflight-owner-report-ui-continuation"}'})()
            with patch.object(planner.subprocess,"run",return_value=result) as verify:
                self.assertTrue(planner.tool_storage_readiness(self.head))
                self.assertNotIn("now",json.loads(verify.call_args.kwargs["input"]))


class ToolStorageCompletionControlTests(unittest.TestCase):
    base, head = "b" * 40, "a" * 40
    def setUp(self):
        self.common=f"100644 blob {'f'*40}\tNekoWidget/Shared/unchanged.swift"
        self.pair=(planner.TOOL_STORAGE_READINESS_BEFORE,"d"*40)
        for name,value in (("TOOL_STORAGE_CLOSURE_COUNT",1),("TOOL_STORAGE_CLOSURE_SHA256",hashlib.sha256((self.common+"\0").encode()).hexdigest()),
                ("TOOL_STORAGE_READINESS_PAIR",self.pair)):
            binding=patch.object(planner,name,value);binding.start();self.addCleanup(binding.stop)
        self.rows={p:[":100644","100644",before,"e"*40,"M"] for p,before in planner.TOOL_STORAGE_CONTROL_BEFORE.items()}
        self.rows[planner.TOOL_STORAGE_READINESS_PATH]=[":100644","100644",*self.pair,"M"]
    def prove(self,rows=None,override=None,signature=True):
        rows=self.rows if rows is None else rows
        def git(*args):
            if override and args in override:return override[args]
            if args[0]=="diff":return "".join(" ".join(v)+"\0"+p+"\0" for p,v in rows.items())
            if args[0]=="ls-tree" and "-r" in args:
                entries=[self.common]
                entries += [f"100644 blob {pair[0]}\t{p}" for p,pair in planner.TOOL_STORAGE_BLOBS.items() if pair[0]!="0"*40]
                entries += [f"100644 blob {r[2 if args[-1]==self.base else 3]}\t{p}" for p,r in self.rows.items()]
                return "\0".join(entries)+"\0"
            if args[0]=="ls-tree":
                ref,p=args[1],args[3];blob=self.rows[p][2 if ref==self.base else 3]
                return f"100644 blob {blob}\t{p}"
            raise AssertionError(args)
        with patch.object(planner,"git",side_effect=git),patch.object(planner,"tool_storage_signature",return_value=signature):
            return planner.tool_storage_control_only(list(rows),self.base,self.head)
    def test_only_control_introduction_with_exact_genuine_artifact_is_plan_only(self):
        self.assertTrue(self.prove())
        self.assertEqual(planner.required_jobs(list(self.rows),planner.ORCHESTRATION_SCOPE),(planner.PLAN_JOB,))
        self.assertFalse(self.prove(signature=False))
        with patch.object(planner,"TOOL_STORAGE_READINESS_PAIR",None):self.assertFalse(self.prove())
    def test_product_workflow_mode_old_control_missing_and_artifact_drift_reject(self):
        for p in self.rows:
            self.assertFalse(self.prove({k:v for k,v in self.rows.items() if k!=p}))
            for i,value in ((0,":100755"),(1,"120000"),(2,"c"*40),(4,"D")):
                changed=copy.deepcopy(self.rows);changed[p][i]=value;self.assertFalse(self.prove(changed))
        for p in [planner.PRESERVATION_WORKFLOW,*planner.TOOL_STORAGE_PATHS]:
            self.assertFalse(self.prove(self.rows|{p:[":100644","100644","c"*40,"d"*40,"M"]}))
        for ref in (self.base,self.head):
            self.assertFalse(self.prove(override={("ls-tree","-r","-z",ref):self.common+"\0"}))


class ToolStorageCompletionDiagnosticTests(unittest.TestCase):
    def test_only_exact_diagnostic_product_can_cross_approved_controls_and_artifact(self):
        source=planner.TOOL_STORAGE_SOURCE;head="a"*40
        before={p:f"100644 blob {pair[1]}\t{p}" for p,pair in planner.TOOL_STORAGE_BLOBS.items()}
        before |= {p:f"100644 blob {blob}\t{p}" for p,blob in planner.TOOL_STORAGE_CONTROL_BEFORE.items()}
        before[planner.TOOL_STORAGE_READINESS_PATH]=f"100644 blob {planner.TOOL_STORAGE_READINESS_BEFORE}\t{planner.TOOL_STORAGE_READINESS_PATH}"
        after=dict(before)
        for p in planner.TOOL_STORAGE_CONTROLS|{planner.TOOL_STORAGE_READINESS_PATH}:after[p]=f"100644 blob {'d'*40}\t{p}"
        raw="".join(f":100644 100644 {before[p].split()[2]} {after[p].split()[2]} M\0{p}\0"
            for p in planner.TOOL_STORAGE_CONTROLS|{planner.TOOL_STORAGE_READINESS_PATH})
        def git(*args):return "" if args[0]=="merge-base" else raw
        with patch.object(planner,"tool_storage_inputs",return_value=True),patch.object(planner,"tool_storage_tree",side_effect=lambda ref:before if ref==source else after), \
                patch.object(planner,"git",side_effect=git):
            self.assertTrue(planner.tool_storage_diagnostic_inputs(source,head))
            self.assertFalse(planner.tool_storage_diagnostic_inputs("c"*40,head))
            p=next(iter(planner.TOOL_STORAGE_PATHS));saved=after[p];after[p]=f"100644 blob {'c'*40}\t{p}"
            self.assertFalse(planner.tool_storage_diagnostic_inputs(source,head));after[p]=saved
            with patch.object(planner,"tool_storage_inputs",return_value=False):self.assertFalse(planner.tool_storage_diagnostic_inputs(source,head))


class ToolStorageCompletionGraphTests(unittest.TestCase):
    def setUp(self):
        self.now=dt.datetime(2026,10,15,1,tzinfo=dt.timezone.utc);self.sha="a"*40;self.main="b"*40
        self.repo="soso-so-27/neko-widget";self.required=planner.required_jobs_from_scope(planner.TOOL_STORAGE_SCOPE)
        self.run={"id":123,"head_sha":self.sha,"workflow_id":335014238,"path":".github/workflows/ios-build.yml",
            "event":"push","head_branch":planner.TOOL_STORAGE_BRANCH,"run_attempt":1,"status":"completed",
            "conclusion":"success","updated_at":self.now.isoformat(),"repository":{"full_name":self.repo},"head_repository":{"full_name":self.repo}}
        self.build_steps=tuple("Build step "+str(i) for i in range(39))
        def job(name,identifier,run,steps):
            return {"id":identifier,"name":name,"run_id":run["id"],"head_sha":self.sha,"run_attempt":1,
                "status":"completed","conclusion":"success","completed_at":self.now.isoformat(),
                "steps":[{"name":n,"status":"completed","conclusion":"success"} for n in steps]}
        names={planner.BUILD:self.build_steps,planner.BOOTSTRAP_SMOKE:("Check out repository","Run Simulator smoke test","Upload Simulator smoke-test artifacts"),
            planner.lane_job(planner.TOOL_STORAGE_SCOPE,"runtime"):planner.OWNER_CLOUD_RUNTIME_STEPS,
            planner.lane_job(planner.TOOL_STORAGE_SCOPE,"app-ui"):planner.OWNER_CLOUD_RUNTIME_STEPS,
            planner.PLAN_JOB:("Check out repository","Test CI selection and evidence boundaries","Select checks")}
        self.jobs=[job(n,100+i,self.run,s) for i,(n,s) in enumerate(names.items())]
        self.jobs += [dict(job(planner.UNEXPANDED_SHARING_JOB,200+i,self.run,()),conclusion="skipped") for i in range(2)]
        self.plan={"schema_version":1,"repository":self.repo,"head_sha":self.sha,"scope":planner.TOOL_STORAGE_SCOPE,
            "required_jobs":list(self.required),"required_backend_runs":planner.tool_storage_requirements(self.sha),
            "evidence_run_id":None,"evidence_sha":None,"test_correction_evidence":None}
        self.backend=dict(self.run,id=456,workflow_id=363932714,path=planner.PRESERVATION_WORKFLOW,run_number=4)
        self.backend_jobs=[job(planner.PRESERVATION_JOB,500,self.backend,planner.TOOL_STORAGE_BACKEND_STEPS)]
    def api(self,path):
        if path.endswith("/jobs/103/logs"):
            return "\n".join(f"Test Case '-[NekoWidgetUITests.{test.removeprefix('NekoWidgetUITests/').replace('/', ' ')}]' {status}"
                for test in scope.native_tests(planner.TOOL_STORAGE_SCOPE) for status in ("started", "passed"))
        if path.endswith("/logs"):return "IOS_CI_PLAN_JSON="+json.dumps(self.plan)
        if path.endswith("/workflows/preservation-service.yml"):return {"id":363932714,"path":planner.PRESERVATION_WORKFLOW,"state":"active"}
        if "/workflows/preservation-service.yml/runs?" in path:return {"total_count":1,"workflow_runs":[self.backend]}
        if path.endswith("/runs/456"):return self.backend
        if "/runs/456/jobs?" in path:return {"total_count":len(self.backend_jobs),"jobs":self.backend_jobs}
        raise AssertionError(path)
    def mocks(self):
        stack=contextlib.ExitStack()
        for name,value in (("tool_storage_inputs",True),("tool_storage_readiness",True),("equivalent_inputs",True)):
            stack.enter_context(patch.object(planner,name,return_value=value))
        stack.enter_context(patch.object(planner,"tool_build_steps",return_value=self.build_steps))
        return stack
    def prove(self):return planner.tool_storage_graph(self.run,self.main,self.api,self.now,self.jobs)
    def test_fresh_four_and_all_eight_backend_steps_are_shared_main_release_proof(self):
        with self.mocks():
            got=self.prove();self.assertEqual(got["native_evidence"]["sha"],self.sha)
            self.assertEqual(len(got["native_evidence"]["job_ids"]),4)
            self.assertEqual(got["backend_evidence"]["preservation-service.yml"]["required_steps"],list(planner.TOOL_STORAGE_BACKEND_STEPS))
    def test_unknown_active_skipped_wrong_sha_duplicate_stale_and_reused_sources_fail(self):
        with self.mocks():
            for field,value in (("head_branch","codex/other"),("status","in_progress"),("conclusion","failure"),("run_attempt",2),
                    ("updated_at",(self.now-dt.timedelta(hours=25)).isoformat())):
                with patch.dict(self.run,{field:value}),self.assertRaises(ValueError):self.prove()
            for j in [job for job in self.jobs if job["name"] in set(self.required)|{planner.PLAN_JOB}]:
                for field,value in (("status","in_progress"),("conclusion","skipped"),("head_sha","c"*40)):
                    with patch.dict(j,{field:value}),self.assertRaises(ValueError):self.prove()
                with patch.dict(j["steps"][0],{"conclusion":"skipped"}),self.assertRaises(ValueError):self.prove()
            self.jobs.append(copy.deepcopy(self.jobs[0]))
            with self.assertRaises(ValueError):self.prove()
            self.jobs.pop()
            for field,value in (("required_backend_runs",[]),("evidence_run_id",99),("test_correction_evidence",{})):
                with patch.dict(self.plan,{field:value}),self.assertRaises(ValueError):self.prove()
            for name in ("tool_storage_inputs","tool_storage_readiness","equivalent_inputs"):
                with patch.object(planner,name,return_value=False),self.assertRaises(ValueError):self.prove()
    def test_backend_all_eight_steps_and_owning_attempt_are_mandatory(self):
        with self.mocks():
            for step in self.backend_jobs[0]["steps"]:
                with patch.dict(step,{"conclusion":"skipped"}),self.assertRaises(ValueError):self.prove()
            for field,value in (("status","in_progress"),("head_sha","c"*40),("head_branch","codex/other"),("run_attempt",2)):
                with patch.dict(self.backend,{field:value}),self.assertRaises(ValueError):self.prove()
    def test_raw_nine_ui_cases_reject_empty_skip_missing_duplicate_and_unexpected(self):
        good=self.api("/jobs/103/logs")
        self.assertTrue(planner.tool_storage_ui_results(good))
        for bad in ("",good.replace("passed","skipped",1),good.split("\n",2)[2],good+"\n"+good,
                good+"\nTest Case '-[NekoWidgetUITests.OtherTests testUnexpected]' started"):
            self.assertFalse(planner.tool_storage_ui_results(bad))
            def api(path):return bad if path.endswith("/jobs/103/logs") else self.api(path)
            with self.mocks(),self.assertRaises(ValueError):planner.tool_storage_graph(self.run,self.main,api,self.now,self.jobs)
    def test_only_known_empty_skipped_native_placeholders_can_be_extra(self):
        extra=self.jobs[-1]
        extra.update(name="Unexpected job",status="in_progress",conclusion=None,steps=[])
        with self.mocks():
            for status,conclusion in (("in_progress",None),("completed","failure"),("completed","success"),("completed","skipped")):
                extra.update(status=status,conclusion=conclusion)
                with self.assertRaises(ValueError):self.prove()
            extra.update(name=planner.UNEXPANDED_SHARING_JOB,status="completed",conclusion="skipped")
            self.assertTrue(self.prove())
            extra["steps"]=[{"name":"Unknown step","status":"completed","conclusion":"success"}]
            with self.assertRaises(ValueError):self.prove()
            extra["steps"]=[];extra["status"]="in_progress"
            with self.assertRaises(ValueError):self.prove()
            extra["status"]="completed"
            self.jobs.pop()
            with self.assertRaises(ValueError):self.prove()
            self.jobs.extend([dict(extra,id=999),dict(extra,id=1000)])
            with self.assertRaises(ValueError):self.prove()
    def test_backend_job_set_rejects_every_extra_execution(self):
        extra=dict(self.backend_jobs[0],id=999,name="Unexpected job",status="in_progress",conclusion=None,steps=[])
        self.backend_jobs.append(extra)
        with self.mocks():
            for status,conclusion in (("in_progress",None),("completed","failure"),("completed","success"),("completed","skipped")):
                extra.update(status=status,conclusion=conclusion)
                with self.assertRaises(ValueError):self.prove()



class ToolStorageFixedPRProofTests(unittest.TestCase):
    def setUp(self):
        self.p=planner;self.now=dt.datetime(2026,10,15,0,tzinfo=dt.timezone.utc);repo={"full_name":"soso-so-27/neko-widget","id":1335079243}
        self.run={"id":planner.TOOL_STORAGE_PR_RUN,"head_sha":planner.TOOL_STORAGE_PR_SOURCE,"head_branch":planner.TOOL_STORAGE_BRANCH,
            "event":"pull_request","workflow_id":363932714,"path":planner.PRESERVATION_WORKFLOW,"status":"completed","conclusion":"success",
            "run_number":237,"run_attempt":1,"updated_at":self.now.isoformat(),"repository":repo,"head_repository":repo,
            "head_commit":{"id":planner.TOOL_STORAGE_PR_SOURCE,"tree_id":planner.TOOL_STORAGE_PR_TREE},
            "pull_requests":[{"id":planner.TOOL_STORAGE_PR_ID,"number":311,
                "head":{"ref":planner.TOOL_STORAGE_BRANCH,"repo":{"id":1335079243}},"base":{"ref":"main","repo":{"id":1335079243}}}]}
        self.job={"id":planner.TOOL_STORAGE_PR_JOB,"run_id":planner.TOOL_STORAGE_PR_RUN,"head_sha":planner.TOOL_STORAGE_PR_SOURCE,
            "run_attempt":1,"name":planner.PRESERVATION_JOB,"status":"completed","conclusion":"success","completed_at":self.now.isoformat(),
            "steps":[{"name":n,"status":"completed","conclusion":"success"} for n in planner.TOOL_STORAGE_BACKEND_STEPS]}
        self.jobs=[self.job];self.push={"total_count":0,"workflow_runs":[]};self.after_push=None
        self.index={"total_count":1,"workflow_runs":[self.run]};self.push_reads=0
        self.raw=(f"+{planner.TOOL_STORAGE_PR_CHECKOUT}:refs/remotes/pull/311/merge\n"
            f"HEAD is now at {planner.TOOL_STORAGE_PR_CHECKOUT[:7]} Merge {planner.TOOL_STORAGE_PR_SOURCE} into {planner.TOOL_STORAGE_PR_BASE}\n")
        self.commits={planner.TOOL_STORAGE_PR_CHECKOUT:{"sha":planner.TOOL_STORAGE_PR_CHECKOUT,"tree":{"sha":planner.TOOL_STORAGE_PR_TREE},
            "parents":[{"sha":planner.TOOL_STORAGE_PR_BASE},{"sha":planner.TOOL_STORAGE_PR_SOURCE}]},
            planner.TOOL_STORAGE_PR_SOURCE:{"sha":planner.TOOL_STORAGE_PR_SOURCE,"tree":{"sha":planner.TOOL_STORAGE_PR_TREE},
            "parents":[{"sha":"0d11066368acdfae9fdd2678ea53e35177be5eec"},{"sha":planner.TOOL_STORAGE_PR_BASE}]}}
        binding=patch.object(planner,"TOOL_STORAGE_PR_LOG_SHA256",planner.tool_log_digest(self.raw));binding.start();self.addCleanup(binding.stop)
    def api(self,path):
        if path.endswith("/workflows/preservation-service.yml"):return {"id":363932714,"path":planner.PRESERVATION_WORKFLOW,"state":"active"}
        if "/workflows/preservation-service.yml/runs?" in path:
            if "event=push" in path:
                self.push_reads+=1
                return self.after_push if self.push_reads%2==0 and self.after_push is not None else self.push
            return self.index
        if path.endswith(f"/runs/{planner.TOOL_STORAGE_PR_RUN}"):return self.run
        if "/jobs?" in path:return {"total_count":len(self.jobs),"jobs":self.jobs}
        if path.endswith("/logs"):return self.raw
        raise AssertionError(path)
    def prove(self):
        self.push_reads=0
        with patch.object(planner,"tool_storage_pr_git_observation",side_effect=lambda path:self.commits[path.rsplit('/',1)[1]]):
            return planner.tool_storage_pr_backend_proof("soso-so-27/neko-widget",self.api,self.now)
    def test_exact_pr_proof_preserves_actual_event_and_absent_push(self):
        proof=self.prove();self.assertEqual(proof["event"],"pull_request");self.assertFalse(proof["push_evidence"])
        self.assertEqual(proof["checkout_sha"],planner.TOOL_STORAGE_PR_CHECKOUT);self.assertEqual(len(proof["required_steps"]),8)
        self.assertEqual(self.push_reads,2)
        self.run["pull_requests"]=[];self.assertEqual(self.prove()["pr_id"],planner.TOOL_STORAGE_PR_ID)
    def test_foreign_pr_sha_identity_active_failed_attempt_and_stale_reject(self):
        for field,value in (("id",1),("head_sha","a"*40),("head_branch","codex/other"),("event","push"),
                ("status","in_progress"),("conclusion","failure"),("run_attempt",2),
                ("updated_at",(self.now-dt.timedelta(hours=25)).isoformat())):
            with patch.dict(self.run,{field:value}),self.assertRaises(ValueError):self.prove()
        for field,value in (("number",312),("id",1)):
            with patch.dict(self.run["pull_requests"][0],{field:value}),self.assertRaises(ValueError):self.prove()
        with patch.dict(self.run["head_commit"],{"tree_id":"a"*40}),self.assertRaises(ValueError):self.prove()
        with patch.dict(self.run["head_repository"],{"id":1}),self.assertRaises(ValueError):self.prove()
        with self.assertRaises(ValueError):planner.tool_storage_pr_backend_proof("other/repo",self.api,self.now)
    def test_any_push_even_active_failed_or_late_cannot_be_replaced(self):
        for status,conclusion in (("in_progress",None),("completed","failure"),("completed","success")):
            present={"total_count":1,"workflow_runs":[dict(self.run,event="push",status=status,conclusion=conclusion)]}
            self.push=present
            with self.assertRaises(ValueError):self.prove()
            self.push={"total_count":0,"workflow_runs":[]};self.after_push=present
            with self.assertRaises(ValueError):self.prove()
            self.after_push=None
        for bad in ({"workflow_runs":[]},{"total_count":False,"workflow_runs":[]},{"total_count":1,"workflow_runs":[]}):
            self.push=bad
            with self.assertRaises(ValueError):self.prove()
    def test_all_eight_steps_exact_single_job_and_attempt_required(self):
        for step in self.job["steps"]:
            with patch.dict(step,{"conclusion":"skipped"}),self.assertRaises(ValueError):self.prove()
        for field,value in (("id",1),("head_sha","a"*40),("run_id",1),("run_attempt",2),("status","in_progress")):
            with patch.dict(self.job,{field:value}),self.assertRaises(ValueError):self.prove()
        self.jobs.append(dict(self.job,id=999,name="Unexpected job"))
        with self.assertRaises(ValueError):self.prove()
        self.jobs.pop();self.job["steps"].append(dict(self.job["steps"][0]))
        with self.assertRaises(ValueError):self.prove()
    def test_checkout_parent_tree_raw_digest_and_transcript_required(self):
        for commit in self.commits.values():
            with patch.dict(commit["tree"],{"sha":"a"*40}),self.assertRaises(ValueError):self.prove()
            with patch.dict(commit,{"parents":list(reversed(commit["parents"]))}),self.assertRaises(ValueError):self.prove()
            with patch.dict(commit,{"sha":"a"*40}),self.assertRaises(ValueError):self.prove()
        original=self.raw
        for bad in ("",original.replace("pull/311","pull/312"),original.replace("HEAD is now at","different checkout")):
            self.raw=bad
            with self.assertRaises(ValueError):self.prove()
        self.raw=original
        with patch.object(planner,"TOOL_STORAGE_PR_LOG_SHA256","0"*64),self.assertRaises(ValueError):self.prove()
        with self.assertRaises(ValueError):planner.tool_storage_pr_git_observation("repos/other/git/commits/"+planner.TOOL_STORAGE_PR_SOURCE)
    def test_pr_index_and_detail_must_be_unique_and_consistent(self):
        for bad in ({"total_count":0,"workflow_runs":[]},{"total_count":2,"workflow_runs":[self.run,self.run]},
                {"total_count":1,"workflow_runs":[dict(self.run,status="in_progress")]}, {"workflow_runs":[self.run]}):
            self.index=bad
            with self.assertRaises(ValueError):self.prove()


class ToolStoragePRControlInputTests(unittest.TestCase):
    def setUp(self):
        self.source=planner.TOOL_STORAGE_PR_SOURCE;self.head="a"*40;self.approved="b"*40
        self.before={p:f"100644 blob {blob}\t{p}" for p,blob in planner.TOOL_STORAGE_PR_CONTROL_BEFORE.items()}
        self.before |= {p:f"100644 blob {pair[1]}\t{p}" for p,pair in planner.TOOL_STORAGE_BLOBS.items()}
        self.before[planner.TOOL_STORAGE_READINESS_PATH]=f"100644 blob {planner.TOOL_STORAGE_READINESS_PAIR[1]}\t{planner.TOOL_STORAGE_READINESS_PATH}"
        self.before['NekoWidget/Shared/unchanged.swift']=f"100644 blob {'e'*40}\tNekoWidget/Shared/unchanged.swift"
        self.after=dict(self.before)
        for p in planner.TOOL_STORAGE_PR_CONTROL_PATHS:self.after[p]=f"100644 blob {'d'*40}\t{p}"
        self.raw="".join(f":100644 100644 {self.before[p].split()[2]} {self.after[p].split()[2]} M\0{p}\0" for p in planner.TOOL_STORAGE_PR_CONTROL_PATHS)
    def prove(self,override=None):
        def git(*args):
            if override and args in override:return override[args]
            if args[0]=="rev-parse":return self.head if args[1]=="HEAD" else planner.TOOL_STORAGE_PR_TREE
            if args[0]=="merge-base":return "" if "--is-ancestor" in args else self.approved
            if args[0]=="show":return f'TOOL_STORAGE_PR_SOURCE = "{self.source}"'
            if args[0]=="ls-tree":return self.after[args[-1]]
            if args[0]=="diff":return self.raw
            raise AssertionError(args)
        with patch.object(planner,"tool_storage_inputs",return_value=True),patch.object(planner,"git",side_effect=git), \
                patch.object(planner,"tool_storage_tree",side_effect=lambda ref:self.before if ref==self.source else self.after):
            return planner.tool_storage_pr_control_equivalent_inputs(self.source,self.head)
    def test_only_exact_two_approved_control_changes_are_equivalent(self):
        self.assertTrue(self.prove())
        for p in self.after:
            if p in planner.TOOL_STORAGE_PR_CONTROL_PATHS:continue
            original=self.after[p];self.after[p]=f"100644 blob {'c'*40}\t{p}"
            self.assertFalse(self.prove());self.after[p]=original
    def test_unapproved_mode_truncated_unknown_and_changed_artifact_reject(self):
        for p in planner.TOOL_STORAGE_CONTROLS:
            self.assertFalse(self.prove({("ls-tree",self.approved,"--",p):f"100644 blob {'c'*40}\t{p}"}))
        self.assertFalse(self.prove({("show",f"{self.approved}:NekoWidget/ci/plan-ios-ci.py"):""}))
        for bad in ("",self.raw+self.raw,self.raw.rsplit("\0",2)[0],self.raw.replace(":100644",":100755",1)):
            with patch.object(self,"raw",bad):self.assertFalse(self.prove())
        self.after["unknown.txt"]=f"100644 blob {'c'*40}\tunknown.txt";self.assertFalse(self.prove())
    def test_approved_control_exception_is_only_the_fixed_native_source(self):
        now=dt.datetime(2026,10,15,0,tzinfo=dt.timezone.utc);repo={"full_name":"soso-so-27/neko-widget"}
        run={"id":planner.TOOL_STORAGE_PR_NATIVE_RUN,"head_sha":self.source,"head_branch":planner.TOOL_STORAGE_BRANCH,
            "workflow_id":335014238,"path":".github/workflows/ios-build.yml","event":"push","run_attempt":1,
            "status":"completed","conclusion":"success","updated_at":now.isoformat(),"repository":repo,"head_repository":repo}
        current=dict(run,id=999,head_sha=self.head,head_branch="main")
        with patch.object(planner,"equivalent_inputs",return_value=False),patch.object(planner,"tool_storage_pr_control_equivalent_inputs",return_value=True):
            self.assertTrue(planner.reusable_run(run,current,repo['full_name'],now))
            for field,value in (("id",1),("head_sha","c"*40),("head_branch","codex/other"),("run_attempt",2),("status","in_progress")):
                with patch.dict(run,{field:value}):self.assertFalse(planner.reusable_run(run,current,repo['full_name'],now))


class ToolStorageFixedPRGraphTests(unittest.TestCase):
    def setUp(self):
        self.f=ToolStorageCompletionGraphTests();self.f.setUp();self.f.sha=planner.TOOL_STORAGE_PR_SOURCE
        self.f.run.update(id=planner.TOOL_STORAGE_PR_NATIVE_RUN,head_sha=self.f.sha)
        for job in self.f.jobs:job.update(head_sha=self.f.sha,run_id=self.f.run['id'])
        self.f.plan.update(head_sha=self.f.sha,required_backend_runs=planner.tool_storage_push_requirements(self.f.sha))
    def test_original_push_declaration_stays_historical_and_native_success_is_separate(self):
        f=self.f
        proof={"kind":planner.TOOL_STORAGE_PR_KIND,"event":"pull_request","push_evidence":False}
        with f.mocks(),patch.object(planner,"tool_storage_pr_backend_proof",return_value=proof) as backend:
            got=f.prove();self.assertEqual(got['source_required_backend_runs'],planner.tool_storage_push_requirements(f.sha))
            self.assertEqual(got['backend_substitution']['event'],'pull_request');self.assertFalse(got['backend_substitution']['push_evidence'])
            self.assertEqual(planner.tool_storage_requirements(f.sha)[0]['event'],'pull_request')
            with patch.dict(f.run,{'status':'in_progress'}),self.assertRaises(ValueError):f.prove()
            f.plan['required_backend_runs']=planner.tool_storage_requirements(f.sha)
            with self.assertRaises(ValueError):f.prove()


class ToolStoragePhotosAttempt2Tests(unittest.TestCase):
    def setUp(self):
        self.f = ToolStorageCompletionGraphTests(); self.f.setUp()
        f = self.f; f.sha = planner.TOOL_STORAGE_PR_SOURCE
        f.run.update(id=planner.TOOL_STORAGE_PR_NATIVE_RUN, head_sha=f.sha, run_attempt=2,
            created_at=planner.TOOL_STORAGE_PHOTOS_SOURCE_CREATED_AT)
        roles = ("build", "photos", "runtime", "app-ui", "plan")
        for job, role in zip(f.jobs[:5], roles):
            job.update(id=planner.TOOL_STORAGE_PHOTOS_SOURCE_JOBS[role], head_sha=f.sha,
                run_id=f.run["id"], completed_at="2026-10-14T23:50:56Z")
        for job, identifier in zip(f.jobs[5:], sorted(planner.TOOL_STORAGE_PHOTOS_SOURCE_PLACEHOLDERS)):
            job.update(id=identifier, head_sha=f.sha, run_id=f.run["id"])
        self.history = copy.deepcopy(f.jobs)
        failed = next(job for job in self.history if job["name"] == planner.BOOTSTRAP_SMOKE)
        failed["conclusion"] = "failure"
        for step, number in zip(failed["steps"], (2, 3, 4)): step["number"] = number
        failed["steps"][1]["conclusion"] = "failure"
        self.retry_id = 991
        fresh = copy.deepcopy(next(job for job in f.jobs if job["name"] == planner.BOOTSTRAP_SMOKE))
        fresh.update(id=self.retry_id, run_attempt=2, completed_at=f.now.isoformat())
        self.history.append(fresh)
        f.plan.update(head_sha=f.sha, required_backend_runs=planner.tool_storage_push_requirements(f.sha))
        self.plan_log = "IOS_CI_PLAN_JSON=" + json.dumps(f.plan)
        self.ui_log = "\n".join(f"Test Case '-[NekoWidgetUITests.{test.removeprefix('NekoWidgetUITests/').replace('/', ' ')}]' {status}"
            for test in scope.native_tests(planner.TOOL_STORAGE_SCOPE) for status in ("started", "passed"))
        self.failed_log = "retained exact permission query timeout\n"
        self.photos_log = "\n".join(f"Test Case '-[NekoWidgetUITests.PhotoPermissionUITests {case}]' {status}"
            for case in ("testGrantFullPhotoLibraryAccess", "testMainlineAcceptanceScreensWithAuthorizedLibrary") for status in ("started", "passed"))
        self.photos_log += "\nSimulator smoke test passed at 2026-10-15T01:00:00Z\n"
        self.diag_log = "\n".join(f"Test Case '-[NekoWidgetUITests.PhotoPermissionUITests testGrantFullPhotoLibraryAccess]' {status}"
            for status in ("started", "passed"))
        self.diag = {"run_id": 881, "job_id": 882, "source_sha": f.sha, "branch": "diagnostic/photos-example",
            "workflow_id": 883, "path": ".github/workflows/ios-ui-diagnostic.yml",
            "raw_log_sha256": planner.tool_log_digest(self.diag_log)}
        self.diag_run = dict(f.run, id=881, head_branch=self.diag["branch"], event="workflow_dispatch",
            workflow_id=883, path=self.diag["path"], run_attempt=1)
        self.diag_job = {"id": 882, "run_id": 881, "head_sha": f.sha, "run_attempt": 1,
            "status": "completed", "conclusion": "success"}
        self.original = dict(f.run, run_attempt=1, conclusion="failure", updated_at=planner.TOOL_STORAGE_PHOTOS_SOURCE_FINISHED_AT)
        for name, value in (("TOOL_STORAGE_PHOTOS_RETRY_JOB", self.retry_id), ("TOOL_STORAGE_PHOTOS_DIAGNOSTIC", self.diag),
                ("TOOL_STORAGE_PHOTOS_FAILURE_SHA256", planner.tool_log_digest(self.failed_log)),
                ("TOOL_STORAGE_PHOTOS_SOURCE_PLAN_SHA256", planner.tool_log_digest(self.plan_log)),
                ("TOOL_STORAGE_PHOTOS_SOURCE_UI_SHA256", planner.tool_log_digest(self.ui_log))):
            binding = patch.object(planner, name, value); binding.start(); self.addCleanup(binding.stop)
    def api(self, path):
        f = self.f
        if path.endswith("/attempts/1"): return self.original
        if path.endswith("/jobs?filter=all&per_page=100&page=1"): return {"total_count": len(self.history), "jobs": self.history}
        if path.endswith("/runs/881"): return self.diag_run
        if path.endswith("/runs/881/jobs?filter=latest&per_page=100&page=1"):
            return {"total_count": 1, "jobs": [self.diag_job]}
        logs = {planner.TOOL_STORAGE_PHOTOS_SOURCE_JOBS['plan']: self.plan_log,
            planner.TOOL_STORAGE_PHOTOS_SOURCE_JOBS['app-ui']: self.ui_log,
            planner.TOOL_STORAGE_PHOTOS_SOURCE_JOBS['photos']: self.failed_log,
            self.retry_id: self.photos_log, 882: self.diag_log}
        if path.endswith("/logs"): return logs[int(path.split('/')[-2])]
        raise AssertionError(path)
    def prove(self):
        f = self.f
        jobs = planner.executed_jobs(f.run, f.repo, self.api)
        with f.mocks(), patch.object(planner, "tool_storage_pr_backend_proof", return_value={"event": "pull_request", "push_evidence": False}):
            return planner.tool_storage_graph(f.run, f.main, self.api, f.now, jobs)
    def test_exact_retry_retains_actual_attempts_and_original_failure(self):
        got = self.prove(); proof = got['photos_retry']
        self.assertEqual((proof['original_attempt'], proof['photos_attempt']), (1, 2))
        self.assertEqual(proof['failed_photos_job_id'], planner.TOOL_STORAGE_PHOTOS_SOURCE_JOBS['photos'])
        self.assertFalse(proof['diagnostic']['release_evidence'])
        self.assertEqual({job['run_attempt'] for job in got['native_evidence']['jobs']}, {1, 2})
        self.assertEqual(self.original['conclusion'], 'failure')
        self.assertEqual(next(job for job in self.history if job['id'] == proof['failed_photos_job_id'])['conclusion'], 'failure')
    def test_pending_pins_failed_current_or_other_run_never_qualifies(self):
        for name in ('TOOL_STORAGE_PHOTOS_RETRY_JOB', 'TOOL_STORAGE_PHOTOS_DIAGNOSTIC'):
            with patch.object(planner, name, None), self.assertRaises(ValueError): self.prove()
        for field, value in (('id', 999), ('head_sha', 'b'*40), ('run_attempt', 1), ('run_attempt', 3), ('status', 'in_progress'), ('conclusion', 'failure')):
            with patch.dict(self.f.run, {field: value}), self.assertRaises((ValueError, AssertionError)): self.prove()
    def test_missing_duplicate_changed_original_or_unexpected_attempt_rejects(self):
        for index in range(len(self.history)):
            with patch.object(self, 'history', self.history[:index] + self.history[index+1:]), self.assertRaises(ValueError): self.prove()
        for field, value in (('id', 1234), ('run_attempt', 2), ('status', 'in_progress'), ('conclusion', 'failure')):
            with patch.dict(self.history[0], {field: value}), self.assertRaises(ValueError): self.prove()
        with patch.object(self, 'history', self.history + [copy.deepcopy(self.history[0])]), self.assertRaises(ValueError): self.prove()
        with patch.dict(self.original, {'conclusion': 'success'}), self.assertRaises(ValueError): self.prove()
    def test_original_photos_step_remains_exact_completed_failure(self):
        failed = next(job for job in self.history if job['id'] == planner.TOOL_STORAGE_PHOTOS_SOURCE_JOBS['photos'])
        step = next(step for step in failed['steps'] if step['name'] == 'Run Simulator smoke test')
        for conclusion in ('skipped', 'cancelled', None):
            with patch.dict(step, {'conclusion':conclusion}), self.assertRaises(ValueError): self.prove()
        with patch.dict(step, {'status':'in_progress'}), self.assertRaises(ValueError): self.prove()
    def test_only_at_most_two_empty_skipped_downstream_can_be_new(self):
        original = copy.deepcopy(self.history)
        for count in (0, 1, 2):
            self.history = copy.deepcopy(original) + [dict(self.f.jobs[-1], id=1200+i, run_attempt=2) for i in range(count)]
            self.assertTrue(self.prove()['photos_retry'])
        self.history.append(dict(self.f.jobs[-1], id=1300, run_attempt=2))
        with self.assertRaises(ValueError): self.prove()
        self.history = copy.deepcopy(original) + [dict(self.f.jobs[-1], id=1200, run_attempt=2)]
        for field, value in (('name', 'unexpected'), ('conclusion', 'success'), ('steps', [{'name':'executed'}]), ('status', 'in_progress')):
            with patch.dict(self.history[-1], {field:value}), self.assertRaises(ValueError): self.prove()
    def test_fresh_photos_full_steps_and_terminal_completion_required(self):
        for step in self.history[-1]['steps']:
            with patch.dict(step, {'conclusion':'skipped'}), self.assertRaises(ValueError): self.prove()
        for bad in (self.photos_log.replace('passed', 'skipped', 1), self.photos_log.split('Simulator smoke test passed')[0],
                self.photos_log + '\n##[error]extra failure', self.photos_log + self.photos_log):
            with patch.object(self, 'photos_log', bad), self.assertRaises(ValueError): self.prove()
    def test_original_raw_plan_ui_and_failure_cannot_be_replaced(self):
        for attr in ('plan_log', 'ui_log', 'failed_log'):
            with patch.object(self, attr, getattr(self, attr)+'\nchanged'), self.assertRaises(ValueError): self.prove()
        with patch.dict(self.history[0]['steps'][0], {'conclusion':'failure'}), self.assertRaises(ValueError): self.prove()
    def test_diagnostic_is_fixed_permission_observation_not_release_substitute(self):
        for bad in ('', self.diag_log.replace('passed', 'failed'), self.diag_log+self.diag_log):
            with patch.object(self, 'diag_log', bad), self.assertRaises(ValueError): self.prove()
        with patch.dict(self.diag, {'job_id':999}), self.assertRaises(ValueError): self.prove()
        with patch.object(self, 'photos_log', self.diag_log), self.assertRaises(ValueError): self.prove()
        for field, value in (('status', 'in_progress'), ('conclusion', 'failure'), ('head_sha', 'b'*40), ('run_attempt', 2),
                ('updated_at', (self.f.now-dt.timedelta(hours=25)).isoformat())):
            with patch.dict(self.diag_run, {field:value}), self.assertRaises(ValueError): self.prove()
    def test_main_reuse_is_fixed_attempt2_only_and_generic_duplicate_guard_unchanged(self):
        f = self.f; current = dict(f.run, id=999, head_sha=f.main, head_branch='main', run_attempt=1)
        with patch.object(planner, 'equivalent_inputs', return_value=False), \
                patch.object(planner, 'tool_storage_pr_control_equivalent_inputs', return_value=True):
            self.assertTrue(planner.reusable_run(f.run, current, f.repo, f.now))
            with patch.object(planner, 'TOOL_STORAGE_PHOTOS_DIAGNOSTIC', None):
                self.assertFalse(planner.reusable_run(f.run, current, f.repo, f.now))
            with patch.dict(f.run, {'run_attempt':3}):
                self.assertFalse(planner.reusable_run(f.run, current, f.repo, f.now))
        other = {'id':42, 'head_sha':'a'*40, 'run_attempt':2}
        duplicate = [dict(self.f.jobs[-1], id=43+i, run_id=42, head_sha='a'*40) for i in range(2)]
        with self.assertRaises(ValueError):
            planner.executed_jobs(other, f.repo, lambda path: {'total_count':2, 'jobs':duplicate})


class ToolStorageFreshBranchTests(unittest.TestCase):
    def setUp(self):
        self.f=ToolStorageCompletionGraphTests();self.f.setUp()
        self.f.run['head_branch']=planner.TOOL_STORAGE_FRESH_BRANCH
        self.f.backend['head_branch']=planner.TOOL_STORAGE_FRESH_BRANCH
    def test_only_normal_fresh_four_and_same_sha_eight_step_push_graph(self):
        with self.f.mocks():
            got=self.f.prove()
            self.assertEqual(len(got['native_evidence']['job_ids']),4)
            self.assertEqual(got['native_evidence']['sha'],self.f.sha)
            self.assertEqual(got['backend_evidence']['preservation-service.yml']['required_steps'],list(planner.TOOL_STORAGE_BACKEND_STEPS))
            self.assertNotIn('backend_substitution',got);self.assertNotIn('photos_retry',got)
    def test_fixed_original_source_cannot_move_to_the_fresh_branch(self):
        self.f.run['head_sha']=planner.TOOL_STORAGE_PR_SOURCE
        with self.f.mocks(),self.assertRaises(ValueError):self.f.prove()
        original={'id':planner.TOOL_STORAGE_PR_NATIVE_RUN,'head_sha':planner.TOOL_STORAGE_PR_SOURCE,
            'head_branch':planner.TOOL_STORAGE_FRESH_BRANCH,'event':'push','workflow_id':335014238,
            'path':'.github/workflows/ios-build.yml','run_attempt':2,'status':'completed','conclusion':'success'}
        self.assertFalse(planner.tool_storage_photos_retry_candidate(original))
    def test_exact_branch_backend_branch_inputs_readiness_and_all_jobs_required(self):
        with self.f.mocks():
            for branch in ('codex/other',planner.TOOL_STORAGE_FRESH_BRANCH+'-other','main'):
                with patch.dict(self.f.run,{'head_branch':branch}),self.assertRaises(ValueError):self.f.prove()
            with patch.dict(self.f.backend,{'head_branch':planner.TOOL_STORAGE_BRANCH}),self.assertRaises(ValueError):self.f.prove()
            for helper in ('tool_storage_inputs','tool_storage_readiness'):
                with patch.object(planner,helper,return_value=False),self.assertRaises(ValueError):self.f.prove()
            for job in self.f.jobs[:4]:
                with patch.dict(job,{'conclusion':'skipped'}),self.assertRaises(ValueError):self.f.prove()
            for step in self.f.backend_jobs[0]['steps']:
                with patch.dict(step,{'conclusion':'skipped'}),self.assertRaises(ValueError):self.f.prove()
    def test_dispatch_foreign_backend_sha_or_attempt_cannot_replace_owning_push(self):
        with self.f.mocks():
            for field,value in (('event','workflow_dispatch'),('event','pull_request'),('head_sha','c'*40),('run_attempt',2),('conclusion','failure')):
                with patch.dict(self.f.backend,{field:value}),self.assertRaises(ValueError):self.f.prove()


class ToolStorageStandalonePhotosTests(unittest.TestCase):
    def setUp(self):
        self.f=ToolStorageCompletionGraphTests();self.f.setUp();f=self.f
        f.now=dt.datetime(2026,10,15,3,30,tzinfo=dt.timezone.utc);f.sha=planner.TOOL_STORAGE_FRESH_PHOTOS_SOURCE
        f.run.update(id=planner.TOOL_STORAGE_FRESH_PHOTOS_RUN,head_sha=f.sha,head_branch=planner.TOOL_STORAGE_FRESH_BRANCH,
            status='queued',conclusion=None,created_at=planner.TOOL_STORAGE_FRESH_PHOTOS_SOURCE_CREATED_AT,
            updated_at=planner.TOOL_STORAGE_FORMAL_QUEUED_AT,run_started_at=planner.TOOL_STORAGE_FORMAL_QUEUED_AT)
        f.run.update(copy.deepcopy(planner.TOOL_STORAGE_FORMAL_QUEUED))
        roles={'plan':planner.PLAN_JOB,'build':planner.BUILD,'photos':planner.BOOTSTRAP_SMOKE,
            'runtime':planner.lane_job(planner.TOOL_STORAGE_SCOPE,'runtime'),'app-ui':planner.lane_job(planner.TOOL_STORAGE_SCOPE,'app-ui')}
        for role,identifier in planner.TOOL_STORAGE_FRESH_PHOTOS_SOURCE_JOBS.items():
            job=next(job for job in f.jobs if job['name']==roles[role])
            job.update(id=identifier,run_id=f.run['id'],head_sha=f.sha,completed_at='2026-10-15T02:27:22Z')
            for i,step in enumerate(job['steps'],1):step['number']=i+1
            if role=='photos':
                job['conclusion']='failure';job['steps'][1]['conclusion']='failure';job['steps'][1]['number']=3
        for job,identifier in zip(f.jobs[-2:],sorted(planner.TOOL_STORAGE_FRESH_PHOTOS_SOURCE_PLACEHOLDERS)):
            job.update(id=identifier,run_id=f.run['id'],head_sha=f.sha,completed_at='2026-10-15T02:27:22Z')
        self.original=copy.deepcopy(planner.TOOL_STORAGE_FORMAL_ORIGINAL)
        f.plan.update(head_sha=f.sha,required_backend_runs=planner.tool_storage_push_requirements(f.sha))
        self.plan_log='IOS_CI_PLAN_JSON='+json.dumps(f.plan)
        self.ui_log='\n'.join(f"Test Case '-[NekoWidgetUITests.{test.removeprefix('NekoWidgetUITests/').replace('/', ' ')}]' {status}"
            for test in scope.native_tests(planner.TOOL_STORAGE_SCOPE) for status in ('started','passed'))
        self.fail_log='original failed exact photo log'
        self.photos_log='\n'.join(f"Test Case '-[NekoWidgetUITests.PhotoPermissionUITests {case}]' {status}"
            for case in ('testGrantFullPhotoLibraryAccess','testMainlineAcceptanceScreensWithAuthorizedLibrary') for status in ('started','passed'))+'\nSimulator smoke test passed at 2026-10-15T03:30:00Z'
        self.artifacts={path:'c'*40 for path in planner.TOOL_STORAGE_FORMAL_ADDITIONS}
        self.controller=dict(f.run,id=900,head_sha='d'*40,head_branch='main',event='workflow_dispatch',
            workflow_id=planner.TOOL_STORAGE_FORMAL_FIRST_FAILURE['workflow_id'],path=planner.TOOL_STORAGE_FORMAL_WORKFLOW,status='completed',conclusion='success',updated_at=f.now.isoformat())
        self.external=[]
        for identifier,name,names in ((902,'Verify fixed Photos source and original history',planner.TOOL_STORAGE_FORMAL_PRECHECK_STEPS),
                (903,'Formal full Photos validation for frozen tool source',planner.TOOL_STORAGE_FORMAL_PHOTOS_STEPS)):
            self.external.append({'id':identifier,'name':name,'run_id':900,'head_sha':'d'*40,'run_attempt':1,
                'status':'completed','conclusion':'success','completed_at':f.now.isoformat(),
                'steps':[{'name':n,'status':'completed','conclusion':'success'} for n in names]})
        self.pins={'controller_sha':'d'*40,'branch':'main','workflow_id':planner.TOOL_STORAGE_FORMAL_FIRST_FAILURE['workflow_id'],'run_id':900,'precheck_job_id':902,'photos_job_id':903,
            'precheck_raw_log_sha256':'0'*64,'photos_raw_log_sha256':'0'*64,
            'precheck_steps_sha256':planner.tool_storage_formal_digest(self.external[0]['steps']),
            'photos_steps_sha256':planner.tool_storage_formal_digest(self.external[1]['steps']),
            'precheck_observations_sha256':'a'*64,'photos_observations_sha256':'b'*64}
        self.first_run=copy.deepcopy(planner.TOOL_STORAGE_FORMAL_FIRST_FAILURE)
        self.first_raw='exact observed pre-native preparation failure'
        self.first_jobs=[{'id':116230623798,'name':'Verify fixed Photos source and original history',
            'run_id':self.first_run['id'],'head_sha':self.first_run['head_sha'],'run_attempt':1,'status':'completed','conclusion':'failure',
            'steps':[{'name':'Verify fixed source and original history','number':4,'status':'completed','conclusion':'failure'}]},
            {'id':116230680503,'name':'Formal full Photos validation for frozen tool source','run_id':self.first_run['id'],
            'head_sha':self.first_run['head_sha'],'run_attempt':1,'status':'completed','conclusion':'skipped','steps':[]}]
        self.first_payload={'total_count':2,'jobs':self.first_jobs}
        self.after_controller_index_extra=None;self.controller_index_reads=0
        for name,value in (('TOOL_STORAGE_FORMAL_ARTIFACTS',self.artifacts),('TOOL_STORAGE_FORMAL_OBSERVED',self.pins),
                ('TOOL_STORAGE_FORMAL_ORIGINAL_JOBS_SHA256',planner.tool_storage_formal_digest(f.jobs)),
                ('TOOL_STORAGE_FORMAL_FIRST_FAILURE_JOBS_SHA256',planner.tool_storage_formal_digest(self.first_jobs)),
                ('TOOL_STORAGE_FORMAL_FIRST_FAILURE_PAYLOAD_SHA256',planner.tool_storage_formal_digest(self.first_payload)),
                ('TOOL_STORAGE_FORMAL_FIRST_FAILURE_RAW_SHA256',planner.tool_log_digest(self.first_raw)),
                ('TOOL_STORAGE_FRESH_PHOTOS_SOURCE_PLAN_SHA256',planner.tool_log_digest(self.plan_log)),
                ('TOOL_STORAGE_FRESH_PHOTOS_SOURCE_UI_SHA256',planner.tool_log_digest(self.ui_log)),
                ('TOOL_STORAGE_FRESH_PHOTOS_FAILURE_SHA256',planner.tool_log_digest(self.fail_log))):
            binding=patch.object(planner,name,value);binding.start();self.addCleanup(binding.stop)
        self.precheck_log='FORMAL_PHOTOS_SOURCE_JSON='+json.dumps(self.manifest('precheck'))
        self.photos_log='FORMAL_PHOTOS_SOURCE_JSON='+json.dumps(self.manifest('pre-native'))+'\n'+self.photos_log
        self.pins['precheck_raw_log_sha256']=planner.tool_log_digest(self.precheck_log)
        self.pins['photos_raw_log_sha256']=planner.tool_log_digest(self.photos_log)
        f.backend.update(id=planner.TOOL_STORAGE_FRESH_PHOTOS_BACKEND_RUN,head_sha=f.sha,head_branch=planner.TOOL_STORAGE_FRESH_BRANCH,
            status='completed',conclusion='success',updated_at=f.now.isoformat())
        f.backend_jobs[0].update(id=planner.TOOL_STORAGE_FRESH_PHOTOS_BACKEND_JOB,run_id=f.backend['id'],head_sha=f.sha,completed_at=f.now.isoformat())
        self.alljobs=f.jobs;self.after_alljobs=None;self.history_reads=0
        self.controller_index_extra=None;self.backend_index_extra=None
    def manifest(self,phase):
        f=self.f
        return {'schema_version':1,'kind':'tool-storage-formal-photos-source-precheck-v1','repository':f.repo,
            'controller_sha':'d'*40,'controller_ref':'refs/heads/main','controller_run_id':900,'controller_run_attempt':1,
            'phase':phase,'product_sha':f.sha,'product_tree':planner.TOOL_STORAGE_FRESH_PHOTOS_SOURCE_TREE,
            'product_parents':['052910e36722874685c6dc4295f01e50dfc40e19',planner.TOOL_STORAGE_PR_SOURCE],
            'harness_sha256':'11a1dac0485a951c4a55ffabc50f8d0f7225601210c7fc32601ea00f309c92d9',
            'original_run_id':f.run['id'],'original_run_attempt':1,'original_status':'queued','original_updated_at':planner.TOOL_STORAGE_FORMAL_QUEUED_AT,
            'original_attempt1_conclusion':'failure','original_attempt1_created_at':planner.TOOL_STORAGE_FRESH_PHOTOS_SOURCE_CREATED_AT,
            'original_attempt1_finished_at':planner.TOOL_STORAGE_FRESH_PHOTOS_SOURCE_FINISHED_AT,
            'original_job_ids':sorted(job['id'] for job in f.jobs),'original_jobs_sha256':planner.tool_storage_formal_digest(f.jobs),
            'original_attempt1_sha256':planner.TOOL_STORAGE_FORMAL_ATTEMPT1_SHA256,
             'first_controller_run_id':planner.TOOL_STORAGE_FORMAL_FIRST_FAILURE['id'],
            'first_controller_sha':planner.TOOL_STORAGE_FORMAL_FIRST_FAILURE['head_sha'],
            'first_controller_run_critical_sha256':planner.TOOL_STORAGE_FORMAL_FIRST_FAILURE_CRITICAL_SHA256,
            'first_controller_jobs_sha256':planner.TOOL_STORAGE_FORMAL_FIRST_FAILURE_JOBS_SHA256,
            'first_controller_failure_raw_sha256':planner.TOOL_STORAGE_FORMAL_FIRST_FAILURE_RAW_SHA256,
            'observations_sha256':self.pins[('precheck' if phase=='precheck' else 'photos')+'_observations_sha256'],
            'checked_at':f.now.isoformat()}
    def api(self,path):
        f=self.f
        if path.endswith('/runs/'+str(self.first_run['id'])):return self.first_run
        if '/runs/'+str(self.first_run['id'])+'/jobs?' in path:return self.first_payload
        if path.endswith('/jobs/116230623798/logs'):return self.first_raw
        if path.endswith('/runs/'+str(f.run['id'])):return f.run
        if path.endswith('/attempts/1'):return self.original
        if '/runs/'+str(f.run['id'])+'/jobs?' in path:
            self.history_reads+=1;rows=self.after_alljobs if self.history_reads>1 and self.after_alljobs is not None else self.alljobs
            return {'total_count':len(rows),'jobs':rows}
        if path.endswith('/workflows/tool-storage-photos-validation.yml'):
            return {'id':planner.TOOL_STORAGE_FORMAL_FIRST_FAILURE['workflow_id'],'path':planner.TOOL_STORAGE_FORMAL_WORKFLOW,'state':'active'}
        if '/workflows/tool-storage-photos-validation.yml/runs?' in path:
            self.controller_index_reads+=1
            rows=[self.first_run,self.controller]+([self.controller_index_extra] if self.controller_index_extra else [])
            if self.controller_index_reads>1 and self.after_controller_index_extra:rows.append(self.after_controller_index_extra)
            return {'total_count':len(rows),'workflow_runs':rows}
        if path.endswith('/runs/900'):return self.controller
        if '/runs/900/jobs?' in path:return {'total_count':len(self.external),'jobs':self.external}
        if path.endswith('/workflows/preservation-service.yml'):
            return {'id':363932714,'path':planner.PRESERVATION_WORKFLOW,'state':'active'}
        if '/workflows/preservation-service.yml/runs?' in path:
            rows=[f.backend]+([self.backend_index_extra] if self.backend_index_extra else [])
            return {'total_count':len(rows),'workflow_runs':rows}
        if path.endswith('/runs/'+str(f.backend['id'])):return f.backend
        if '/runs/'+str(f.backend['id'])+'/jobs?' in path:return {'total_count':len(f.backend_jobs),'jobs':f.backend_jobs}
        logs={planner.TOOL_STORAGE_FRESH_PHOTOS_SOURCE_JOBS['plan']:self.plan_log,
            planner.TOOL_STORAGE_FRESH_PHOTOS_SOURCE_JOBS['app-ui']:self.ui_log,
            planner.TOOL_STORAGE_FRESH_PHOTOS_SOURCE_JOBS['photos']:self.fail_log,902:self.precheck_log,903:self.photos_log}
        if path.endswith('/logs'):return logs[int(path.split('/')[-2])]
        raise AssertionError(path)
    def mocks(self):
        stack=self.f.mocks()
        stack.enter_context(patch.object(planner,'tool_storage_formal_equivalent_inputs',return_value=True))
        stack.enter_context(patch.object(planner,'tool_storage_signature',return_value=True))
        rows={path:f'100644 blob {blob}\t{path}' for path,blob in planner.TOOL_STORAGE_FRESH_PHOTOS_CONTROL_BEFORE.items()}
        rows.update({path:f'100644 blob {pair[0]}\t{path}' for path,pair in planner.TOOL_STORAGE_BLOBS.items() if pair[0]!='0'*40})
        stack.enter_context(patch.object(planner,'tool_storage_formal_tree',return_value=rows))
        def git(*args):return rows.get(args[-1],'') if args[0]=='ls-tree' else self.f.main
        stack.enter_context(patch.object(planner,'git',side_effect=git))
        return stack
    def prove(self):
        self.history_reads=0;self.controller_index_reads=0
        with self.mocks():
            jobs=planner.executed_jobs(self.f.run,self.f.repo,self.api)
            return planner.tool_storage_graph(self.f.run,self.f.main,self.api,self.f.now,jobs)
    def test_literal_standalone_preserves_failure_and_separate_actual_heads(self):
        got=self.prove();formal=got['formal_photos']
        self.assertEqual(got['native_evidence']['status'],'queued');self.assertIsNone(got['native_evidence']['conclusion'])
        self.assertEqual(formal['original_conclusion'],'failure');self.assertEqual(formal['controller']['event'],'workflow_dispatch')
        self.assertEqual(formal['first_controller_failure']['native_jobs_executed'],0);self.assertFalse(formal['first_controller_failure']['release_evidence'])
        self.assertEqual(formal['controller']['sha'],'d'*40);self.assertEqual(formal['compiled_source_sha'],self.f.sha)
        self.assertEqual(len(formal['history_job_ids']),7);self.assertNotIn('backend_substitution',got)
        self.assertEqual(got['backend_evidence']['preservation-service.yml']['event'],'push')
    def test_unobserved_pins_and_unknown_original_identity_never_qualify(self):
        for name in ('TOOL_STORAGE_FORMAL_ARTIFACTS','TOOL_STORAGE_FORMAL_OBSERVED'):
            with patch.object(planner,name,None),self.assertRaises(ValueError):self.prove()
        for field,value in (('id',99),('head_sha','e'*40),('head_branch',planner.TOOL_STORAGE_BRANCH),('event','workflow_dispatch'),
                ('run_attempt',2),('run_attempt',3),('status','in_progress'),('status','completed'),('conclusion','success')):
            with patch.dict(self.f.run,{field:value}),self.assertRaises((ValueError,AssertionError)):self.prove()
    def test_original_raw_build_failure_history_and_new_attempt_reject(self):
        for name in ('plan_log','ui_log','fail_log'):
            with patch.object(self,name,getattr(self,name)+'changed'),self.assertRaises(ValueError):self.prove()
        for job in self.f.jobs:
            with patch.dict(job,{'run_attempt':2}),self.assertRaises(ValueError):self.prove()
        with patch.object(self,'alljobs',self.alljobs+[dict(self.alljobs[0],id=888)]),self.assertRaises(ValueError):self.prove()
        self.after_alljobs=self.alljobs+[dict(self.alljobs[0],id=888)]
        with self.assertRaises(ValueError):self.prove()
    def test_external_controller_identity_unique_two_jobs_and_no_reruns(self):
        for field,value in (('id',99),('head_sha',self.f.sha),('head_branch','codex/unknown'),('event','push'),
                ('workflow_id',335014238),('run_attempt',2),('status','in_progress'),('conclusion','failure')):
            with patch.dict(self.controller,{field:value}),self.assertRaises((ValueError,AssertionError)):self.prove()
        self.controller_index_extra=dict(self.controller,id=999)
        with self.assertRaises(ValueError):self.prove()
        self.controller_index_extra=None
        extra=dict(self.external[0],id=888,status='in_progress',conclusion=None)
        self.external.append(extra)
        with self.assertRaises(ValueError):self.prove()
    def test_all_controller_steps_execute_and_unknown_extra_steps_reject(self):
        for job in self.external:
            for step in job['steps']:
                with patch.dict(step,{'conclusion':'skipped'}),self.assertRaises(ValueError):self.prove()
            job['steps'].append({'name':'Unknown','status':'completed','conclusion':'success'})
            with self.assertRaises(ValueError):self.prove()
            job['steps'].pop()
    def test_full_two_cases_terminal_and_source_manifest_required(self):
        for bad in ('',self.photos_log.replace('passed','skipped',1),self.photos_log.replace('Simulator smoke test passed',''),
                self.photos_log+'\n##[error]unknown',self.photos_log+'\n'+self.photos_log):
            with patch.object(self,'photos_log',bad),patch.dict(self.pins,{'photos_raw_log_sha256':planner.tool_log_digest(bad)}),self.assertRaises(ValueError):self.prove()
        for key,value in (('product_sha','e'*40),('product_tree','e'*40),('controller_sha',self.f.sha),('phase','precheck'),
                ('harness_sha256','e'*64),('original_attempt1_conclusion','success'),('observations_sha256','e'*64)):
            record=self.manifest('pre-native');record[key]=value
            raw='FORMAL_PHOTOS_SOURCE_JSON='+json.dumps(record)+'\n'+self.photos_log.split('\n',1)[1]
            with patch.object(self,'photos_log',raw),patch.dict(self.pins,{'photos_raw_log_sha256':planner.tool_log_digest(raw)}),self.assertRaises(ValueError):self.prove()
    def test_normal_backend_same_source_branch_push_all8_mandatory(self):
        for field,value in (('event','pull_request'),('head_sha','e'*40),('head_branch',planner.TOOL_STORAGE_BRANCH),('run_attempt',2),('conclusion','failure')):
            with patch.dict(self.f.backend,{field:value}),self.assertRaises(ValueError):self.prove()
        for step in self.f.backend_jobs[0]['steps']:
            with patch.dict(step,{'conclusion':'skipped'}),self.assertRaises(ValueError):self.prove()
        self.backend_index_extra=dict(self.f.backend,id=99)
        with self.assertRaises(ValueError):self.prove()
    def test_signature_closure_stale_and_source_only_default_graph_reject(self):
        with self.mocks():
            for name in ('tool_storage_signature','tool_storage_formal_equivalent_inputs'):
                with patch.object(planner,name,return_value=False),self.assertRaises(ValueError):
                    planner.tool_storage_graph(self.f.run,self.f.main,self.api,self.f.now,self.f.jobs)
            with self.assertRaises(ValueError):planner.tool_storage_graph(self.f.run,self.f.sha,self.api,self.f.now,self.f.jobs)
            with patch.dict(self.controller,{'updated_at':(self.f.now-dt.timedelta(hours=25)).isoformat()}),self.assertRaises(ValueError):self.prove()
    def test_premerge_observation_is_explicit_and_never_ordinary_graph(self):
        with self.mocks(),patch.object(planner,'tool_storage_formal_premerge_observation',return_value={
                'kind':'premerge-source-only','release_qualified':False}) as observe:
            got=planner.tool_storage_formal_photos_proof(self.f.repo,self.api,self.f.now,self.f.sha,premerge=True)
            self.assertFalse(got['validation_context']['release_qualified']);self.assertEqual(observe.call_count,1)
            with self.assertRaises(ValueError):planner.tool_storage_formal_photos_proof(self.f.repo,self.api,self.f.now,self.f.sha)
    def test_same_structural_candidate_for_main_and_direct_lookup(self):
        f=self.f;current=dict(f.run,id=999,head_sha=f.main,head_branch='main',status='in_progress')
        with self.mocks():
            self.assertTrue(planner.reusable_run(f.run,current,f.repo,f.now))
            with patch.object(planner,'TOOL_STORAGE_FORMAL_OBSERVED',None):self.assertFalse(planner.reusable_run(f.run,current,f.repo,f.now))
            env={'GITHUB_EVENT_NAME':'push','GITHUB_REF':'refs/heads/main','GITHUB_RUN_ID':'999','GITHUB_SHA':f.main,'GITHUB_REPOSITORY':f.repo}
            def api(path):return current if path.endswith('/runs/999') else self.api(path)
            self.assertEqual(planner.find_evidence(env,f.required,api,f.now),(f.run['id'],f.sha))
    def test_premerge_requires_controller_on_approved_main_without_controller_ancestor_of_fb5(self):
        f=self.f;calls=[]
        rows={path:f'100644 blob {blob}\t{path}' for path,blob in planner.TOOL_STORAGE_FRESH_PHOTOS_CONTROL_BEFORE.items()}
        def git(*args):
            calls.append(args)
            if args[0]=='ls-tree':return rows[args[-1]]
            if args==('rev-parse','HEAD'):return f.main
            if args==('merge-base','refs/remotes/origin/main',f.main):return f.main
            if args==('merge-base','--is-ancestor','d'*40,f.main):return ''
            if args==('merge-base','--is-ancestor','d'*40,f.sha):
                raise AssertionError('New controller cannot be ancestor of older fb5')
            raise AssertionError(args)
        with self.mocks(),patch.object(planner,'git',side_effect=git), \
                patch.object(planner,'tool_storage_formal_premerge_observation',return_value={'release_qualified':False}):
            got=planner.tool_storage_formal_photos_proof(f.repo,self.api,f.now,f.sha,premerge=True)
            self.assertFalse(got['validation_context']['release_qualified'])
        self.assertIn(('merge-base','--is-ancestor','d'*40,f.main),calls)
        self.assertNotIn(('merge-base','--is-ancestor','d'*40,f.sha),calls)
        def rejected_git(*args):
            if args==('merge-base','--is-ancestor','d'*40,f.main):
                raise subprocess.CalledProcessError(1,['git',*args])
            return git(*args)
        with self.mocks(),patch.object(planner,'git',side_effect=rejected_git),self.assertRaises(subprocess.CalledProcessError):
            planner.tool_storage_formal_photos_proof(f.repo,self.api,f.now,f.main)
    def test_first_failed_controller_cannot_be_replaced_retried_or_execute_mac(self):
        for field,value in (('id',99),('head_sha','e'*40),('run_attempt',2),('status','in_progress'),('conclusion','success')):
            with patch.dict(self.first_run,{field:value}),self.assertRaises((ValueError,AssertionError)):self.prove()
        with patch.object(self,'first_raw',self.first_raw+'changed'),self.assertRaises(ValueError):self.prove()
        for field,value in (('conclusion','success'),('steps',[{'name':'native executed'}]),('run_attempt',2)):
            with patch.dict(self.first_jobs[1],{field:value}),self.assertRaises(ValueError):self.prove()
        extra=dict(self.first_jobs[0],id=888,run_attempt=2)
        with patch.dict(self.first_payload,{'total_count':3,'jobs':self.first_jobs+[extra]}),self.assertRaises(ValueError):self.prove()
    def test_global_two_dispatch_index_catches_unknown_head_and_late_new_dispatch(self):
        self.after_controller_index_extra=dict(self.controller,id=999,head_sha='e'*40)
        with self.assertRaises(ValueError):self.prove()
        self.after_controller_index_extra=None
        with patch.dict(self.pins,{'run_id':planner.TOOL_STORAGE_FORMAL_FIRST_FAILURE['id']}),self.assertRaises(ValueError):self.prove()
    def test_source_manifest_requires_all_five_retained_first_failure_fields(self):
        for key in ('first_controller_run_id','first_controller_sha','first_controller_run_critical_sha256',
                'first_controller_jobs_sha256','first_controller_failure_raw_sha256'):
            record=self.manifest('pre-native');del record[key]
            raw='FORMAL_PHOTOS_SOURCE_JSON='+json.dumps(record)+'\n'+self.photos_log.split('\n',1)[1]
            with patch.object(self,'photos_log',raw),patch.dict(self.pins,{'photos_raw_log_sha256':planner.tool_log_digest(raw)}),self.assertRaises(ValueError):self.prove()


class ToolStorageStandaloneClosureTests(unittest.TestCase):
    def setUp(self):
        self.artifacts={path:'c'*40 for path in planner.TOOL_STORAGE_FORMAL_ADDITIONS}
        self.row=f"100644 blob {'d'*40}\timmutable.txt"
        self.rows='\0'.join([self.row]+[f'100644 blob {blob}\t{path}' for path,blob in self.artifacts.items()])+'\0'
    def test_only_exact_controller_additions_removed_from_old_closure(self):
        with patch.object(planner,'TOOL_STORAGE_FORMAL_ARTIFACTS',self.artifacts),patch.object(planner,'TOOL_STORAGE_CLOSURE_COUNT',1), \
                patch.object(planner,'TOOL_STORAGE_CLOSURE_SHA256',hashlib.sha256((self.row+'\0').encode()).hexdigest()), \
                patch.object(planner,'git',side_effect=lambda *args:self.rows):
            self.assertEqual(len(planner.tool_storage_formal_tree('a'*40)),4)
            for bad in (self.rows+f"100644 blob {'e'*40}\tunknown.txt\0",self.rows.replace('100644','100755',1),self.rows+self.row+'\0'):
                with patch.object(self,'rows',bad),self.assertRaises(ValueError):planner.tool_storage_formal_tree('a'*40)
            with patch.object(self,'rows',self.rows.replace('c'*40,'e'*40,1)),self.assertRaises(ValueError):planner.tool_storage_formal_tree('a'*40)
    def test_dedicated_plan_only_shape_is_exact_and_inactive_proof_remains_none(self):
        paths=list(planner.TOOL_STORAGE_FORMAL_CONTROLS | planner.TOOL_STORAGE_FORMAL_ADDITIONS)
        self.assertTrue(planner.tool_storage_formal_control_paths_only(paths))
        self.assertEqual(planner.required_jobs(paths,planner.ORCHESTRATION_SCOPE),(planner.PLAN_JOB,))
        for bad in (None,[],paths[:-1],paths+['unknown.txt'],paths+paths):self.assertFalse(planner.tool_storage_formal_control_paths_only(bad))
        with patch.object(planner,'TOOL_STORAGE_FORMAL_OBSERVED',None):
            self.assertFalse(planner.tool_storage_formal_configured())


class ToolStorageStandaloneControlRegistrationTests(unittest.TestCase):
    def setUp(self):
        self.base='a'*40;self.head='b'*40
        self.before={path:f'100644 blob {blob}\t{path}' for path,blob in planner.TOOL_STORAGE_FORMAL_CONTROL_BEFORE.items()}
        self.before.update({path:f'100644 blob {pair[0]}\t{path}' for path,pair in planner.TOOL_STORAGE_BLOBS.items() if pair[0]!='0'*40})
        self.before[planner.TOOL_STORAGE_READINESS_PATH]=f'100644 blob {planner.TOOL_STORAGE_READINESS_PAIR[1]}\t{planner.TOOL_STORAGE_READINESS_PATH}'
        self.before.update({path:f'100644 blob {blob}\t{path}' for path,blob in planner.TOOL_STORAGE_FORMAL_ARTIFACTS_BEFORE.items()})
        self.after=dict(self.before)
        for path in planner.TOOL_STORAGE_FORMAL_CONTROLS:self.after[path]=f"100644 blob {'d'*40}\t{path}"
        for path,blob in planner.TOOL_STORAGE_FORMAL_ARTIFACTS.items():self.after[path]=f'100644 blob {blob}\t{path}'
        self.paths=list(planner.TOOL_STORAGE_FORMAL_CONTROLS|planner.TOOL_STORAGE_FORMAL_ADDITIONS)
        self.raw=''.join(f":100644 100644 {self.before[path].split()[2]} {self.after[path].split()[2]} M\0{path}\0" for path in planner.TOOL_STORAGE_FORMAL_CONTROLS)
        self.raw+=''.join(f":100644 100644 {planner.TOOL_STORAGE_FORMAL_ARTIFACTS_BEFORE[path]} {blob} M\0{path}\0" for path,blob in planner.TOOL_STORAGE_FORMAL_ARTIFACTS.items())
    def prove(self):
        def git(*args):
            if args[0]=='ls-tree':return '\0'.join(self.before.values())+'\0'
            if args[0]=='diff':return self.raw
            raise AssertionError(args)
        with patch.object(planner,'git',side_effect=git),patch.object(planner,'tool_storage_formal_tree',return_value=self.after), \
                patch.object(planner,'tool_storage_signature',return_value=True):
            return planner.tool_storage_formal_control_only(self.paths,self.base,self.head)
    def test_only_exact_five_correction_modifications_are_plan_only(self):
        self.assertTrue(self.prove())
        with patch.object(planner,'comparison_base',return_value=self.base),patch.object(planner,'tool_storage_formal_control_only',return_value=True):
            self.assertEqual(planner.runtime_scope(self.paths,{}, {'GITHUB_SHA':self.head}),planner.ORCHESTRATION_SCOPE)
        for path in self.after:
            if path in planner.TOOL_STORAGE_FORMAL_CONTROLS|planner.TOOL_STORAGE_FORMAL_ADDITIONS:continue
            saved=self.after[path];self.after[path]=f"100644 blob {'e'*40}\t{path}"
            self.assertFalse(self.prove());self.after[path]=saved
    def test_unknown_modes_unfrozen_addition_truncation_and_signature_reject(self):
        for bad in (self.raw+self.raw,self.raw.replace(':100644',':100755',1),self.raw.replace('a79acffa41ec1a74b4b1ddb73f5707941c96609b','e'*40),self.raw[:-1]):
            with patch.object(self,'raw',bad):self.assertFalse(self.prove())
        with patch.object(planner,'TOOL_STORAGE_FORMAL_CONTROL_BEFORE',None):self.assertFalse(self.prove())
    def test_source_to_main_equivalence_preserves_all_other_products_and_controls(self):
        source=planner.TOOL_STORAGE_FRESH_PHOTOS_SOURCE;approved='c'*40
        before={p:row for p,row in self.before.items() if p not in planner.TOOL_STORAGE_FORMAL_ADDITIONS}
        before.update({p:f'100644 blob {blob}\t{p}' for p,blob in planner.TOOL_STORAGE_FRESH_PHOTOS_CONTROL_BEFORE.items()})
        before.update({path:f'100644 blob {pair[1]}\t{path}' for path,pair in planner.TOOL_STORAGE_BLOBS.items()})
        after=dict(self.after);after.update({path:f'100644 blob {pair[1]}\t{path}' for path,pair in planner.TOOL_STORAGE_BLOBS.items()})
        def prove():
            def git(*args):
                if args[0]=='rev-parse':return self.head if args[1]=='HEAD' else planner.TOOL_STORAGE_FRESH_PHOTOS_SOURCE_TREE
                if args[0]=='merge-base':return '' if '--is-ancestor' in args else approved
                if args[0]=='show':return 'TOOL_STORAGE_FORMAL_KIND = "tool-storage-fb5-standalone-formal-photos-v1"'
                if args[0]=='ls-tree':return after.get(args[-1],'')
                if args[0]=='diff':return ''.join(f":100644 100644 {before[p].split()[2]} {after[p].split()[2]} M\0{p}\0" for p in planner.TOOL_STORAGE_FORMAL_CONTROLS)+''.join(f":000000 100644 {'0'*40} {blob} A\0{p}\0" for p,blob in planner.TOOL_STORAGE_FORMAL_ARTIFACTS.items())
                raise AssertionError(args)
            with patch.object(planner,'git',side_effect=git),patch.object(planner,'tool_storage_inputs',return_value=True), \
                    patch.object(planner,'tool_storage_tree',return_value=before),patch.object(planner,'tool_storage_formal_tree',return_value=after):
                return planner.tool_storage_formal_equivalent_inputs(source,self.head)
        self.assertTrue(prove())
        for path in after:
            if path in planner.TOOL_STORAGE_FORMAL_CONTROLS|planner.TOOL_STORAGE_FORMAL_ADDITIONS:continue
            saved=after[path];after[path]=f"100644 blob {'e'*40}\t{path}"
            self.assertFalse(prove());after[path]=saved
    def test_old_controller_addition_or_wrong_before_blob_cannot_be_a_correction(self):
        for path in planner.TOOL_STORAGE_FORMAL_ADDITIONS:
            old=planner.TOOL_STORAGE_FORMAL_ARTIFACTS_BEFORE[path];new=planner.TOOL_STORAGE_FORMAL_ARTIFACTS[path]
            bad=self.raw.replace(f":100644 100644 {old} {new} M\0{path}\0",f":000000 100644 {'0'*40} {new} A\0{path}\0")
            with patch.object(self,'raw',bad):self.assertFalse(self.prove())
            with patch.object(self,'raw',self.raw.replace(old,'e'*40,1)):self.assertFalse(self.prove())
    def test_observed_pin_only_activation_keeps_three_corrected_artifacts_unchanged(self):
        for path,blob in planner.TOOL_STORAGE_FORMAL_ARTIFACTS.items():self.before[path]=f'100644 blob {blob}\t{path}'
        self.paths=list(planner.TOOL_STORAGE_FORMAL_CONTROLS)
        self.raw=''.join(f":100644 100644 {self.before[p].split()[2]} {self.after[p].split()[2]} M\0{p}\0" for p in self.paths)
        self.assertTrue(self.prove())
        path=next(iter(planner.TOOL_STORAGE_FORMAL_ADDITIONS));self.before[path]=f"100644 blob {'e'*40}\t{path}"
        self.assertFalse(self.prove())


class ToolStorageFormalLookupActivationTests(unittest.TestCase):
    def lookup(self, *, repo='soso-so-27/neko-widget', dedicated=False, configured=True, candidate=None, graph_error=False, head='a'*40):
        now=dt.datetime(2026,10,15,4,tzinfo=dt.timezone.utc);calls=[]
        current={'id':999,'head_sha':head,'head_branch':'main','event':'push','run_attempt':1,'workflow_id':335014238,
            'path':'.github/workflows/ios-build.yml','repository':{'full_name':repo},'head_repository':{'full_name':repo}}
        source=copy.deepcopy(planner.TOOL_STORAGE_FORMAL_QUEUED)
        env={'GITHUB_EVENT_NAME':'push','GITHUB_REF':'refs/heads/main','GITHUB_REPOSITORY':repo,'GITHUB_RUN_ID':'999','GITHUB_SHA':head}
        def api(path):
            calls.append(path)
            if path.endswith('/runs/999'):return current
            if path.endswith('/runs/'+str(planner.TOOL_STORAGE_FRESH_PHOTOS_RUN)):
                if repo!='soso-so-27/neko-widget' or not dedicated or head==planner.TOOL_STORAGE_FRESH_PHOTOS_SOURCE:
                    raise AssertionError('Fixed-source API stolen before eligible validation context')
                return source
            if '/workflows/ios-build.yml/runs?' in path:return {'workflow_runs':([candidate] if candidate else [])}
            raise AssertionError(path)
        with patch.object(planner,'tool_storage_formal_configured',return_value=configured), \
                patch.object(planner,'tool_storage_formal_equivalent_inputs',return_value=dedicated) as equivalence, \
                patch.object(planner,'git',return_value=head),patch.object(planner,'executed_jobs',return_value=[]), \
                patch.object(planner,'reusable_run',return_value=True),patch.object(planner,'covers_jobs',return_value=True), \
                patch.object(planner,'tool_storage_graph',side_effect=ValueError('unqualified actual graph') if graph_error else None) as graph:
            value=planner.find_evidence(env,planner.required_jobs_from_scope(planner.TOOL_STORAGE_SCOPE),api,now)
            return value,calls,graph.call_args,equivalence.call_count
    def test_active_pins_do_not_fetch_fixed_source_for_unrelated_validation_context(self):
        value,calls,_,_=self.lookup(dedicated=False)
        self.assertIsNone(value);self.assertFalse(any(path.endswith('/runs/'+str(planner.TOOL_STORAGE_FRESH_PHOTOS_RUN)) for path in calls))
        self.assertEqual(sum('/workflows/ios-build.yml/runs?' in path for path in calls),2)
    def test_active_pins_do_not_target_another_repository_even_if_equivalence_is_true(self):
        value,calls,_,equivalence_calls=self.lookup(repo='other/recipient',dedicated=True)
        self.assertIsNone(value);self.assertEqual(equivalence_calls,0)
        self.assertFalse(any(path.endswith('/runs/'+str(planner.TOOL_STORAGE_FRESH_PHOTOS_RUN)) for path in calls))
    def test_c033_and_ordinary_candidate_success_listing_is_preserved_when_not_dedicated(self):
        for sha in (planner.TOOL_STORAGE_PR_SOURCE,'e'*40):
            candidate={'id':123,'head_sha':sha}
            value,calls,call,_=self.lookup(candidate=candidate,dedicated=False,head=sha)
            self.assertEqual(value,(123,sha));self.assertEqual(call.args[0],candidate)
            self.assertFalse(any(path.endswith('/runs/'+str(planner.TOOL_STORAGE_FRESH_PHOTOS_RUN)) for path in calls))
    def test_only_literal_dedicated_main_uses_default_shared_graph_and_failure_never_falls_back(self):
        value,calls,call,_=self.lookup(dedicated=True)
        self.assertEqual(value,(planner.TOOL_STORAGE_FRESH_PHOTOS_RUN,planner.TOOL_STORAGE_FRESH_PHOTOS_SOURCE))
        self.assertEqual(call.args[1],'a'*40);self.assertEqual(call.kwargs,{})
        self.assertFalse(any('/workflows/ios-build.yml/runs?' in path for path in calls))
        with self.assertRaisesRegex(ValueError,'unqualified actual graph'):self.lookup(dedicated=True,graph_error=True)
    def test_missing_pins_or_source_only_head_cannot_enter_standalone_lookup(self):
        value,calls,_,_=self.lookup(configured=False,dedicated=True)
        self.assertIsNone(value);self.assertFalse(any(path.endswith('/runs/'+str(planner.TOOL_STORAGE_FRESH_PHOTOS_RUN)) for path in calls))
        value,calls,_,_=self.lookup(head=planner.TOOL_STORAGE_FRESH_PHOTOS_SOURCE,dedicated=True)
        self.assertIsNone(value);self.assertFalse(any(path.endswith('/runs/'+str(planner.TOOL_STORAGE_FRESH_PHOTOS_RUN)) for path in calls))
    def test_unobserved_negative_fixture_is_independent_of_activated_global_pins(self):
        active=ToolStorageStandalonePhotosTests();active.setUp();self.addCleanup(active.doCleanups)
        self.assertTrue(planner.tool_storage_formal_configured())
        fixture=ToolStorageStandaloneClosureTests();fixture.setUp()
        fixture.test_dedicated_plan_only_shape_is_exact_and_inactive_proof_remains_none()
        self.assertTrue(planner.tool_storage_formal_configured())


class ToolStorageActualObservedRegistrationTests(unittest.TestCase):
    def test_actual_registered_tuple_is_active_but_cannot_become_source_first_failure_or_unknown_scope(self):
        actual=copy.deepcopy(planner.TOOL_STORAGE_FORMAL_OBSERVED)
        self.assertTrue(planner.tool_storage_formal_configured())
        self.assertIsInstance(actual,dict);self.assertEqual(len(actual),12)
        for key,value in (('controller_sha',planner.TOOL_STORAGE_FRESH_PHOTOS_SOURCE),
                ('controller_sha',planner.TOOL_STORAGE_FORMAL_FIRST_FAILURE['head_sha']),
                ('branch','codex/unknown'),('workflow_id',335014238),
                ('run_id',planner.TOOL_STORAGE_FORMAL_FIRST_FAILURE['id']),
                ('photos_job_id',116230680503),('photos_job_id',actual['precheck_job_id']),
                ('photos_raw_log_sha256','invalid'),('photos_observations_sha256',None)):
            changed=dict(actual,**{key:value})
            with patch.object(planner,'TOOL_STORAGE_FORMAL_OBSERVED',changed):
                self.assertFalse(planner.tool_storage_formal_configured())
        with patch.object(planner,'TOOL_STORAGE_FORMAL_OBSERVED',dict(actual,unexpected='unknown')):
            self.assertFalse(planner.tool_storage_formal_configured())


if __name__ == "__main__":
    unittest.main()
