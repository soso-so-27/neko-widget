#!/usr/bin/env python3
"""Widget-specific test selection and evidence boundaries; no network or CI run."""

import copy
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import ios_ci_scope as scope


spec = importlib.util.spec_from_file_location("widget_scope_planner", Path(__file__).with_name("plan-ios-ci.py"))
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)

ROOT = Path(__file__).resolve().parents[2]




class ReportRuntimeCancelledDuplicateTests(unittest.TestCase):
    def fixture(self):
        import datetime as dt
        head=planner.REPORT_RUNTIME_DUPLICATE_HEAD
        now=dt.datetime.fromisoformat('2026-10-13T02:00:00+00:00')
        runs={identifier:dict(id=identifier,head_sha=head,head_branch=planner.REPORT_RUNTIME_BRANCH,path='.github/workflows/sharing-service.yml',event='push',workflow_id=planner.REPORT_RUNTIME_DUPLICATE_WORKFLOW,run_attempt=1,status='completed',repository={'full_name':'soso-so-27/neko-widget'},head_repository={'full_name':'soso-so-27/neko-widget'},**fixed) for identifier,fixed in planner.REPORT_RUNTIME_DUPLICATE_RUNS.items()}
        cancelled=runs[planner.REPORT_RUNTIME_CANCELLED_DUPLICATE];successful=runs[planner.REPORT_RUNTIME_SUCCESSFUL_DUPLICATE]
        jobs={cancelled['id']:[dict(id=identifier,name=name,head_sha=head,run_id=cancelled['id'],run_attempt=1,status='completed',conclusion='cancelled',started_at=start,completed_at=end,steps=[]) for identifier,(name,start,end) in planner.REPORT_RUNTIME_CANCELLED_JOBS.items()]}
        steps=(('Run python NekoWidget/ci/plan-ios-ci.py',),('Verify Apple transaction service boundary','Verify durable nonce and capability credential boundaries','Build nonroot Node image and private Worker without publishing'),('Parse and exercise Windows path, volume, and ACL policy',),('Run Worker, D1, staging, moderation, and key ceremony tests','Build deployment bundle without publishing'))
        jobs[successful['id']]=[dict(id=i+1,name=name,head_sha=head,run_id=successful['id'],run_attempt=1,status='completed',conclusion='success',completed_at=successful['updated_at'],steps=[dict(name=n,status='completed',conclusion='success') for n in expected]) for i,(name,expected) in enumerate(zip(planner.REPORT_RUNTIME_SHARING_JOBS,steps))]
        index={'total_count':2,'workflow_runs':[copy.deepcopy(successful),copy.deepcopy(cancelled)]}
        identity={'id':planner.REPORT_RUNTIME_DUPLICATE_WORKFLOW,'path':'.github/workflows/sharing-service.yml','state':'active'}
        def api(path):
            if '/runs?' in path:return index
            if '/jobs?' in path:
                owner=int(path.split('/runs/',1)[1].split('/',1)[0]);return {'total_count':len(jobs[owner]),'jobs':jobs[owner]}
            if '/runs/' in path:return runs[int(path.rsplit('/',1)[1])]
            return identity
        return head,now,index,runs,jobs,identity,api

    def test_fixed_zero_step_cancellation_is_retained_only_as_cancellation(self):
        head,now,index,runs,jobs,identity,api=self.fixture()
        evidence=planner.report_runtime_backend_evidence(head,api,now)
        self.assertEqual(evidence['run_id'],planner.REPORT_RUNTIME_SUCCESSFUL_DUPLICATE)
        self.assertEqual(evidence['required_jobs'],list(planner.REPORT_RUNTIME_SHARING_JOBS))
        self.assertEqual(evidence['cancelled_duplicate'],{'run_id':planner.REPORT_RUNTIME_CANCELLED_DUPLICATE,'conclusion':'cancelled','executed_step_count':0,'success_evidence':False})
        index['workflow_runs'].reverse()
        self.assertEqual(planner.report_runtime_backend_evidence(head,api,now),evidence)

    def test_started_cancel_or_failure_is_never_ignored(self):
        for mutation in ('step','failed_job','active_job','failed_run','active_run'):
            with self.subTest(mutation=mutation):
                head,now,index,runs,jobs,identity,api=self.fixture()
                cancelled=runs[planner.REPORT_RUNTIME_CANCELLED_DUPLICATE];job=jobs[cancelled['id']][0]
                if mutation=='step':job['steps']=[{'name':'Set up job','status':'completed','conclusion':'success'}]
                elif mutation=='failed_job':job['conclusion']='failure'
                elif mutation=='active_job':job['status']='in_progress'
                elif mutation=='failed_run':cancelled['conclusion']='failure'
                else:cancelled['status']='in_progress'
                with self.assertRaises(planner.CorrectionEvidenceUnavailable):planner.report_runtime_backend_evidence(head,api,now)

    def test_unknown_missing_or_ambiguous_runs_and_other_heads_are_rejected(self):
        for mutation in ('unknown_cancel','unknown_success','extra_success','duplicate_success','missing_cancel','bad_count','other_head'):
            with self.subTest(mutation=mutation):
                head,now,index,runs,jobs,identity,api=self.fixture()
                if mutation=='unknown_cancel':index['workflow_runs'][1]['id']+=1
                elif mutation=='unknown_success':index['workflow_runs'][0]['id']+=1
                elif mutation=='extra_success':index['workflow_runs'].append({**index['workflow_runs'][0],'id':900});index['total_count']=3
                elif mutation=='duplicate_success':index['workflow_runs'][1]=copy.deepcopy(index['workflow_runs'][0])
                elif mutation=='missing_cancel':index['workflow_runs'].pop();index['total_count']=1
                elif mutation=='bad_count':index['total_count']=1
                else:head='a'*40
                with self.assertRaises(planner.CorrectionEvidenceUnavailable):planner.report_runtime_backend_evidence(head,api,now)

    def test_fixed_run_and_zero_step_job_identity_cannot_drift(self):
        mutations=(('run','head_sha','a'*40),('run','head_branch','main'),('run','event','workflow_dispatch'),('run','path','.github/workflows/ios-build.yml'),('run','workflow_id',123),('run','run_attempt',2),('run','run_number',999),('run','created_at','2026-10-13T00:57:49Z'),('run','updated_at','2026-10-13T00:57:53Z'),('run','repository',{'full_name':'foreign/repo'}),('index','run_number',999),('job','head_sha','a'*40),('job','run_id',900),('job','run_attempt',2),('job','id',900),('job','name','unknown'),('job','started_at','2026-10-13T00:57:50Z'),('job','steps',None))
        for target,key,value in mutations:
            with self.subTest(target=target,key=key):
                head,now,index,runs,jobs,identity,api=self.fixture()
                owner=runs[planner.REPORT_RUNTIME_CANCELLED_DUPLICATE] if target=='run' else index['workflow_runs'][1] if target=='index' else jobs[planner.REPORT_RUNTIME_CANCELLED_DUPLICATE][0]
                owner[key]=value
                with self.assertRaises(planner.CorrectionEvidenceUnavailable):planner.report_runtime_backend_evidence(head,api,now)
        head,now,index,runs,jobs,identity,api=self.fixture()
        jobs[planner.REPORT_RUNTIME_CANCELLED_DUPLICATE].pop()
        with self.assertRaises(planner.CorrectionEvidenceUnavailable):planner.report_runtime_backend_evidence(head,api,now)

    def test_successful_run_still_requires_all_four_jobs_and_actual_steps(self):
        for mutation in ('missing_job','skipped_job','skipped_step','duplicate_job','failed_run','wrong_success_identity'):
            with self.subTest(mutation=mutation):
                head,now,index,runs,jobs,identity,api=self.fixture()
                run=runs[planner.REPORT_RUNTIME_SUCCESSFUL_DUPLICATE];executed=jobs[run['id']]
                if mutation=='missing_job':executed.pop()
                elif mutation=='skipped_job':executed[0]['conclusion']='skipped'
                elif mutation=='skipped_step':executed[0]['steps'][0]['conclusion']='skipped'
                elif mutation=='duplicate_job':executed.append({**executed[0],'id':900})
                elif mutation=='failed_run':run['conclusion']='failure'
                else:run['head_sha']='a'*40
                with self.assertRaises(planner.CorrectionEvidenceUnavailable):planner.report_runtime_backend_evidence(head,api,now)


class ReportRuntimeContinuationBoundaryTests(unittest.TestCase):
    def test_exact_four_product_pairs_and_native_tool_transition_are_closed(self):
        head='a'*40; raw='\0'.join(item for path,pair in planner.REPORT_RUNTIME_BLOBS.items() for item in (':100644 100644 '+' '.join(pair)+' M',path))+'\0'
        tools='\0'.join(item for path,pair in planner.REPORT_RUNTIME_TOOL_BLOBS.items() for item in (':100644 100644 '+' '.join(pair)+' M',path))+'\0'
        approved=True
        def git(*args):
            if args[0]=='merge-base':return 'c'*40
            if args[0]=='diff':return tools if args[-1]==planner.REPORT_RUNTIME_BASE else raw
            if args[0]=='show':return 'REPORT_RUNTIME_CONTINUATION_DIGESTS = '+repr(planner.REPORT_RUNTIME_CONTINUATION_DIGESTS)
            if args[0]=='ls-tree':return '100644 blob '+(('d' if approved or args[1]!='a'*40 else 'e')*40)+'\t'+args[-1]
            raise AssertionError(args)
        with patch.object(planner,'git',side_effect=git):
            self.assertTrue(planner.report_runtime_inputs(head))
            saved=raw
            for mutate in (lambda v:v.replace('100644 100644','100644 100755',1),
                           lambda v:v.replace(next(iter(planner.REPORT_RUNTIME_BLOBS.values()))[1],'f'*40,1),
                           lambda v:v+':100644 100644 '+('e'*40)+' '+('f'*40)+' M\0NekoWidget/Shared/Sharing/MomentSharingCore.swift\0',
                           lambda v:'\0'.join(v.split('\0')[2:])):
                raw=mutate(saved);self.assertFalse(planner.report_runtime_inputs(head))
            raw=saved;approved=False;self.assertFalse(planner.report_runtime_inputs(head))
            approved=True;tools+=':100644 100644 '+('e'*40)+' '+('f'*40)+' M\0NekoWidget/NekoWidget/Info.plist\0'
            self.assertFalse(planner.report_runtime_inputs(head))

    def test_known_branch_bad_scope_or_current_readiness_cannot_start_native_jobs(self):
        import datetime as dt
        now=dt.datetime.now(dt.timezone.utc)
        with patch.object(planner,'report_runtime_inputs',side_effect=lambda head,**kw:not kw.get('current',False)):
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):
                planner.report_runtime_source('a'*40,'soso-so-27/neko-widget',lambda _:self.fail('No API before current readiness'),now)
        with patch.object(planner,'report_runtime_inputs',return_value=True),patch.object(planner,'reply_readiness_inputs',return_value=False):
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):
                planner.report_runtime_source('a'*40,'soso-so-27/neko-widget',lambda _:self.fail('No API before original native closure'),now)
        with self.assertRaises(planner.CorrectionEvidenceUnavailable):
            planner.find_test_correction_evidence('a'*40,planner.REPORT_RUNTIME_BRANCH,'soso-so-27/neko-widget',planner.required_jobs_from_scope(scope.FULL_SCOPE),lambda _:self.fail('No API for wrong native graph'),now)

    def test_new_graph_requires_boundary_marker_fixed_proof_and_actual_backend(self):
        import datetime as dt,json
        now=dt.datetime.now(dt.timezone.utc);head='a'*40;validation='b'*40
        required=planner.required_jobs_from_scope(scope.REPORT_REPLY_ENTRY_SCOPE)
        run=dict(id=900,head_sha=head,head_branch=planner.REPORT_RUNTIME_BRANCH,path='.github/workflows/ios-build.yml',event='push',workflow_id=335014238,run_attempt=1,status='completed',conclusion='success',updated_at=now.isoformat(),repository={'full_name':'soso-so-27/neko-widget'},head_repository={'full_name':'soso-so-27/neko-widget'})
        jobs=[dict(id=777,name=planner.PLAN_JOB,head_sha=head,run_id=900,run_attempt=1,status='completed',conclusion='success',completed_at=now.isoformat(),steps=[dict(name=n,status='completed',conclusion='success') for n in ('Test CI selection and evidence boundaries','Select checks')])]
        proof=dict(kind=planner.REPORT_RUNTIME_KIND,candidate_sha=validation,required_backend_runs=planner.report_runtime_requirements(validation),jobs=[{'sha':planner.REPORT_RUNTIME_BUILD_SOURCE}])
        recorded={**proof,'candidate_sha':head,'required_backend_runs':planner.report_runtime_requirements(head)}
        record=dict(schema_version=1,repository='soso-so-27/neko-widget',head_sha=head,scope=scope.REPORT_REPLY_ENTRY_SCOPE,required_jobs=list(required),evidence_run_id=None,evidence_sha=None,test_correction_evidence=recorded,required_backend_runs=recorded['required_backend_runs'],report_runtime_boundary_checks={'head_sha':head,'passed':True,'commands':[list(c) for c in planner.REPORT_RUNTIME_BOUNDARY_COMMANDS]})
        api=lambda _: 'IOS_CI_PLAN_JSON='+json.dumps(record)
        with patch.object(planner,'report_runtime_inputs',return_value=True),patch.object(planner,'report_runtime_source',side_effect=lambda *_:dict(proof)),patch.object(planner,'report_runtime_backend_evidence',return_value={}) as backend:
            self.assertTrue(planner.covers_report_runtime_continuation(run,validation,required,api,now,jobs))
            backend.assert_called_once_with(head,api,now)
            for key in ('report_runtime_boundary_checks','required_backend_runs','test_correction_evidence'):
                saved=record.pop(key);backend.reset_mock()
                self.assertFalse(planner.covers_report_runtime_continuation(run,validation,required,api,now,jobs));backend.assert_not_called();record[key]=saved
            duplicate=[*jobs,{**jobs[0],'id':778}]
            self.assertFalse(planner.covers_report_runtime_continuation(run,validation,required,api,now,duplicate))
            record['schema_version']=2
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):planner.covers_report_runtime_continuation(run,validation,required,api,now,jobs)

    def test_all_four_new_sharing_jobs_and_steps_are_required(self):
        import datetime as dt
        now=dt.datetime.now(dt.timezone.utc);head='a'*40
        run=dict(id=900,head_sha=head,head_branch=planner.REPORT_RUNTIME_BRANCH,path='.github/workflows/sharing-service.yml',event='push',workflow_id=123,run_attempt=1,status='completed',conclusion='success',updated_at=now.isoformat(),run_number=9,repository={'full_name':'soso-so-27/neko-widget'},head_repository={'full_name':'soso-so-27/neko-widget'})
        names=(('Run python NekoWidget/ci/plan-ios-ci.py',),('Verify Apple transaction service boundary','Verify durable nonce and capability credential boundaries','Build nonroot Node image and private Worker without publishing'),('Parse and exercise Windows path, volume, and ACL policy',),('Run Worker, D1, staging, moderation, and key ceremony tests','Build deployment bundle without publishing'))
        jobs=[dict(id=i+1,name=name,head_sha=head,run_id=900,run_attempt=1,status='completed',conclusion='success',completed_at=now.isoformat(),steps=[dict(name=n,status='completed',conclusion='success') for n in steps]) for i,(name,steps) in enumerate(zip(planner.REPORT_RUNTIME_SHARING_JOBS,names))]
        def api(path):
            if '/jobs?' in path:return {'total_count':len(jobs),'jobs':jobs}
            if '/runs?' in path:return {'total_count':1,'workflow_runs':[run]}
            if path.endswith('/900'):return run
            return {'id':123,'path':'.github/workflows/sharing-service.yml','state':'active'}
        self.assertEqual(planner.report_runtime_backend_evidence(head,api,now)['sha'],head)
        for job in jobs:
            saved=job['conclusion'];job['conclusion']='skipped'
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):planner.report_runtime_backend_evidence(head,api,now)
            job['conclusion']=saved
            step=job['steps'][0];saved=step['conclusion'];step['conclusion']='skipped'
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):planner.report_runtime_backend_evidence(head,api,now)
            step['conclusion']=saved
        run['event']='workflow_dispatch'
        with self.assertRaises(planner.CorrectionEvidenceUnavailable):planner.report_runtime_backend_evidence(head,api,now)

    def test_fixed_build_requires_all39_checks_and_failed_release_upload_skip(self):
        import datetime as dt,json
        now=dt.datetime.now(dt.timezone.utc);head='a'*40;repo='soso-so-27/neko-widget'
        def run(identifier,sha,path,branch,event,outcome,wid):
            return dict(id=identifier,head_sha=sha,path=path,head_branch=branch,event=event,status='completed',conclusion=outcome,workflow_id=wid,run_attempt=1,updated_at=now.isoformat(),repository={'full_name':repo},head_repository={'full_name':repo})
        buildrun=run(planner.REPORT_RUNTIME_BUILD_RUN,planner.REPORT_RUNTIME_BUILD_SOURCE,'.github/workflows/ios-build.yml',planner.REPLY_READINESS_BRANCH,'push','success',335014238)
        release=run(planner.REPORT_RUNTIME_FAILED_RELEASE,planner.REPORT_RUNTIME_BASE,'.github/workflows/testflight.yml','main','workflow_dispatch','failure',335014239)
        names=tuple('check'+str(i) for i in range(39))
        def job(identifier,name,owner,steps,outcome='success'):
            return dict(id=identifier,name=name,head_sha=owner['head_sha'],run_id=owner['id'],run_attempt=1,status='completed',conclusion=outcome,completed_at=now.isoformat(),steps=steps)
        steps=lambda items:[dict(name=n,status='completed',conclusion='success') for n in items]
        jobs=[job(planner.REPORT_RUNTIME_BUILD_PLAN,planner.PLAN_JOB,buildrun,steps(('Test CI selection and evidence boundaries','Select checks'))),job(planner.REPORT_RUNTIME_BUILD_JOB,planner.BUILD,buildrun,steps(names))]
        failed_steps=[dict(name=n,status='completed',conclusion=c) for n,c in [('Validate the exact runtime embedded in the limited external beta','failure'),('Archive app and widget','skipped'),('Validate and upload IPA to TestFlight','skipped')]]
        release_jobs=[job(planner.REPORT_RUNTIME_FAILED_RELEASE_JOB,'Archive, export IPA, and upload',release,failed_steps,'failure')]
        original={'jobs':[{'name':n,'job_id':planner.REPLY_READINESS_JOB_IDS[n]} for n in planner.required_jobs_from_scope(scope.REPORT_REPLY_ENTRY_SCOPE) if n!=planner.BUILD]}
        record=dict(schema_version=1,repository=repo,head_sha=buildrun['head_sha'],scope=scope.REPORT_REPLY_ENTRY_SCOPE,required_jobs=list(planner.required_jobs_from_scope(scope.REPORT_REPLY_ENTRY_SCOPE)),evidence_run_id=None,evidence_sha=None,test_correction_evidence=original)
        def api(path):
            if '/jobs?' in path:return {'total_count':len(release_jobs if str(release['id']) in path else jobs),'jobs':release_jobs if str(release['id']) in path else jobs}
            return release if path.endswith('/'+str(release['id'])) else buildrun
        with patch.object(planner,'report_runtime_inputs',return_value=True),patch.object(planner,'reply_readiness_source_facts',return_value=original),patch.object(planner,'reply_readiness_build_steps',return_value=names),patch.object(planner,'report_runtime_log',side_effect=lambda api,id,digest:'IOS_CI_PLAN_JSON='+json.dumps(record) if id==planner.REPORT_RUNTIME_BUILD_PLAN else 'pinned'):
            proof=planner.report_runtime_source(head,repo,api,now);self.assertEqual(len(proof['jobs']),4)
            saved=jobs[1]['steps'].pop()
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):planner.report_runtime_source(head,repo,api,now)
            jobs[1]['steps'].append(saved);failed_steps[-1]['conclusion']='success'
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):planner.report_runtime_source(head,repo,api,now)

    def test_native_plan_executes_boundaries_and_emits_no_mac_flags(self):
        import contextlib,io,json,tempfile
        head='a'*40
        proof={'kind':planner.REPORT_RUNTIME_KIND,'sha':planner.REPORT_RUNTIME_BUILD_SOURCE,'run_id':planner.REPORT_RUNTIME_BUILD_RUN,'jobs':[]}
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp);event=folder/'event.json';event.write_text('{}');output=folder/'output';summary=folder/'summary'
            env={'GITHUB_EVENT_PATH':str(event),'GITHUB_OUTPUT':str(output),'GITHUB_STEP_SUMMARY':str(summary),'GITHUB_EVENT_NAME':'push','GITHUB_REF':'refs/heads/'+planner.REPORT_RUNTIME_BRANCH,'GITHUB_REPOSITORY':'soso-so-27/neko-widget','GITHUB_SHA':head,'GITHUB_RUN_ID':'900','GITHUB_WORKFLOW':'iOS build'}
            marker={'head_sha':head,'passed':True,'commands':[list(c) for c in planner.REPORT_RUNTIME_BOUNDARY_COMMANDS]}
            captured=io.StringIO()
            with patch.dict(planner.os.environ,env,clear=True),patch.object(planner,'changed_paths',return_value=list(planner.REPORT_RUNTIME_BLOBS)),patch.object(planner,'runtime_scope',return_value=scope.REPORT_REPLY_ENTRY_SCOPE),patch.object(planner,'find_evidence',return_value=None),patch.object(planner,'find_test_correction_evidence',return_value=proof),patch.object(planner,'report_runtime_inputs',return_value=True),patch.object(planner,'preservation_sharing_plan',return_value=False),patch.object(planner,'report_runtime_boundary_checks',return_value=marker) as boundary,contextlib.redirect_stdout(captured):
                planner.main()
            boundary.assert_called_once_with(head)
            flags=output.read_text()
            for flag in ('build','smoke','sharing','app_ui'):self.assertIn(flag+'=false',flags)
            record=json.loads(next(line.split('=',1)[1] for line in captured.getvalue().splitlines() if line.startswith('IOS_CI_PLAN_JSON=')))
            self.assertEqual(record['report_runtime_boundary_checks'],marker)
            self.assertEqual(record['required_backend_runs'],planner.report_runtime_requirements(head))

    def test_cost_retains_original_clock_failure_and_reference(self):
        import datetime as dt
        spec=importlib.util.spec_from_file_location('runtime_cost_preflight',Path(__file__).with_name('preflight-ci.py'));preflight=importlib.util.module_from_spec(spec);spec.loader.exec_module(preflight)
        result={'scope':scope.REPORT_REPLY_ENTRY_SCOPE,'target_minutes':180}
        proof={'kind':planner.REPORT_RUNTIME_KIND,'jobs':[]}
        cost=preflight.report_reply_readiness_cost(dict(result),proof,True,{'upload_minutes':12})
        self.assertEqual(cost['cost']['with_upload_minutes'],[0,32]);self.assertFalse(cost['cost']['includes_future_rework'])
        for upload in (float('nan'),float('inf'),-1):
            with self.assertRaises(ValueError):preflight.report_reply_readiness_cost(dict(result),proof,True,{'upload_minutes':upload})
        now=dt.datetime.fromisoformat('2026-10-13T01:13:27+00:00');head='a'*40
        proof.update(candidate_sha=head,run_id=planner.REPORT_RUNTIME_BUILD_RUN,sha=planner.REPORT_RUNTIME_BUILD_SOURCE,owning_jobs_to_execute=[],failed_release_run_id=planner.REPORT_RUNTIME_FAILED_RELEASE,failed_release_job_id=planner.REPORT_RUNTIME_FAILED_RELEASE_JOB,failed_release_log_sha256=planner.REPORT_RUNTIME_FAILED_RELEASE_LOG,failed_release_upload_skipped=True,required_backend_runs=planner.report_runtime_requirements(head))
        runs=[dict(id=id,head_sha=sha,path=path,status='completed',conclusion='failure',created_at='2026-10-13T00:00:00Z',failed_tests=[],unsupported_failed_tests=[]) for id,sha,path in ((planner.REPLY_READINESS_RUN,planner.REPLY_READINESS_SOURCE,preflight.IOS_WORKFLOW),(planner.REPORT_RUNTIME_FAILED_RELEASE,planner.REPORT_RUNTIME_BASE,'.github/workflows/testflight.yml'))]
        cost['head']=head;cost['required_jobs']=list(planner.required_jobs_from_scope(scope.REPORT_REPLY_ENTRY_SCOPE))
        gated=preflight.apply_task_gate(cost,runs,now,correction_evidence=proof)
        self.assertEqual(gated['task']['failed_runs'],[planner.REPLY_READINESS_RUN,planner.REPORT_RUNTIME_FAILED_RELEASE])
        self.assertEqual(gated['task']['minutes_since_first_candidate'],180)
        self.assertEqual(gated['task']['projected_total_minutes'],212)
        self.assertIn('cumulative_cost_requires_replanning',gated['task']['blockers']);self.assertFalse(gated['ready'])


class ReportReplyEntryBoundaryTests(unittest.TestCase):
    def test_preflight_routes_reply_scope_through_required_recovery_verification(self):
        import contextlib, io
        spec = importlib.util.spec_from_file_location('reply_routing_preflight', Path(__file__).with_name('preflight-ci.py'))
        preflight = importlib.util.module_from_spec(spec); spec.loader.exec_module(preflight)
        candidate = {'scope': scope.REPORT_REPLY_ENTRY_SCOPE, 'head': 'a'*40,
                     'required_jobs': list(planner.required_jobs_from_scope(scope.REPORT_REPLY_ENTRY_SCOPE))}
        errors = io.StringIO()
        with patch.object(preflight, 'candidate_plan', return_value=candidate), \
             patch.object(preflight, 'read_task_runs', return_value=[]), \
             patch.object(preflight.planner, 'git', return_value=planner.REPLY_READINESS_BRANCH), \
             patch.object(preflight.planner, 'find_test_correction_evidence', side_effect=ValueError('Required recovery reached')) as verifier, \
             contextlib.redirect_stderr(errors):
            self.assertEqual(preflight.main([]), 2)
        verifier.assert_called_once()
        self.assertIn('Required recovery reached', errors.getvalue())

    def test_readiness_cost_rejects_invalid_upload_and_keeps_reference_bounds(self):
        spec = importlib.util.spec_from_file_location('reply_cost_preflight', Path(__file__).with_name('preflight-ci.py'))
        preflight = importlib.util.module_from_spec(spec); spec.loader.exec_module(preflight)
        proof = {'jobs': ['Photos', 'Runtime', 'ReplyUI']}
        result = {'scope': scope.REPORT_REPLY_ENTRY_SCOPE, 'target_minutes': 30}
        for value in (float('nan'), float('inf'), -1):
            with self.assertRaises(ValueError):
                preflight.report_reply_readiness_cost(dict(result), proof, True, {'upload_minutes': value})
        actual = preflight.report_reply_readiness_cost(dict(result), proof, True, {'upload_minutes': 12})
        self.assertEqual(actual['cost']['with_upload_minutes'], [0, 42])
        self.assertFalse(actual['ready'])
        self.assertEqual(actual['cost']['required_jobs_to_execute'], [planner.BUILD])

    def test_known_recovery_stops_if_current_signature_or_lease_is_invalid(self):
        import datetime as dt
        with patch.object(planner,'reply_readiness_inputs',side_effect=lambda head,**kw:not kw.get('current',False)):
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):
                planner.reply_readiness_source('a'*40,'soso-so-27/neko-widget',lambda _:self.fail('No API call after invalid readiness'),dt.datetime.now(dt.timezone.utc))

    def test_recovery_rejects_wrong_source_failed_siblings_and_unknown_build_failure(self):
        import datetime as dt
        now = dt.datetime.now(dt.timezone.utc)
        stamp = now.isoformat()
        run = dict(id=planner.REPLY_READINESS_RUN, head_sha=planner.REPLY_READINESS_SOURCE,
            head_branch=planner.REPLY_READINESS_BRANCH, event='push', run_attempt=1,
            path='.github/workflows/ios-build.yml', workflow_id=335014238,
            status='completed', conclusion='failure', updated_at=stamp,
            repository={'full_name':'soso-so-27/neko-widget'},head_repository={'full_name':'soso-so-27/neko-widget'})
        jobs=[]
        for name,identifier in planner.REPLY_READINESS_JOB_IDS.items():
            steps = (['Verify sharing release privacy gates'] if name==planner.BUILD else
                ['Test CI selection and evidence boundaries','Select checks'] if name==planner.PLAN_JOB else
                ['Run Simulator smoke test','Upload Simulator smoke-test artifacts'] if name==planner.BOOTSTRAP_SMOKE else
                ['Run sharing runtime matrix','Upload sharing runtime matrix artifacts'])
            jobs.append(dict(id=identifier,name=name,head_sha=run['head_sha'],run_id=run['id'],run_attempt=1,
                status='completed',conclusion='failure' if name==planner.BUILD else 'success',completed_at=stamp,
                steps=[dict(name=n,status='completed',conclusion='failure' if name==planner.BUILD else 'success') for n in steps]))
        def api(path):
            if '/jobs?' in path:return {'total_count':len(jobs),'jobs':jobs}
            if path.endswith('/logs'):return 'fixed log'
            return run
        hashes={name:scope.hashlib.sha256(b'fixed log').hexdigest() for name in planner.REPLY_READINESS_LOG_HASHES}
        with patch.object(planner,'reply_readiness_inputs',return_value=True), patch.dict(planner.REPLY_READINESS_LOG_HASHES,hashes,clear=True):
            proof=planner.reply_readiness_source('a'*40,'soso-so-27/neko-widget',api,now)
            self.assertEqual(proof['owning_jobs_to_execute'],[planner.BUILD])
            self.assertEqual(len(proof['jobs']),3)
            for key,value in [('head_sha','b'*40),('event','workflow_dispatch'),('head_branch','codex/other'),('conclusion','success')]:
                saved=run[key];run[key]=value
                with self.assertRaises(planner.CorrectionEvidenceUnavailable):planner.reply_readiness_source('a'*40,'soso-so-27/neko-widget',api,now)
                run[key]=saved
            for job in jobs:
                if job['name']==planner.BUILD:continue
                saved=job['conclusion'];job['conclusion']='skipped'
                with self.assertRaises(planner.CorrectionEvidenceUnavailable):planner.reply_readiness_source('a'*40,'soso-so-27/neko-widget',api,now)
                job['conclusion']=saved
            build=next(j for j in jobs if j['name']==planner.BUILD)
            build['steps'][0]['name']='Unrelated failure'
            with self.assertRaises(planner.CorrectionEvidenceUnavailable):planner.reply_readiness_source('a'*40,'soso-so-27/neko-widget',api,now)

    def test_readiness_recovery_requires_exact_three_metadata_pairs_and_approved_controls(self):
        head='a'*40;before=planner.REPLY_READINESS_SOURCE
        changes=[]
        for path,(old,new) in planner.REPLY_READINESS_BLOBS.items():changes.extend([f':100644 100644 {old} {new} M',path])
        raw='\0'.join(changes)+'\0'
        def git(*args):
            if args[0]=='merge-base':return 'c'*40 if args[1]!='--is-ancestor' else ''
            if args[0]=='diff':return raw
            if args[0]=='ls-tree':return '100644 blob '+('d'*40)+'\t'+args[-1]
            raise AssertionError(args)
        with patch.object(planner,'git',side_effect=git):
            self.assertTrue(planner.reply_readiness_inputs(head))
            saved=raw
            raw=raw.replace('100644 100644','100644 100755',1)
            self.assertFalse(planner.reply_readiness_inputs(head))
            raw=saved+':100644 100644 '+('e'*40)+' '+('f'*40)+' M\0NekoWidget/Shared/Sharing/MomentSharingCore.swift\0'
            self.assertFalse(planner.reply_readiness_inputs(head))
            raw='\0'.join(changes[2:])+'\0'
            self.assertFalse(planner.reply_readiness_inputs(head))

    def test_exact_two_files_are_required_and_every_changed_byte_is_bound(self):
        changes = {path: ("before" + str(i), "after" + str(i))
                   for i, path in enumerate(scope.REPORT_REPLY_ENTRY_DIGESTS)}
        pairs = {path: tuple(scope.source_digest(v) for v in pair) for path, pair in changes.items()}
        with patch.dict(scope.REPORT_REPLY_ENTRY_DIGESTS, pairs, clear=True):
            self.assertTrue(scope.report_reply_entry_changes(changes))
            self.assertEqual(scope.select_scope(changes), scope.REPORT_REPLY_ENTRY_SCOPE)
            for path in changes:
                missing = dict(changes); missing.pop(path)
                self.assertFalse(scope.report_reply_entry_changes(missing))
                for side in (0, 1):
                    mutated = dict(changes); value = list(mutated[path]); value[side] += "changed"
                    mutated[path] = tuple(value)
                    self.assertFalse(scope.report_reply_entry_changes(mutated))
            extra = dict(changes); extra["NekoWidget/Shared/Sharing/MomentSharingCore.swift"] = ("old", "new")
            self.assertFalse(scope.report_reply_entry_changes(extra))

    def test_required_native_checks_and_owned_operations_remain_real(self):
        selected = scope.REPORT_REPLY_ENTRY_SCOPE
        self.assertIn(selected, scope.SCOPES)
        jobs = planner.required_jobs_from_scope(selected)
        self.assertEqual(jobs, (planner.BUILD, planner.BOOTSTRAP_SMOKE,
            scope.lane_job(selected, "runtime"), scope.lane_job(selected, "app-ui")))
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(len(scope.native_tests(selected)), 4)
        self.assertIn("NekoWidgetUITests/MomentDeliveryComposerUITests/testReportReplyEntryRemainsVisibleWithLargestText", scope.native_tests(selected))
        self.assertNotIn(scope.GALLERY_TEST, scope.native_tests(selected))
        paths = list(scope.REPORT_REPLY_ENTRY_DIGESTS)
        self.assertTrue(scope.accepts_paths(selected, paths))
        self.assertFalse(scope.accepts_paths(selected, paths + [paths[0]]))
        self.assertFalse(scope.accepts_paths(selected, paths + ["NekoWidget/SharingService/src/moments.ts"]))

class MembershipStateNativeBoundaryTests(unittest.TestCase):
    def test_exact_owning_operations_keep_build_photos_and_both_os_runtime(self):
        selected = scope.REVIEWED_MEMBERSHIP_STATE_SCOPE
        self.assertIn(selected, scope.SCOPES)
        expected = tuple("NekoWidgetUITests/SoloMemoriesUITests/" + method for method in (
            "testMembershipOfferPreviewReturnsToPurpose",
            "testMembershipOfferPreviewWaitingAndRestore",
            "testMembershipOfferExplainsExpiryWithoutChangingThePlan",
            "testMembershipAccessPreservesExistingMemoAndDistinguishesUnknown",
        )) + ("NekoWidgetUITests/MomentDeliveryComposerUITests/"
              "testWindowSupportResumeRequiresApprovalAndKeepsUnknownSeparate",)
        self.assertEqual(scope.native_tests(selected), expected)
        self.assertEqual(scope.lane_tests(selected, "app-ui"), expected)
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(scope.matrix_lanes(selected), ("runtime",))
        self.assertEqual(scope.app_ui_lanes(selected), ("app-ui",))
        self.assertEqual(scope.smoke_tests(selected), (
            "NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",
            "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary",
        ))
        required = planner.required_jobs_from_scope(selected)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE,
            scope.lane_job(selected, "runtime"), scope.lane_job(selected, "app-ui")))
        # The unchanged runtime lane still executes the existing two-OS matrix.
        self.assertEqual(scope.SHARING_JOB_PREFIX, "Sharing runtime self-test (iOS 18.5 / 26.2)")
        source = (ROOT / scope.MEMORY_TEST_PATH).read_text(encoding="utf-8")
        self.assertTrue(scope.memory_tests_available(source, expected))
        for lane in ("gallery-normal", "gallery-variants", "app-ui-solo-1", "app-ui-other"):
            with self.assertRaises(ValueError): scope.lane_tests(selected, lane)

    def test_exact_paths_reject_partial_or_shared_and_keep_old_scope_inventory(self):
        selected = scope.REVIEWED_MEMBERSHIP_STATE_SCOPE
        self.assertEqual(scope.MEMBERSHIP_STATE_PATHS, frozenset({
            "NekoWidget/NekoWidget/App/NekoWidgetApp.swift",
            "NekoWidget/NekoWidget/Services/PlusPurchaseStore.swift",
            "NekoWidget/NekoWidget/Services/MembershipOfferModel.swift",
            "NekoWidget/NekoWidget/Views/MembershipOfferView.swift",
            "NekoWidget/NekoWidget/Views/WindowSupportResumeView.swift",
            "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift",
            "NekoWidget/ci/test-plus-purchase-foundation.py",
        }))
        paths = scope.MEMBERSHIP_STATE_PATHS | scope.MEMBERSHIP_STATE_COMPANIONS
        self.assertTrue(scope.accepts_paths(selected, paths))
        self.assertTrue(scope.accepts_paths(selected, scope.MEMBERSHIP_STATE_PATHS))
        self.assertTrue(scope.accepts_paths(selected, paths | {"handoffs/member.md"}))
        for path in paths:
            self.assertFalse(scope.accepts_paths(selected, paths - {path}), path)
            self.assertEqual(planner.required_jobs(sorted(paths - {path}), selected), planner.FULL)
        for extra in ("NekoWidget/Shared/MembershipAccessPolicy.swift", "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                      "NekoWidget/NekoWidget.xcodeproj/project.pbxproj", scope.CI_WORKFLOW):
            self.assertFalse(scope.accepts_paths(selected, paths | {extra}))
            self.assertEqual(planner.required_jobs(sorted(paths | {extra}), selected), planner.FULL)
        self.assertFalse(scope.accepts_paths(selected, None))
        self.assertFalse(scope.accepts_paths(selected, []))
        self.assertEqual(len(scope.native_tests(scope.BILLING_LOCAL_PREPARATION_SCOPE)), 3)
        self.assertEqual(scope.lanes(scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE), ("runtime", "app-ui"))
        self.assertNotIn(scope.GALLERY_TEST, scope.native_tests(selected))

    def test_release_evidence_requires_all_four_successful_same_sha_jobs(self):
        selected, sha = scope.REVIEWED_MEMBERSHIP_STATE_SCOPE, "a" * 40
        required = planner.required_jobs_from_scope(selected)
        jobs = [{"name": name, "head_sha": sha, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, sha))
        self.assertFalse(planner.covers_jobs(jobs, planner.FULL, sha))
        self.assertFalse(planner.covers_jobs(jobs, required, "b" * 40))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, sha))
            for conclusion in ("failure", "skipped", "cancelled", None):
                changed = copy.deepcopy(jobs); changed[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(changed, required, sha), (index, conclusion))
        old = planner.required_jobs_from_scope(scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE)
        old_jobs = [{"name": name, "head_sha": sha, "status": "completed", "conclusion": "success"} for name in old]
        self.assertFalse(planner.covers_jobs(old_jobs, required, sha))


class PurchaseCatalogNativeBoundaryTests(unittest.TestCase):
    def test_exact_owning_operations_keep_build_photos_and_both_os_runtime(self):
        selected = scope.REVIEWED_PURCHASE_CATALOG_SCOPE
        self.assertIn(selected, scope.SCOPES)
        expected = tuple("NekoWidgetUITests/SoloMemoriesUITests/" + method for method in (
            "testMembershipOfferPreviewReturnsToPurpose",
            "testMembershipOfferPreviewWaitingAndRestore",
            "testMembershipOfferExplainsExpiryWithoutChangingThePlan",
            "testMembershipAccessPreservesExistingMemoAndDistinguishesUnknown",
        )) + ("NekoWidgetUITests/MomentDeliveryComposerUITests/"
              "testWindowSupportResumeRequiresApprovalAndKeepsUnknownSeparate",)
        self.assertEqual(scope.native_tests(selected), expected)
        self.assertEqual(scope.lane_tests(selected, "app-ui"), expected)
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(scope.matrix_lanes(selected), ("runtime",))
        self.assertEqual(scope.app_ui_lanes(selected), ("app-ui",))
        self.assertEqual(scope.smoke_tests(selected), (
            "NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",
            "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary",
        ))
        required = planner.required_jobs_from_scope(selected)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE,
            scope.lane_job(selected, "runtime"), scope.lane_job(selected, "app-ui")))
        # The unchanged runtime lane still executes the existing two-OS matrix.
        self.assertEqual(scope.SHARING_JOB_PREFIX, "Sharing runtime self-test (iOS 18.5 / 26.2)")
        source = (ROOT / scope.MEMORY_TEST_PATH).read_text(encoding="utf-8")
        self.assertTrue(scope.memory_tests_available(source, expected))
        for lane in ("gallery-normal", "gallery-variants", "app-ui-solo-1", "app-ui-other"):
            with self.assertRaises(ValueError): scope.lane_tests(selected, lane)

    def test_exact_paths_reject_partial_or_shared_and_keep_old_scope_inventory(self):
        selected = scope.REVIEWED_PURCHASE_CATALOG_SCOPE
        self.assertEqual(scope.PURCHASE_CATALOG_PATHS, frozenset({'NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift', 'NekoWidget/NekoWidget/Services/MembershipOfferModel.swift', 'NekoWidget/ci/test-plus-purchase-foundation.py', 'NekoWidget/NekoWidget/Services/PlusPurchaseStore.swift'}))
        paths = scope.PURCHASE_CATALOG_PATHS | scope.PURCHASE_CATALOG_COMPANIONS
        self.assertTrue(scope.accepts_paths(selected, paths))
        self.assertTrue(scope.accepts_paths(selected, scope.PURCHASE_CATALOG_PATHS))
        self.assertTrue(scope.accepts_paths(selected, paths | {"handoffs/member.md"}))
        for path in paths:
            self.assertFalse(scope.accepts_paths(selected, paths - {path}), path)
            self.assertEqual(planner.required_jobs(sorted(paths - {path}), selected), planner.FULL)
        for extra in ("NekoWidget/Shared/MembershipAccessPolicy.swift", "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                      "NekoWidget/NekoWidget.xcodeproj/project.pbxproj", scope.CI_WORKFLOW):
            self.assertFalse(scope.accepts_paths(selected, paths | {extra}))
            self.assertEqual(planner.required_jobs(sorted(paths | {extra}), selected), planner.FULL)
        self.assertFalse(scope.accepts_paths(selected, None))
        self.assertFalse(scope.accepts_paths(selected, []))
        self.assertEqual(len(scope.native_tests(scope.BILLING_LOCAL_PREPARATION_SCOPE)), 3)
        self.assertEqual(scope.lanes(scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE), ("runtime", "app-ui"))
        self.assertNotIn(scope.GALLERY_TEST, scope.native_tests(selected))

    def test_release_evidence_requires_all_four_successful_same_sha_jobs(self):
        selected, sha = scope.REVIEWED_PURCHASE_CATALOG_SCOPE, "a" * 40
        required = planner.required_jobs_from_scope(selected)
        jobs = [{"name": name, "head_sha": sha, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, sha))
        self.assertFalse(planner.covers_jobs(jobs, planner.FULL, sha))
        self.assertFalse(planner.covers_jobs(jobs, required, "b" * 40))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, sha))
            for conclusion in ("failure", "skipped", "cancelled", None):
                changed = copy.deepcopy(jobs); changed[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(changed, required, sha), (index, conclusion))
        old = planner.required_jobs_from_scope(scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE)
        old_jobs = [{"name": name, "head_sha": sha, "status": "completed", "conclusion": "success"} for name in old]
        self.assertFalse(planner.covers_jobs(old_jobs, required, sha))


class PreservationExportNativeBoundaryTests(unittest.TestCase):
    def test_exact_owning_operations_keep_build_photos_and_both_os_runtime(self):
        selected = scope.PRESERVATION_EXPORT_SCOPE
        self.assertIn(selected, scope.SCOPES)
        expected = (
            "NekoWidgetUITests/SoloMemoriesUITests/testManagedPreservationMembershipLinkConsentAndRetry",
            "NekoWidgetUITests/SoloMemoriesUITests/testMemoryNoteExportCancellationKeepsText",
            "NekoWidgetUITests/SoloMemoriesUITests/testPersonalArchiveExportCancellationKeepsPhotoAndText",
            "NekoWidgetUITests/MomentDeliveryComposerUITests/testFamilyRecordKeepsOtherAuthorsWordsWhenPhotoIsWithdrawnAndRevokesAccess",
        )
        self.assertEqual(scope.native_tests(selected), expected)
        self.assertEqual(scope.lane_tests(selected, "app-ui"), expected)
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(scope.matrix_lanes(selected), ("runtime",))
        self.assertEqual(scope.app_ui_lanes(selected), ("app-ui",))
        self.assertEqual(scope.smoke_tests(selected), (
            "NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",
            "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary",
        ))
        required = planner.required_jobs_from_scope(selected)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE,
            scope.lane_job(selected, "runtime"), scope.lane_job(selected, "app-ui")))
        # The unchanged runtime lane still executes the existing two-OS matrix.
        self.assertEqual(scope.SHARING_JOB_PREFIX, "Sharing runtime self-test (iOS 18.5 / 26.2)")
        source = (ROOT / scope.MEMORY_TEST_PATH).read_text(encoding="utf-8")
        self.assertTrue(scope.memory_tests_available(source, expected))
        for lane in ("gallery-normal", "gallery-variants", "app-ui-solo-1", "app-ui-other"):
            with self.assertRaises(ValueError): scope.lane_tests(selected, lane)

    def test_exact_paths_reject_partial_or_shared_and_keep_old_scope_inventory(self):
        selected = scope.PRESERVATION_EXPORT_SCOPE
        self.assertEqual(len(scope.PRESERVATION_EXPORT_PATHS), 31)
        self.assertEqual(len(scope.PRESERVATION_EXPORT_COMPANIONS), 6)
        self.assertIn("NekoWidget/PreservationService/src/export-page.ts", scope.PRESERVATION_EXPORT_PATHS)
        self.assertIn("NekoWidget/NekoWidget/Services/ManagedPreservationClient.swift", scope.PRESERVATION_EXPORT_PATHS)
        paths = scope.PRESERVATION_EXPORT_PATHS | scope.PRESERVATION_EXPORT_COMPANIONS
        self.assertTrue(scope.accepts_paths(selected, paths))
        self.assertTrue(scope.accepts_paths(selected, scope.PRESERVATION_EXPORT_PATHS))
        self.assertTrue(scope.accepts_paths(selected, paths | {"handoffs/member.md"}))
        for path in paths:
            self.assertFalse(scope.accepts_paths(selected, paths - {path}), path)
            self.assertEqual(planner.required_jobs(sorted(paths - {path}), selected), planner.FULL)
        for extra in ("NekoWidget/Shared/MembershipAccessPolicy.swift", "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                      "NekoWidget/NekoWidget.xcodeproj/project.pbxproj", scope.CI_WORKFLOW):
            self.assertFalse(scope.accepts_paths(selected, paths | {extra}))
            self.assertEqual(planner.required_jobs(sorted(paths | {extra}), selected), planner.FULL)
        self.assertFalse(scope.accepts_paths(selected, None))
        self.assertFalse(scope.accepts_paths(selected, []))
        self.assertEqual(len(scope.native_tests(scope.BILLING_LOCAL_PREPARATION_SCOPE)), 3)
        self.assertEqual(scope.lanes(scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE), ("runtime", "app-ui"))
        self.assertNotIn(scope.GALLERY_TEST, scope.native_tests(selected))

    def test_release_evidence_requires_all_four_successful_same_sha_jobs(self):
        selected, sha = scope.PRESERVATION_EXPORT_SCOPE, "a" * 40
        required = planner.required_jobs_from_scope(selected)
        jobs = [{"name": name, "head_sha": sha, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, sha))
        self.assertFalse(planner.covers_jobs(jobs, planner.FULL, sha))
        self.assertFalse(planner.covers_jobs(jobs, required, "b" * 40))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, sha))
            for conclusion in ("failure", "skipped", "cancelled", None):
                changed = copy.deepcopy(jobs); changed[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(changed, required, sha), (index, conclusion))
        old = planner.required_jobs_from_scope(scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE)
        old_jobs = [{"name": name, "head_sha": sha, "status": "completed", "conclusion": "success"} for name in old]
        self.assertFalse(planner.covers_jobs(old_jobs, required, sha))


class MembershipManagementNativeBoundaryTests(unittest.TestCase):
    def test_exact_owning_operations_keep_build_photos_and_both_os_runtime(self):
        selected = scope.REVIEWED_MEMBERSHIP_MANAGEMENT_SCOPE
        self.assertIn(selected, scope.SCOPES)
        expected = tuple("NekoWidgetUITests/SoloMemoriesUITests/" + method for method in (
            "testMembershipOfferPreviewReturnsToPurpose",
            "testMembershipOfferPreviewWaitingAndRestore",
            "testMembershipOfferExplainsExpiryWithoutChangingThePlan",
            "testMembershipAccessPreservesExistingMemoAndDistinguishesUnknown",
        ))
        self.assertEqual(scope.native_tests(selected), expected)
        self.assertEqual(scope.lane_tests(selected, "app-ui"), expected)
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(scope.matrix_lanes(selected), ("runtime",))
        self.assertEqual(scope.app_ui_lanes(selected), ("app-ui",))
        self.assertEqual(scope.smoke_tests(selected), (
            "NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",
            "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary",
        ))
        required = planner.required_jobs_from_scope(selected)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE,
            scope.lane_job(selected, "runtime"), scope.lane_job(selected, "app-ui")))
        # The unchanged runtime lane still executes the existing two-OS matrix.
        self.assertEqual(scope.SHARING_JOB_PREFIX, "Sharing runtime self-test (iOS 18.5 / 26.2)")
        source = (ROOT / scope.MEMORY_TEST_PATH).read_text(encoding="utf-8")
        self.assertTrue(scope.memory_tests_available(source, expected))
        for lane in ("gallery-normal", "gallery-variants", "app-ui-solo-1", "app-ui-other"):
            with self.assertRaises(ValueError): scope.lane_tests(selected, lane)

    def test_exact_paths_reject_partial_or_shared_and_keep_old_scope_inventory(self):
        selected = scope.REVIEWED_MEMBERSHIP_MANAGEMENT_SCOPE
        self.assertEqual(scope.MEMBERSHIP_MANAGEMENT_PATHS, frozenset({
            "NekoWidget/NekoWidget/Services/MembershipOfferModel.swift",
            "NekoWidget/NekoWidget/Views/MembershipOfferView.swift",
            "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift",
        }))
        paths = scope.MEMBERSHIP_MANAGEMENT_PATHS | scope.MEMBERSHIP_MANAGEMENT_COMPANIONS
        self.assertTrue(scope.accepts_paths(selected, paths))
        self.assertTrue(scope.accepts_paths(selected, scope.MEMBERSHIP_MANAGEMENT_PATHS))
        self.assertTrue(scope.accepts_paths(selected, paths | {"handoffs/member.md"}))
        for path in paths:
            self.assertFalse(scope.accepts_paths(selected, paths - {path}), path)
            self.assertEqual(planner.required_jobs(sorted(paths - {path}), selected), planner.FULL)
        for extra in ("NekoWidget/Shared/MembershipAccessPolicy.swift", "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                      "NekoWidget/NekoWidget.xcodeproj/project.pbxproj", scope.CI_WORKFLOW):
            self.assertFalse(scope.accepts_paths(selected, paths | {extra}))
            self.assertEqual(planner.required_jobs(sorted(paths | {extra}), selected), planner.FULL)
        self.assertFalse(scope.accepts_paths(selected, None))
        self.assertFalse(scope.accepts_paths(selected, []))
        self.assertEqual(len(scope.native_tests(scope.BILLING_LOCAL_PREPARATION_SCOPE)), 3)
        self.assertEqual(scope.lanes(scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE), ("runtime", "app-ui"))
        self.assertNotIn(scope.GALLERY_TEST, scope.native_tests(selected))

    def test_release_evidence_requires_all_four_successful_same_sha_jobs(self):
        selected, sha = scope.REVIEWED_MEMBERSHIP_MANAGEMENT_SCOPE, "a" * 40
        required = planner.required_jobs_from_scope(selected)
        jobs = [{"name": name, "head_sha": sha, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, sha))
        self.assertFalse(planner.covers_jobs(jobs, planner.FULL, sha))
        self.assertFalse(planner.covers_jobs(jobs, required, "b" * 40))
        for index in range(len(jobs)):
            self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, sha))
            for conclusion in ("failure", "skipped", "cancelled", None):
                changed = copy.deepcopy(jobs); changed[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(changed, required, sha), (index, conclusion))
        old = planner.required_jobs_from_scope(scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE)
        old_jobs = [{"name": name, "head_sha": sha, "status": "completed", "conclusion": "success"} for name in old]
        self.assertFalse(planner.covers_jobs(old_jobs, required, sha))


class PrivateAppDataGalleryBoundaryTests(unittest.TestCase):
    """Replay the shipped incident, with no Xcode, CI, network or new release."""

    @classmethod
    def setUpClass(cls):
        cls.base = "58ce6d9688c160384607d03d8ff3d357cdc45216"
        cls.head = "a06d30432900e8b27709046d0a6c53250d2cc736"
        cls.paths = [path for path in planner.git("diff", "--name-only", "--no-renames", "-z", cls.base, cls.head).split("\0") if path]
        cls.raw = planner.git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", cls.base, cls.head)
        records = cls.raw.split("\0")
        cls.added = {records[i + 1] for i in range(0, len(records) - 1, 2) if records[i].split()[4] == "A"}
        cls.changes = {path: ("" if path in cls.added else planner.git("show", f"{cls.base}:{path}"),
                              planner.git("show", f"{cls.head}:{path}"))
                       for path in cls.paths if not scope.is_handoff(path)}
        cls.project = cls.changes[scope.APP_DATA_PROJECT][1]

    def replay(self, raw=None):
        original_git = planner.git
        def git(*args):
            return raw if args[0] == "diff" and raw is not None else original_git(*args)
        with patch.object(planner, "comparison_base", return_value=self.base), patch.object(planner, "git", side_effect=git):
            return planner.runtime_scope(self.paths, {}, {"GITHUB_SHA": self.head})

    def test_actual_weight_and_veterinary_batch_omits_only_gallery(self):
        self.assertEqual(self.replay(), scope.APP_DATA_SCOPE)
        self.assertEqual(scope.select_scope(self.changes), scope.APP_DATA_SCOPE)
        required = planner.required_jobs(self.paths, scope.APP_DATA_SCOPE)
        self.assertEqual(len(required), 6)
        self.assertEqual(required[:2], (planner.BUILD, planner.SMOKE))
        self.assertEqual(scope.lanes(scope.APP_DATA_SCOPE),
                         ("runtime", "app-ui-solo-1", "app-ui-solo-2", "app-ui-other"))
        self.assertEqual(scope.native_tests(scope.APP_DATA_SCOPE),
                         tuple(test for test in scope.native_tests(scope.FULL_SCOPE) if test != scope.GALLERY_TEST))
        self.assertEqual(scope.smoke_tests(scope.APP_DATA_SCOPE), scope.smoke_tests(scope.FULL_SCOPE))
        for lane in scope.LANES[2:]:
            with self.assertRaises(ValueError):
                scope.lane_tests(scope.APP_DATA_SCOPE, lane)

    def test_billing_local_preparation_requires_exact_review_and_project_proof(self):
        expected_products = {
            "NekoWidget/NekoWidget/Services/BillingFreshAccountAuthorization.swift",
            "NekoWidget/NekoWidget/Services/BillingKeychainStore.swift",
            "NekoWidget/NekoWidget/Services/MembershipOfferModel.swift",
        }
        self.assertEqual(scope.BILLING_LOCAL_PREPARATION_PRODUCTS, expected_products)
        self.assertEqual(set(scope.BILLING_LOCAL_PREPARATION_DIGESTS), expected_products | {
            scope.MEMORY_TEST_PATH, "NekoWidget/ci/test-billing-client-foundation.py"})
        changes = {path: ("old " + path, "new " + path)
                   for path in scope.BILLING_LOCAL_PREPARATION_DIGESTS}
        self.assertFalse(scope.app_data_changes(changes, project_source=self.project))
        digests = {path: tuple(map(scope.source_digest, pair)) for path, pair in changes.items()}
        with patch.object(scope, "BILLING_LOCAL_PREPARATION_DIGESTS", digests):
            self.assertFalse(scope.app_data_changes(changes))
            self.assertTrue(scope.app_data_changes(changes, project_source=self.project))
            for path in changes:
                modified = dict(changes)
                modified[path] = (modified[path][0], modified[path][1] + " unreviewed")
                self.assertFalse(scope.app_data_changes(modified, project_source=self.project))
                missing = {key: value for key, value in changes.items() if key != path}
                self.assertFalse(scope.app_data_changes(missing, project_source=self.project))
            for path in ("NekoWidget/Shared/MembershipAccessPolicy.swift",
                         "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
                         "NekoWidget/NekoWidget/Services/ManagedPreservationClient.swift"):
                self.assertFalse(scope.app_data_changes(changes | {path: ("old", "new")}, project_source=self.project))
        # Existing app-data jobs still retain all product boundary checks;
        # this change does not alter tests, execution commands or release gates.
        required = planner.required_jobs_from_scope(scope.APP_DATA_SCOPE)
        self.assertIn(planner.BUILD, required)
        self.assertIn(planner.SMOKE, required)
        self.assertEqual(scope.lanes(scope.APP_DATA_SCOPE),
                         ("runtime", "app-ui-solo-1", "app-ui-solo-2", "app-ui-other"))

    def test_exact_billing_preparation_requires_all_three_owning_operations(self):
        selected = scope.BILLING_LOCAL_PREPARATION_SCOPE
        self.assertIn(selected, scope.SCOPES)
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(scope.native_tests(selected), (
            "NekoWidgetUITests/SoloMemoriesUITests/testMembershipOfferPreviewReturnsToPurpose",
            "NekoWidgetUITests/SoloMemoriesUITests/testMembershipOfferPreviewWaitingAndRestore",
            "NekoWidgetUITests/SoloMemoriesUITests/testMembershipOfferExplainsExpiryWithoutChangingThePlan",
        ))
        required = planner.required_jobs_from_scope(selected)
        self.assertEqual(set(required), {planner.BUILD, planner.BOOTSTRAP_SMOKE,
            scope.lane_job(selected, "runtime"), scope.lane_job(selected, "app-ui")})
        self.assertEqual(scope.smoke_tests(selected), scope.smoke_tests(scope.REVIEWED_MEMBERSHIP_OFFER_SCOPE))
        paths = set(scope.BILLING_LOCAL_PREPARATION_DIGESTS)
        self.assertTrue(scope.accepts_paths(selected, paths))
        for path in paths:
            self.assertFalse(scope.accepts_paths(selected, paths - {path}))
        self.assertFalse(scope.accepts_paths(selected, paths | {"NekoWidget/Shared/MembershipAccessPolicy.swift"}))
        for lane in ("app-ui-solo-1", "app-ui-other", "gallery", "gallery-variants", "gallery-normal"):
            with self.assertRaises(ValueError):
                scope.lane_tests(selected, lane)

    def test_later_private_store_edit_needs_project_proof_not_frozen_product_hashes(self):
        path = "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift"
        changes = {path: (self.changes[path][1], self.changes[path][1] + "\n// private storage change\n")}
        self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        self.assertEqual(scope.select_scope(changes, project_source=self.project), scope.APP_DATA_SCOPE)
        self.assertFalse(scope.app_data_changes(changes, project_source="unparseable project"))

    def test_render_cache_shared_model_startup_and_unknown_inputs_cannot_borrow_exclusion(self):
        for path in (
            "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
            "NekoWidget/Shared/Models/WidgetRenderPlan.swift",
            "NekoWidget/Shared/Storage/PersonalRediscoveryStore.swift",
            "NekoWidget/NekoWidget/Services/CanonicalPreviewBuilder.swift",
            "NekoWidget/NekoWidget/Services/WidgetCacheBuilder.swift",
            "NekoWidget/NekoWidget/Services/PersonalWidgetBackgroundRefresh.swift",
            "NekoWidget/NekoWidget/App/NekoWidgetApp.swift",
            "NekoWidget/NekoWidget/Services/AppStoreScreenshotFixture.swift",
            "NekoWidget/NekoWidget/Services/NewPrivateStore.swift",
            "NekoWidget/NekoWidgetUITests/WidgetPlacementScreenshotUITests.swift",
            "NekoWidget/ci/run-sharing-runtime-matrix.sh", ".github/workflows/testflight.yml",
        ):
            with self.subTest(path=path):
                self.assertEqual(scope.select_scope(self.changes | {path: ("before", "after")}), scope.FULL_SCOPE)

    def test_app_registration_does_not_allow_widget_settings_aliases_or_framework_changes(self):
        before, after = self.changes[scope.APP_DATA_PROJECT]
        self.assertTrue(scope.app_data_project_unchanged(before, after))
        for changed in (
            after.replace('SWIFT_VERSION = 5.0', 'SWIFT_VERSION = 6.0', 1),
            after.replace('isa = PBXFrameworksBuildPhase', 'isa = ChangedFrameworksBuildPhase', 1),
            after.replace('fileRef = F00000000000000000000314', 'fileRef = D02609300000000000000002', 1),
            after.replace('path = VeterinaryVisitView.swift', 'path = NekoWidgetView.swift', 1),
            after.replace('A00000000000000000000025 /* Sources */ = {',
                          'A00000000000000000000025 /* Sources */ = {\n// unreviewed registration'),
        ):
            self.assertNotEqual(after, changed)
            self.assertFalse(scope.app_data_project_unchanged(before, changed))
            changes = self.changes | {scope.APP_DATA_PROJECT: (before, changed)}
            self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)

    def test_widget_membership_is_resolved_from_ids_not_filename_comments(self):
        path = "NekoWidget/NekoWidget/Services/PhotoMemoryNoteStore.swift"
        changes = {path: self.changes[path]}
        # Keep the misleading Widget-view comment, point the build entry at a
        # private store. Gallery must run even when the comment was not edited.
        changed = self.project.replace('fileRef = F00000000000000000000314',
                                       'fileRef = D02609300000000000000002', 1)
        self.assertNotEqual(self.project, changed)
        self.assertEqual(scope.select_scope(changes, project_source=changed), scope.FULL_SCOPE)

    def test_workflow_exception_is_additive_model_check_only(self):
        before, after = self.changes[scope.CI_WORKFLOW]
        for changed in (after.replace('contents: read', 'contents: write', 1),
                        after.replace('ci/verify-photo-memory-notes.swift', 'ci/unreviewed.swift', 1),
                        after.replace(scope.APP_DATA_MODEL_CHECK, ''),
                        after + '\n# other workflow change\n'):
            self.assertFalse(scope.app_data_changes(self.changes | {scope.CI_WORKFLOW: (before, changed)}))
        diagnostic = self.changes[scope.APP_DATA_DIAGNOSTIC][1]
        self.assertFalse(scope.app_data_changes(self.changes | {scope.APP_DATA_DIAGNOSTIC: ('', diagnostic + '\n# changed\n')}))

    def test_raw_modes_additions_deletions_and_hidden_extra_files_fail_closed(self):
        records = self.raw.split("\0")
        for i in range(0, len(records) - 1, 2):
            path = records[i + 1]
            if scope.is_handoff(path):
                continue
            for modes, status in ((":100644 100755", "M"), (":100644 120000", "T"),
                                  (":100644 000000", "D"), (":100644 100644", "R100")):
                changed = list(records)
                fields = changed[i].split()
                changed[i] = f"{modes} {fields[2]} {fields[3]} {status}"
                with self.subTest(path=path, modes=modes, status=status):
                    self.assertEqual(self.replay("\0".join(changed)), scope.FULL_SCOPE)
        extra = f":100644 100644 {'c' * 40} {'d' * 40} M\0unreported.swift\0"
        self.assertEqual(self.replay(self.raw + extra), scope.FULL_SCOPE)

    def test_limited_success_does_not_cover_full_or_skipped_storage_build_checks(self):
        required = planner.required_jobs_from_scope(scope.APP_DATA_SCOPE)
        jobs = [dict(name=name, head_sha=self.head, status="completed", conclusion="success") for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.head))
        self.assertFalse(planner.covers_jobs(jobs, planner.FULL, self.head))
        for index in range(len(jobs)):
            for conclusion in ("skipped", "failure", "cancelled"):
                changed = copy.deepcopy(jobs); changed[index]["conclusion"] = conclusion
                self.assertFalse(planner.covers_jobs(changed, required, self.head))


class DiagnosticRouteBoundaryTests(unittest.TestCase):
    def test_window_diagnostic_selects_only_existing_requested_methods(self):
        source = (ROOT / "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift").read_text(encoding="utf-8")
        methods = ("testMixedWindowsKeepAdditionAndScopedRecoveryReachable",
                   "testDiscoverReceiveGuideAndStopUpdatesWindowList",
                   "testWindowListLargeTextKeepsDiscoveryAndPhotoReachable")
        self.assertEqual(scope.diagnostic_tests("OfficialWindowUITests", ",".join(methods), source),
                         tuple("NekoWidgetUITests/OfficialWindowUITests/" + name for name in methods))
        for names in ("testUnknownWindowMethod", ",".join(methods + (methods[0],)), methods[0] + ";exit 0"):
            with self.assertRaises(ValueError):
                scope.diagnostic_tests("OfficialWindowUITests", names, source)

    def test_exact_diagnostic_addition_preserves_regular_commands(self):
        path = scope.CI_DIAGNOSTIC_MATRIX
        current = (ROOT / path).read_text(encoding="utf-8")
        pattern = r"(?m)^# BEGIN DIAGNOSTIC-ONLY [^\n]+\n[\s\S]*?^# END DIAGNOSTIC-ONLY [^\n]+\n"
        previous = re.sub(pattern, "", current)
        self.assertNotEqual(previous, current)
        self.assertTrue(scope.ci_selection_only({path: (previous, current)}))
        for changed in (current.replace('!= "workflow_dispatch"', '== "workflow_dispatch"'),
                        current.replace('CODE_SIGN_IDENTITY=-', 'CODE_SIGN_IDENTITY=modified')):
            self.assertNotEqual(current, changed)
            self.assertFalse(scope.ci_selection_only({path: (previous, changed)}))

    def test_diagnostic_workflow_is_exact_and_never_release_evidence(self):
        path = scope.CI_DIAGNOSTIC_WORKFLOW
        current = (ROOT / path).read_text(encoding="utf-8")
        self.assertTrue(scope.ci_selection_only({path: ("", current)}))
        self.assertFalse(scope.ci_selection_only({path: ("", current.replace('contents: read', 'contents: write'))}))
        with self.assertRaises(ValueError):
            planner.required_jobs_from_scope("diagnostic")

    def test_only_diagnostic_push_exclusion_is_normalized(self):
        current = (ROOT / scope.CI_WORKFLOW).read_text(encoding="utf-8")
        previous = current.replace('    # Manual diagnostic runs use a separate workflow and are not release evidence.\n'
                                   '    branches-ignore:\n      - "diagnostic/**"\n', '')
        self.assertNotEqual(current, previous)
        self.assertEqual(scope.workflow_execution(previous), scope.workflow_execution(current))
        self.assertNotEqual(scope.workflow_execution(previous), scope.workflow_execution(current.replace('"diagnostic/**"', '"**"')))

WIDGET = "NekoWidget/NekoWidgetWidget/"
BEHAVIOR_PATHS = frozenset(WIDGET + name for name in (
    "NekoWidgetEntry.swift", "NekoWidgetTimelineProvider.swift", "WidgetManifestReader.swift",
    "DailyPersonalPhotoIntent.swift", "ToggleWidgetLikeIntent.swift", "NekoWidgetConfigurationIntent.swift",
)) | {
    "NekoWidget/Shared/Storage/PersonalRediscoveryStore.swift",
    "NekoWidget/NekoWidget/Views/PersonalRediscoveryHistoryView.swift",
    "NekoWidget/NekoWidget/Services/PersonalWidgetBackgroundRefresh.swift",
}
LAYOUT_PATHS = frozenset(WIDGET + name for name in ("NekoWidgetView.swift", "WidgetCacheImageLoader.swift"))
UI_TESTS = frozenset("NekoWidgetUITests/" + identifier for identifier in (
    "OfficialWindowUITests/testWidgetURLsColdOpenPhotoBeforeSourceResolvesAndCloseOnce",
    "OfficialWindowUITests/testWidgetURLsActiveAppReplacesPhotosAndRestoresPresentations",
    "OfficialWindowUITests/testWidgetURLsMissingPhotoNeverSubstituteAvailableFixturePhoto",
    "PersonalRediscoveryUITests/testDailyTurnKeepsYesterdayAndPreviousPhotoWithExistingPhotoActions",
    "PersonalRediscoveryUITests/testOneCandidateShowsPhotoWithoutSpendingADailyTurn",
    "SoloMemoriesUITests/testWidgetPhotoOutsideCurrentScopeOffersAPathBack",
    "MomentDeliveryComposerUITests/testReceivedProductControlsBindRequestsAndPendingStateToTheVisiblePhoto",
))
CHANGE = ("return currentPhoto\n", "return nextPhoto\n")


class WidgetScopeTests(unittest.TestCase):
    @staticmethod
    def photo_source_check_blocks():
        pairs = (
            ('accessibilityIdentifier("albums-favorites")', 'accessibilityIdentifier("saved-memories-gallery")'),
            (r'accessibilityLabel("お気に入り、\(photos.count.formatted())枚")',
             r'accessibilityValue("お気に入り、\(photos.count.formatted())枚")'),
        )
        target = "            NekoWidget/Views/LikedPhotosView.swift\n"
        return [(old, new, f"\n          grep -Fq '{old}' \\\n" + target,
                 "\n          grep -Fq \\\n" + f"            -e '{old}' \\\n"
                 + f"            -e '{new}' \\\n" + target) for old, new in pairs]

    @classmethod
    def photo_source_check_workflow_fixture(cls):
        # Freeze the historical grep contract independently of the live workflow.
        # The new helper checker is a different execution change, tested below.
        return ("name: Historical photo source checks\n"
                "permissions:\n  contents: read\n"
                "jobs:\n  build:\n    steps:\n"
                "      - name: Check photo source\n        run: |\n"
                "          set -euo pipefail\n"
                + "".join(compatible for _, _, _, compatible in cls.photo_source_check_blocks())
                + "\n          grep -Fq 'LikedPhotoOrderingPolicy.comesBefore(' \\\n"
                  "            NekoWidget/App/AppRootView.swift\n")

    def test_exact_photo_source_check_upgrade_keeps_ci_selection_and_required_jobs(self):
        workflow = self.photo_source_check_workflow_fixture()
        legacy = workflow
        for _, _, old, compatible in self.photo_source_check_blocks():
            self.assertEqual(workflow.count(compatible), 1)
            legacy = legacy.replace(compatible, old)
        self.assertNotEqual(legacy, workflow)
        changes = {scope.CI_WORKFLOW: (legacy, workflow)}
        selected = scope.select_scope(changes)
        self.assertEqual(selected, scope.CI_SELECTION_SCOPE)
        self.assertEqual(planner.required_jobs(list(changes), selected),
                         planner.required_jobs_from_scope(scope.CI_SELECTION_SCOPE))
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui", "gallery-normal"))
        self.assertEqual(set(scope.lane_tests(selected, "app-ui")), UI_TESTS)
        self.assertIn(planner.BUILD, planner.required_jobs_from_scope(selected))
        self.assertIn(planner.BOOTSTRAP_SMOKE, planner.required_jobs_from_scope(selected))
        # A product change cannot borrow the CI-only exception.
        self.assertEqual(scope.select_scope(dict(changes, **{
            "NekoWidget/NekoWidget/Views/LikedPhotosView.swift": CHANGE})), scope.FULL_SCOPE)

    def test_photo_source_check_exception_rejects_removed_alternatives_and_unrelated_commands(self):
        workflow = self.photo_source_check_workflow_fixture()
        for old, new, legacy, compatible in self.photo_source_check_blocks():
            self.assertEqual(workflow.count(compatible), 1)
            variants = (
                legacy, legacy.replace(old, new),  # Neither one-sided rollback is equivalent.
                compatible.replace("Views/LikedPhotosView.swift", "Views/HomeView.swift"),
                compatible.replace("grep -Fq", "grep -Fqv"),
                compatible.replace(new, 'accessibilityIdentifier("unknown")'),
                compatible.rstrip("\n") + " || true\n",
                compatible + compatible,
                "\n",
            )
            for replacement in variants:
                with self.subTest(replacement=replacement):
                    changed = workflow.replace(compatible, replacement)
                    self.assertNotEqual(changed, workflow)
                    self.assertEqual(scope.select_scope({scope.CI_WORKFLOW: (workflow, changed)}),
                                     scope.FULL_SCOPE)
                    before = workflow.replace(compatible, legacy)
                    self.assertNotEqual(before, workflow)
                    # A different command/path may not hitchhike on an upgrade.
                    if replacement != legacy:
                        self.assertNotEqual(before, changed)
                        self.assertEqual(scope.select_scope({scope.CI_WORKFLOW: (before, changed)}),
                                         scope.FULL_SCOPE)
        changed = workflow.replace('grep -Fq', 'grep -Fqv', 1)
        self.assertNotEqual(changed, workflow)
        self.assertEqual(scope.select_scope({scope.CI_WORKFLOW: (workflow, changed)}), scope.FULL_SCOPE)

    def test_new_photo_source_helper_checker_requires_full_scope(self):
        workflow = (ROOT / scope.CI_WORKFLOW).read_text(encoding="utf-8")
        pattern = (r"(?m)\n          # Favorites accessibility normal/recovery contract\n"
                   r"          python3 - <<'PY'\n[\s\S]*?^          PY\n")
        checkers = re.findall(pattern, workflow)
        self.assertEqual(len(checkers), 1)
        compatible = self.photo_source_check_blocks()[1][3]
        self.assertNotIn(compatible, workflow)
        previous = workflow.replace(checkers[0], compatible, 1)
        self.assertNotEqual(previous, workflow)
        self.assertEqual(previous.count(compatible), 1)
        changes = {scope.CI_WORKFLOW: (previous, workflow)}
        self.assertFalse(scope.ci_selection_only(changes))
        self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
        self.assertEqual(planner.required_jobs(list(changes), scope.FULL_SCOPE), planner.FULL)

    def test_compatible_source_checks_accept_old_or_new_but_not_missing_values(self):
        git_bash = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
        bash = str(git_bash) if os.name == "nt" and git_bash.is_file() else shutil.which("bash")
        self.assertIsNotNone(bash)
        with tempfile.TemporaryDirectory(prefix="neko-photo-source-") as directory:
            target = Path(directory) / "NekoWidget/Views/LikedPhotosView.swift"
            target.parent.mkdir(parents=True)
            for old, new, _, compatible in self.photo_source_check_blocks():
                for value, expected in ((old, 0), (new, 0), ("unrelated", 1)):
                    with self.subTest(value=value):
                        target.write_text(value + "\n", encoding="utf-8")
                        result = subprocess.run([bash, "-c", compatible.strip()], cwd=directory,
                                                capture_output=True, timeout=10)
                        self.assertEqual(result.returncode, expected, result.stderr)

    def widget_scopes(self):
        return (scope.WIDGET_BEHAVIOR_SCOPE, scope.WIDGET_LAYOUT_SCOPE, scope.WIDGET_STYLE_SCOPE,
                scope.CI_SELECTION_SCOPE)

    def test_ci_selection_requires_unchanged_build_security_and_smoke_execution(self):
        workflow = (ROOT / scope.CI_WORKFLOW).read_text(encoding="utf-8")
        previous = workflow.replace(
            "      max-parallel: ${{ fromJSON(needs.plan.outputs.matrix_parallelism) }}",
            "      max-parallel: 2")
        self.assertEqual(scope.select_scope({scope.CI_WORKFLOW: (previous, workflow)}), scope.CI_SELECTION_SCOPE)
        for before, after in (("contents: read", "contents: write"),
                              ("CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_ALLOWED=YES"),
                              ("ci/verify-personal-rediscovery.swift", "ci/skip-check.swift")):
            self.assertIn(before, workflow)
            self.assertEqual(scope.select_scope({scope.CI_WORKFLOW: (workflow, workflow.replace(before, after))}),
                             scope.FULL_SCOPE)
        smoke = (ROOT / scope.CI_SMOKE_SCRIPT).read_text(encoding="utf-8")
        original = re.sub(r"# BEGIN CI_SMOKE_SELECTION[\s\S]*?# END CI_SMOKE_SELECTION", "", smoke)
        original = original.replace('    "${SMOKE_TEST_ARGUMENTS[@]}" \\',
            '    -only-testing:NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess \\\n'
            '    -only-testing:NekoWidgetUITests/OfficialWindowUITests \\\n'
            '    -only-testing:NekoWidgetUITests/PersonalRediscoveryUITests \\')
        self.assertEqual(scope.select_scope({scope.CI_SMOKE_SCRIPT: (original, smoke)}), scope.CI_SELECTION_SCOPE)
        altered = smoke.replace("PERMISSION_TEST_STATUS=0", "PERMISSION_TEST_STATUS=1")
        self.assertNotEqual(altered, smoke)
        self.assertEqual(scope.select_scope({scope.CI_SMOKE_SCRIPT: (smoke, altered)}), scope.FULL_SCOPE)
        self.assertEqual(scope.select_scope({scope.CI_WORKFLOW: (previous, workflow), WIDGET + "DailyPersonalPhotoIntent.swift": CHANGE}),
                         scope.FULL_SCOPE)

    def test_ci_python_regressions_need_no_native_checks_or_current_main_ancestor(self):
        sha = "a" * 40
        env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/codex/ci", "GITHUB_SHA": sha}
        new_test = "NekoWidget/ci/test-widget-ci-scope.py"
        def git(*args):
            if args[:1] == ("diff",):
                return f":000000 100644 {'0' * 40} {'b' * 40} A\0{new_test}\0"
            if args[:1] == ("show",):
                self.assertEqual(args[1], f"{sha}:{new_test}")
                return "# named selector regression test\n"
            return sha
        with patch.object(planner, "git", side_effect=git) as calls:
            self.assertEqual(planner.runtime_scope([new_test], {}, env), planner.ORCHESTRATION_SCOPE)
        def stale(*args):
            if args[:2] == ("merge-base", "--is-ancestor"):
                raise subprocess.CalledProcessError(1, "git")
            return git(*args)
        with patch.object(planner, "git", side_effect=stale):
            self.assertEqual(planner.runtime_scope([new_test], {}, env), planner.ORCHESTRATION_SCOPE)
        self.assertEqual(scope.select_scope({"NekoWidget/ci/unreviewed-new-test.py": ("", "new")}), scope.FULL_SCOPE)

    def jobs(self, names):
        return [{"name": name, "head_sha": "a" * 40, "status": "completed", "conclusion": "success",
                 "completed_at": "2026-09-14T01:00:00Z"} for name in names]

    def test_reviewed_paths_exist_and_behavior_changes_select_their_scope(self):
        # Exact sets make expansion of the trusted allowlist an explicit review.
        self.assertEqual(scope.WIDGET_BEHAVIOR_PATHS, BEHAVIOR_PATHS)
        self.assertEqual(scope.WIDGET_LAYOUT_PATHS, LAYOUT_PATHS)
        for paths, selected in ((BEHAVIOR_PATHS, scope.WIDGET_BEHAVIOR_SCOPE),
                                (LAYOUT_PATHS, scope.WIDGET_LAYOUT_SCOPE)):
            for path in paths:
                with self.subTest(path=path):
                    self.assertTrue((ROOT / path).is_file())
                    self.assertEqual(scope.select_scope({path: CHANGE}), selected)
                    self.assertEqual(planner.required_jobs([path], selected),
                                     planner.required_jobs_from_scope(selected))

    def test_literal_widget_style_does_not_include_interaction_or_fixture_changes(self):
        path = WIDGET + "NekoWidgetView.swift"
        for change in (("Text(\"Before\")", "Text(\"After\")"),
                       (".padding(.horizontal, 12)", ".padding(.horizontal, 16)")):
            with self.subTest(change=change):
                self.assertEqual(scope.select_scope({path: change}), scope.WIDGET_STYLE_SCOPE)
        for change in ((".disabled(true)", ".disabled(false)"),
                       ("Button(intent: previousIntent)", "Button(intent: nextIntent)")):
            self.assertEqual(scope.select_scope({path: change}), scope.WIDGET_LAYOUT_SCOPE)
        fixture = '#if DEBUG\nText("before")\n#endif\n'
        self.assertEqual(scope.select_scope({path: (fixture, fixture.replace("before", "after"))}),
                         scope.FULL_SCOPE)
        history = "NekoWidget/NekoWidget/Views/PersonalRediscoveryHistoryView.swift"
        self.assertEqual(scope.select_scope({history: ('Text("before")', 'Text("after")')}),
                         scope.WIDGET_BEHAVIOR_SCOPE)

    def test_common_unknown_ci_and_signing_paths_prevent_narrow_selection(self):
        widget = WIDGET + "DailyPersonalPhotoIntent.swift"
        for extra in (
            "NekoWidget/NekoWidget/App/AppViewModel.swift",
            "NekoWidget/NekoWidget/Views/MainTabView.swift",
            "NekoWidget/NekoWidget/Views/OnboardingView.swift",
            "NekoWidget/NekoWidget/Services/WidgetCacheBuilder.swift",
            "NekoWidget/NekoWidget/Services/MomentSharingCoordinator.swift",
            "NekoWidget/NekoWidget/Services/MomentSharingAPIClient.swift",
            "NekoWidget/Shared/Sharing/MomentSharingStore.swift",
            "NekoWidget/Shared/Storage/SharedLikeStore.swift",
            "NekoWidget/Shared/Models/WidgetRenderPlan.swift",
            "NekoWidget/Shared/Routing/DeepLink.swift",
            "NekoWidget/NekoWidget/Info.plist", "NekoWidget/NekoWidget/NekoWidget.entitlements",
            "NekoWidget/ci/ios_ci_scope.py", ".github/workflows/ios-build.yml", "unknown.swift",
        ):
            with self.subTest(extra=extra):
                changes = {widget: CHANGE, extra: CHANGE}
                self.assertEqual(scope.select_scope(changes), scope.FULL_SCOPE)
                self.assertEqual(planner.required_jobs(list(changes), scope.WIDGET_BEHAVIOR_SCOPE), planner.FULL)

    def test_attached_handoff_does_not_hide_source_or_create_its_own_scope(self):
        widget = WIDGET + "DailyPersonalPhotoIntent.swift"
        handoff = "handoffs/2026-09-14-widget-daily-heart.md"
        self.assertEqual(scope.select_scope({widget: CHANGE, handoff: ("before", "after")}),
                         scope.WIDGET_BEHAVIOR_SCOPE)
        self.assertEqual(scope.select_scope({handoff: ("before", "after")}), scope.FULL_SCOPE)
        self.assertEqual(scope.select_scope({widget: CHANGE, "docs/unknown.md": ("before", "after")}),
                         scope.FULL_SCOPE)

    def test_ui_selection_is_exact_and_methods_belong_to_real_test_classes(self):
        methods = {}
        for source in (ROOT / "NekoWidget/NekoWidgetUITests").glob("*.swift"):
            text = source.read_text(encoding="utf-8")
            classes = list(re.finditer(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b", text, re.MULTILINE))
            for index, match in enumerate(classes):
                end = classes[index + 1].start() if index + 1 < len(classes) else len(text)
                for method in re.findall(r"\bfunc\s+(test\w+)\s*\(", text[match.end():end]):
                    identifier = f"NekoWidgetUITests/{match.group(1)}/{method}"
                    methods[identifier] = methods.get(identifier, 0) + 1
        for selected in (scope.WIDGET_BEHAVIOR_SCOPE, scope.WIDGET_LAYOUT_SCOPE):
            selected_ui = scope.lane_tests(selected, "app-ui")
            self.assertEqual(len(selected_ui), 7)
            self.assertEqual(set(selected_ui), UI_TESTS)
            for identifier in selected_ui:
                self.assertEqual(methods.get(identifier), 1, identifier)
        # Full class selection must really include each limited method.
        full = tuple(test for lane in scope.app_ui_lanes(scope.FULL_SCOPE)
                     for test in scope.lane_tests(scope.FULL_SCOPE, lane))
        for identifier in UI_TESTS:
            self.assertTrue(any(identifier == item or identifier.startswith(item + "/") for item in full), identifier)

    def test_lane_selection_keeps_runtime_and_required_gallery_conditions(self):
        expected = {
            scope.WIDGET_BEHAVIOR_SCOPE: ("runtime", "app-ui", "gallery-normal"),
            scope.WIDGET_LAYOUT_SCOPE: ("runtime", "app-ui", "gallery-normal", "gallery-variants"),
            scope.WIDGET_STYLE_SCOPE: ("runtime", "gallery-normal", "gallery-variants"),
        }
        for selected, lanes in expected.items():
            with self.subTest(scope=selected):
                self.assertEqual(scope.lanes(selected), lanes)
                self.assertEqual(scope.matrix_lanes(selected), tuple(lane for lane in lanes if lane != "app-ui"))
                required = planner.required_jobs_from_scope(selected)
                self.assertIn(planner.BUILD, required)
                self.assertEqual(len(required), len(lanes) + 2)  # Build, real Photos smoke, and lanes.
                for lane in lanes:
                    self.assertIn(scope.lane_job(selected, lane), required)
                    if lane.startswith("gallery-"):
                        self.assertEqual(scope.lane_tests(selected, lane), scope.lane_tests(scope.FULL_SCOPE, lane))
        self.assertNotIn("app-ui", scope.lanes(scope.WIDGET_STYLE_SCOPE))

    def test_real_photos_smoke_remains_required_with_separate_execution_evidence(self):
        bootstrap = ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",
                     "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary")
        sha = "a" * 40
        for selected in scope.SCOPES:
            required = planner.required_jobs_from_scope(selected)
            if selected == scope.ICON_SCOPE:
                self.assertEqual(required, (planner.ICON_BUILD,))
                continue
            if selected == scope.OWNER_CLOUD_SCOPE:
                self.assertEqual(required, (planner.BUILD, scope.lane_job(selected, "runtime")))
                continue
            self.assertIn(planner.smoke_job(selected), required)
            if selected not in (scope.FULL_SCOPE, scope.APP_VIEW_SCOPE, scope.APP_DATA_SCOPE):
                self.assertEqual(scope.smoke_tests(selected), bootstrap)
                self.assertEqual(planner.smoke_job(selected), planner.BOOTSTRAP_SMOKE)
        for selected in (scope.FULL_SCOPE, scope.APP_VIEW_SCOPE, scope.APP_DATA_SCOPE):
            self.assertEqual(scope.smoke_tests(selected),
                             bootstrap + scope.OFFICIAL_TESTS + ("NekoWidgetUITests/PersonalRediscoveryUITests",))
            self.assertEqual(planner.smoke_job(selected), planner.SMOKE)
        self.assertTrue(planner.covers_jobs(self.jobs([planner.SMOKE]), (planner.BOOTSTRAP_SMOKE,), sha))
        self.assertFalse(planner.covers_jobs(self.jobs([planner.BOOTSTRAP_SMOKE]), (planner.SMOKE,), sha))
        self.assertFalse(planner.covers_jobs(self.jobs([planner.SMOKE, planner.BOOTSTRAP_SMOKE]),
                                            (planner.BOOTSTRAP_SMOKE,), sha))

    def test_full_evidence_covers_only_the_corresponding_limited_lane(self):
        sha = "a" * 40
        full_jobs = self.jobs(planner.FULL)
        for selected in self.widget_scopes():
            required = planner.required_jobs_from_scope(selected)
            limited = self.jobs(required)
            self.assertTrue(planner.covers_jobs(limited, required, sha))
            self.assertTrue(planner.covers_jobs(full_jobs, required, sha))
            self.assertFalse(planner.covers_jobs(limited, planner.FULL, sha))
            for lane in scope.lanes(selected):
                with self.subTest(scope=selected, lane=lane):
                    limited_name = scope.lane_job(selected, lane)
                    full_names = ([scope.lane_job(scope.FULL_SCOPE, name)
                                   for name in scope.app_ui_lanes(scope.FULL_SCOPE)]
                                  if lane == "app-ui" else [scope.lane_job(scope.FULL_SCOPE, lane)])
                    self.assertTrue(planner.covers_jobs(self.jobs(full_names), (limited_name,), sha))
                    for other in scope.lanes(scope.FULL_SCOPE):
                        if scope.lane_job(scope.FULL_SCOPE, other) not in full_names:
                            wrong_lane = scope.lane_job(scope.FULL_SCOPE, other)
                            self.assertFalse(planner.covers_jobs(self.jobs([wrong_lane]), (limited_name,), sha))

    def test_failed_skipped_duplicate_or_missing_required_evidence_never_reuses(self):
        sha = "a" * 40
        for selected in self.widget_scopes():
            required = planner.required_jobs_from_scope(selected)
            jobs = self.jobs(required)
            for index, name in enumerate(required):
                with self.subTest(scope=selected, job=name):
                    for conclusion in ("failure", "skipped", "cancelled", None):
                        changed = copy.deepcopy(jobs)
                        changed[index]["conclusion"] = conclusion
                        self.assertFalse(planner.covers_jobs(changed, required, sha))
                    self.assertFalse(planner.covers_jobs(jobs[:index] + jobs[index + 1:], required, sha))
                    self.assertFalse(planner.covers_jobs(jobs + [jobs[index]], required, sha))
            for lane in scope.lanes(selected):
                covering = (scope.app_ui_lanes(scope.FULL_SCOPE) if lane == "app-ui" else (lane,))
                duplicate_coverage = jobs + self.jobs([scope.lane_job(scope.FULL_SCOPE, name) for name in covering])
                self.assertFalse(planner.covers_jobs(duplicate_coverage, required, sha))
            self.assertFalse(planner.covers_jobs(jobs, required, "b" * 40))


class LostCatSavedInfoBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Exercise the structural fallback without importing historical commits.
        # Exact snapshot digest-gate logic is covered separately below; this
        # fixture does not claim to verify the original snapshot bytes.
        before = Path(__file__).with_name("fixtures").joinpath(
            "lost-cat-ux-legacy-store.swift").read_text(encoding="utf-8")
        method = ("    func removePhoto(_ role: CatPreparednessStore.PhotoRole,\n"
                  "                     draft: LostCatDraft, for key: String) throws -> LostCatDraft {\n"
                  "        var updated = draft\n"
                  "        if role == .face { updated.faceFileName = nil }\n"
                  "        else { updated.bodyFileName = nil }\n"
                  "        try save(updated, for: key)\n"
                  "        return updated\n"
                  "    }\n\n")
        after = before.replace("    func image(_ name:", method + "    func image(_ name:", 1)
        before_tests = """import XCTest
final class SoloMemoriesUITests: XCTestCase {
    @MainActor
    func testUnpreparedLostCatDraftPreviewsAndCreatesImageAndPDF() {
        XCTAssertTrue(true)
    }
    @MainActor
    func testLostCatDraftOffersThisCatsPhotosBeforeEntireLibrary() {
        XCTAssertTrue(true)
    }
}
"""
        after_tests = before_tests.replace(
            "\n}\n", "\n    @MainActor\n"
            "    func testLostCatPhotoTapSelectsOnlyTheTappedCandidate() {\n"
            "        XCTAssertTrue(true)\n    }\n}\n", 1)
        cls.changes = {
            scope.LOST_CAT_STORE_PATH: (before, after),
            scope.LOST_CAT_PHOTO_PATH: ("struct Before {}", "struct After {}"),
            scope.MEMORY_TEST_PATH: (before_tests, after_tests),
        }

    def test_exact_snapshot_digest_gate_requires_ordered_unchanged_pair(self):
        # Dedicated sentinel strings cannot pass structural validation. Map
        # their digests only within this test to cover the fixed-pair gate.
        before, after = "snapshot-before-sentinel", "snapshot-after-sentinel"
        self.assertFalse(scope.lost_cat_store_changes(before, after))
        digest = scope.source_digest
        digests = dict(zip((before, after), scope.LOST_CAT_SAVED_INFO_STORE_DIGESTS))
        with patch.object(scope, "source_digest", side_effect=lambda source:
                          digests.get(source, digest(source))):
            self.assertTrue(scope.lost_cat_store_changes(before, after))
            for pair in ((after, before), (before + " changed", after),
                         (before, after + " changed"), ("unknown-before", "unknown-after")):
                with self.subTest(pair=pair):
                    self.assertFalse(scope.lost_cat_store_changes(*pair))

    def test_reviewed_store_keeps_existing_lost_cat_checks_without_gallery(self):
        self.assertEqual(scope.select_scope(self.changes), scope.LOST_CAT_UX_SCOPE)
        self.assertEqual(set(self.changes), {scope.LOST_CAT_STORE_PATH, scope.LOST_CAT_PHOTO_PATH, scope.MEMORY_TEST_PATH})
        self.assertEqual(scope.native_tests(scope.LOST_CAT_UX_SCOPE), scope.LOST_CAT_PHOTO_TESTS)
        required = planner.required_jobs(list(self.changes), scope.LOST_CAT_UX_SCOPE)
        self.assertEqual(len(required), 4)
        self.assertEqual(required[:2], (planner.BUILD, planner.smoke_job(scope.LOST_CAT_UX_SCOPE)))
        self.assertEqual(scope.lanes(scope.LOST_CAT_UX_SCOPE), ("runtime", "app-ui"))
        self.assertFalse(any("gallery" in job for job in required))

    def test_unknown_store_input_or_mixed_companion_cannot_borrow_review(self):
        modified = dict(self.changes)
        before, after = modified[scope.LOST_CAT_STORE_PATH]
        modified[scope.LOST_CAT_STORE_PATH] = (before, after + "\nstruct ExtraStore {}\n")
        self.assertNotEqual(scope.select_scope(modified), scope.LOST_CAT_UX_SCOPE)
        for path in ("NekoWidget/NekoWidget/Services/EvacuationStore.swift",
                     "NekoWidget/ci/ios_ci_scope.py", "NekoWidget/NekoWidget.xcodeproj/project.pbxproj",
                     "NekoWidget/NekoWidgetWidget/NekoWidget.swift"):
            with self.subTest(path=path):
                mixed = dict(self.changes); mixed[path] = ("before", "after")
                self.assertNotEqual(scope.select_scope(mixed), scope.LOST_CAT_UX_SCOPE)
        self.assertIn("static let schemaVersion = 1", before)
        self.assertFalse(scope.lost_cat_store_changes(
            before.replace("static let schemaVersion = 1", "static let schemaVersion = 2"), after))


class VetSavedCatBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = "59dad7942f6836d35a005c167bc94dae11757991"
        cls.head = "f888f590ff0afcd63523521496b7407d5dc3b2db"
        cls.paths = [path for path in planner.git("diff", "--name-only", "--no-renames", "-z", cls.base, cls.head).split("\0") if path]
        cls.changes = {path: (planner.git("show", f"{cls.base}:{path}"), planner.git("show", f"{cls.head}:{path}"))
                       for path in cls.paths if not scope.is_handoff(path)}

    def test_real_candidate_selects_only_vet_weight_cases_and_required_boundaries(self):
        self.assertEqual(set(self.changes), scope.VET_SAVED_CAT_PATHS)
        self.assertEqual(scope.select_scope(self.changes), scope.VET_SAVED_CAT_SCOPE)
        with patch.object(planner, "comparison_base", return_value=self.base):
            self.assertEqual(planner.runtime_scope(self.paths, {}, {"GITHUB_SHA": self.head}), scope.VET_SAVED_CAT_SCOPE)
        self.assertEqual(len(scope.VET_SAVED_CAT_TESTS), 3)
        self.assertEqual(scope.native_tests(scope.VET_SAVED_CAT_SCOPE), scope.VET_SAVED_CAT_TESTS)
        required = planner.required_jobs(self.paths, scope.VET_SAVED_CAT_SCOPE)
        self.assertEqual(required, (planner.BUILD, planner.BOOTSTRAP_SMOKE) + scope.sharing_jobs(scope.VET_SAVED_CAT_SCOPE))
        self.assertEqual(len(required), 4)
        self.assertEqual(scope.lanes(scope.VET_SAVED_CAT_SCOPE), ("runtime", "app-ui"))
        self.assertEqual(scope.smoke_tests(scope.VET_SAVED_CAT_SCOPE),
                         ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",
                          "NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary"))
        self.assertFalse(any("gallery" in job for job in required))

    def test_no_unknown_product_or_control_input_can_borrow_review(self):
        for path in self.changes:
            for side in (0, 1):
                altered = dict(self.changes); pair = list(altered[path]); pair[side] += "\n// unreviewed"
                altered[path] = tuple(pair)
                self.assertNotEqual(scope.select_scope(altered), scope.VET_SAVED_CAT_SCOPE)
            incomplete = dict(self.changes); del incomplete[path]
            self.assertNotEqual(scope.select_scope(incomplete), scope.VET_SAVED_CAT_SCOPE)
        for path in ("NekoWidget/NekoWidget/Services/CareHandoffStore.swift", "NekoWidget/Shared/Storage/AtomicJSON.swift",
                     "NekoWidget/ci/ios_ci_scope.py", ".github/workflows/ios-build.yml",
                     "NekoWidget/NekoWidget.xcodeproj/project.pbxproj", "NekoWidget/NekoWidgetWidget/NekoWidget.swift"):
            altered = dict(self.changes); altered[path] = ("before", "after")
            self.assertNotEqual(scope.select_scope(altered), scope.VET_SAVED_CAT_SCOPE)
        # Required jobs remain same-SHA, actually executed evidence, not skips.
        required = planner.required_jobs(self.paths, scope.VET_SAVED_CAT_SCOPE)
        jobs = [{"name": name, "head_sha": self.head, "status": "completed", "conclusion": "success"} for name in required]
        self.assertTrue(planner.covers_jobs(jobs, required, self.head))
        self.assertFalse(planner.covers_jobs(jobs, required, self.base))
        self.assertFalse(planner.covers_jobs(jobs, planner.FULL, self.head))
        for index in range(len(jobs)):
            for result in ("failure", "skipped", "cancelled", None):
                changed = copy.deepcopy(jobs); changed[index]["conclusion"] = result
                self.assertFalse(planner.covers_jobs(changed, required, self.head))


class ModerationReportBplistScopeTests(unittest.TestCase):
    base, head = 'b'*40, 'a'*40

    def rows(self):
        return {path:[':100644','100644',before,after,'M']
                for path,(before,after) in planner.MODERATION_REPORT_BPLIST_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, change=None):
        import hashlib
        rows=self.rows() if rows is None else rows
        paths=list(rows) if paths is None else paths
        tree=f'100644 blob {"d"*40}\tunchanged-product.swift\0'
        def git(*args):
            if args[0]=='merge-base':
                if change=='ancestry' and '--is-ancestor' in args:raise subprocess.CalledProcessError(1,args)
                return self.base
            if args[0]=='rev-parse':return self.head if args[1]=='HEAD' else '0'*40
            if args[0]=='diff':return raw if raw is not None else ''.join(' '.join(r)+'\0'+p+'\0' for p,r in rows.items())
            if args[0]=='show':return '' if change=='registration' else 'MODERATION_REPORT_BPLIST_SCOPE = "moderation-report-bplist-width-v1"'
            if args[:3]==('ls-tree','-r','-z'):
                return tree+(f'100644 blob {"e"*40}\tprivacy.swift\0' if change=='frozen' and args[3]==self.head else '')
            if args[0]=='ls-tree':
                ref,path=args[1],args[-1]
                if path in planner.MODERATION_REPORT_BPLIST_BLOBS:
                    blob=planner.MODERATION_REPORT_BPLIST_BLOBS[path][ref==self.head]
                else:blob=('f' if change=='control' and ref==self.head else 'c')*40
                return f'100644 blob {blob}\t{path}'
            raise AssertionError(args)
        with patch.object(planner,'git',side_effect=git),patch.object(planner,'MODERATION_REPORT_BPLIST_TREE_SHA256',hashlib.sha256(tree.encode()).hexdigest()):
            return planner.runtime_scope(paths,{}, {'GITHUB_SHA':self.head,'GITHUB_EVENT_NAME':'push','GITHUB_REF':'refs/heads/codex/parser'})

    def test_exact_reviewed_two_modifications_require_current_backend_and_reject_release(self):
        selected=planner.MODERATION_REPORT_BPLIST_SCOPE
        self.assertEqual(self.select(),selected)
        self.assertEqual(planner.required_jobs(list(self.rows()),selected),planner.MODERATION_REPORT_BPLIST_JOBS)
        self.assertEqual(planner.moderation_report_bplist_requirements(self.head),[
            {'workflow':'.github/workflows/sharing-service.yml','job':job,'head_sha':self.head,'event':'push','success_required':True}
            for job in planner.MODERATION_OPERATOR_STARTUP_JOBS])
        self.assertNotIn(selected,scope.SCOPES)
        with self.assertRaises(ValueError):planner.required_jobs_from_scope(selected)
        import json
        package=json.loads((ROOT/'NekoWidget/SharingService/package.json').read_text(encoding='utf-8'))
        command=package['scripts']['check:moderation-tool']
        for name in ('moderation-report-tool','moderation-report-windows-boundary','moderation-bound-review',
                     'moderation-owner-review-host','moderation-owner-r2-transport'):
            self.assertIn(name+'.node-tests.mjs',command)
        workflow=(ROOT/'.github/workflows/sharing-service.yml').read_text(encoding='utf-8')
        self.assertIn('npm run check:moderation-tool',workflow)
        self.assertIn('run: npm run check',workflow)
        for job in planner.MODERATION_REPORT_BPLIST_JOBS:self.assertIn('name: '+job,workflow)

    def test_partial_unknown_product_control_workflow_and_permission_mix_are_full(self):
        for path in self.rows():self.assertEqual(self.select({p:r for p,r in self.rows().items() if p!=path}),scope.FULL_SCOPE)
        for path in ('NekoWidget/Shared/Privacy.swift','NekoWidget/NekoWidget/Info.plist',
                     'NekoWidget/SharingService/src/index.ts','NekoWidget/SharingService/migrations/0040_new.sql',
                     'NekoWidget/SharingService/scripts/moderation-owner-key-check-client-windows.ps1',
                     '.github/workflows/sharing-service.yml','NekoWidget/ci/plan-ios-ci.py','unknown.txt'):
            self.assertEqual(self.select(self.rows()|{path:[':100644','100644','c'*40,'d'*40,'M']}),scope.FULL_SCOPE,path)
        self.assertEqual(self.select(paths=list(self.rows())+[next(iter(self.rows()))]),scope.FULL_SCOPE)
        for change in ('registration','ancestry','control','frozen'):self.assertEqual(self.select(change=change),scope.FULL_SCOPE,change)

    def test_exact_blob_pairs_raw_modes_types_and_handoffs_fail_closed(self):
        for path,row in self.rows().items():
            for index,value in ((0,':100755'),(1,'100755'),(1,'120000'),(2,'0'*40),(2,'e'*40),(3,'f'*40),(4,'A'),(4,'D')):
                changed=self.rows();changed[path]=row.copy();changed[path][index]=value
                self.assertEqual(self.select(changed),scope.FULL_SCOPE,(path,index,value))
        raw=''.join(' '.join(r)+'\0'+p+'\0' for p,r in self.rows().items())
        for malformed in (raw+raw,raw+'malformed\0',raw.split('\0',2)[2]):self.assertEqual(self.select(raw=malformed),scope.FULL_SCOPE)
        for status in ('A','M'):
            rows=self.rows()|{'handoffs/parser.md':[':000000' if status=='A' else ':100644','100644','0'*40 if status=='A' else 'c'*40,'d'*40,status]}
            self.assertEqual(self.select(rows),planner.MODERATION_REPORT_BPLIST_SCOPE)
            rows['handoffs/parser.md'][1]='120000';self.assertEqual(self.select(rows),scope.FULL_SCOPE)

    def test_backend_plan_names_current_jobs_and_starts_no_mac_or_evidence_lookup(self):
        import contextlib,io,json
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);event=root/'event.json';event.write_text('{}')
            env={'GITHUB_EVENT_PATH':str(event),'GITHUB_OUTPUT':str(root/'output'),'GITHUB_STEP_SUMMARY':str(root/'summary'),
                'GITHUB_SHA':self.head,'GITHUB_REPOSITORY':'soso-so-27/neko-widget','GITHUB_EVENT_NAME':'push'}
            output=io.StringIO()
            with patch.dict(os.environ,env,clear=True),patch.object(planner,'changed_paths',return_value=list(self.rows())), \
                    patch.object(planner,'runtime_scope',return_value=planner.MODERATION_REPORT_BPLIST_SCOPE), \
                    patch.object(planner,'github_api') as api,contextlib.redirect_stdout(output):planner.main()
            api.assert_not_called()
            record=json.loads(next(x.split('=',1)[1] for x in output.getvalue().splitlines() if x.startswith('IOS_CI_PLAN_JSON=')))
            self.assertEqual(record['required_backend_runs'],planner.moderation_report_bplist_requirements(self.head))
            self.assertIsNone(record['evidence_sha']);self.assertIsNone(record['evidence_run_id'])
            flags=(root/'output').read_text()
            for flag in ('build','smoke','sharing','app_ui'):self.assertIn(flag+'=false\n',flags)
            for flag in ('lanes','matrix_lanes','app_ui_lanes'):self.assertIn(flag+'=[]\n',flags)

    def test_preflight_is_unmeasured_with_first_measurement_gates_and_no_upload(self):
        import datetime as dt
        spec=importlib.util.spec_from_file_location('bplist_preflight',Path(__file__).with_name('preflight-ci.py'))
        preflight=importlib.util.module_from_spec(spec);spec.loader.exec_module(preflight)
        selected=preflight.planner.MODERATION_REPORT_BPLIST_SCOPE;history={'observations':[],'upload_minutes':12}
        cost=preflight.observe_cost(selected,history,False)
        self.assertEqual(cost['status'],'unmeasured');self.assertEqual(cost['samples'],[])
        self.assertEqual(cost['measurement_job_timeouts_minutes'],planner.MODERATION_REPORT_BPLIST_JOB_TIMEOUTS)
        with self.assertRaises(ValueError):preflight.observe_cost(selected,history,True)
        now=dt.datetime.now(dt.timezone.utc)
        result={'scope':selected,'head':self.head,'required_jobs':list(planner.MODERATION_REPORT_BPLIST_JOBS),
                'cost':cost,'target_minutes':30,'ready':False}
        self.assertTrue(preflight.apply_task_gate(copy.deepcopy(result),[],now,measure_baseline=True)['ready'])
        for status,conclusion in (('completed','failure'),('in_progress',None),('completed','success')):
            run={'id':10,'path':preflight.planner.BILLING_WORKFLOW,'head_branch':'codex/parser','head_sha':self.head,
                 'event':'push','status':status,'conclusion':conclusion,'created_at':now.isoformat(),'failed_tests':[],'unsupported_failed_tests':[]}
            self.assertFalse(preflight.apply_task_gate(copy.deepcopy(result),[run],now,measure_baseline=True)['ready'])


class ModerationRetiredReportScopeTests(unittest.TestCase):
    base, head = 'b'*40, 'a'*40

    def rows(self):
        return {path:[':000000' if before=='0'*40 else ':100644','100644',before,after,'A' if before=='0'*40 else 'M']
                for path,(before,after) in planner.MODERATION_RETIRED_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, change=None):
        import hashlib
        rows=self.rows() if rows is None else rows
        paths=list(rows) if paths is None else paths
        tree=f'100644 blob {"d"*40}\tunchanged-product.swift\0'
        def git(*args):
            if args[0]=='merge-base':
                if change=='ancestry' and '--is-ancestor' in args:raise subprocess.CalledProcessError(1,args)
                return self.base
            if args[0]=='rev-parse':return self.head if args[1]=='HEAD' else '0'*40
            if args[0]=='diff':return raw if raw is not None else ''.join(' '.join(r)+'\0'+p+'\0' for p,r in rows.items())
            if args[0]=='show':return '' if change=='registration' else 'MODERATION_RETIRED_SCOPE = "moderation-retired-no-action-v1"'
            if args[:3]==('ls-tree','-r','-z'):
                return tree+(f'100644 blob {"e"*40}\tprivacy.swift\0' if change=='frozen' and args[3]==self.head else '')
            if args[0]=='ls-tree':
                ref,path=args[1],args[-1]
                if path in planner.MODERATION_RETIRED_BLOBS:
                    blob=planner.MODERATION_RETIRED_BLOBS[path][ref==self.head]
                else:blob=('f' if change=='control' and ref==self.head else 'c')*40
                return '' if blob=='0'*40 else f'100644 blob {blob}\t{path}'
            raise AssertionError(args)
        with patch.object(planner,'git',side_effect=git),patch.object(planner,'MODERATION_RETIRED_TREE_SHA256',hashlib.sha256(tree.encode()).hexdigest()):
            return planner.runtime_scope(paths,{}, {'GITHUB_SHA':self.head,'GITHUB_EVENT_NAME':'push','GITHUB_REF':'refs/heads/codex/parser'})

    def test_exact_reviewed_eight_changes_require_current_backend_and_reject_release(self):
        selected=planner.MODERATION_RETIRED_SCOPE
        self.assertEqual(self.select(),selected)
        self.assertEqual(planner.required_jobs(list(self.rows()),selected),planner.MODERATION_RETIRED_JOBS)
        self.assertEqual(planner.moderation_retired_requirements(self.head),[
            {'workflow':planner.PRESERVATION_WORKFLOW if job==planner.PRESERVATION_JOB else '.github/workflows/sharing-service.yml','job':job,'head_sha':self.head,'event':'push','success_required':True}
            for job in (*planner.MODERATION_OPERATOR_STARTUP_JOBS,planner.PRESERVATION_JOB)])
        self.assertNotIn(selected,scope.SCOPES)
        with self.assertRaises(ValueError):planner.required_jobs_from_scope(selected)
        import json
        package=json.loads((ROOT/'NekoWidget/SharingService/package.json').read_text(encoding='utf-8'))
        command=package['scripts']['check:moderation-tool']
        for name in ('moderation-report-tool','moderation-report-windows-boundary','moderation-bound-review',
                     'moderation-owner-review-host','moderation-owner-r2-transport'):
            self.assertIn(name+'.node-tests.mjs',command)
        workflow=(ROOT/'.github/workflows/sharing-service.yml').read_text(encoding='utf-8')
        self.assertIn('npm run check:moderation-tool',workflow)
        self.assertIn('run: npm run check',workflow)
        for job in planner.MODERATION_RETIRED_JOBS:self.assertIn('name: '+job,workflow)

    def test_partial_unknown_product_control_workflow_and_permission_mix_are_full(self):
        for path in self.rows():self.assertEqual(self.select({p:r for p,r in self.rows().items() if p!=path}),scope.FULL_SCOPE)
        for path in ('NekoWidget/Shared/Privacy.swift','NekoWidget/NekoWidget/Info.plist',
                     'NekoWidget/SharingService/src/index.ts','NekoWidget/SharingService/migrations/0040_new.sql',
                     'NekoWidget/SharingService/scripts/moderation-owner-key-check-client-windows.ps1',
                     '.github/workflows/sharing-service.yml','NekoWidget/ci/plan-ios-ci.py','unknown.txt'):
            self.assertEqual(self.select(self.rows()|{path:[':100644','100644','c'*40,'d'*40,'M']}),scope.FULL_SCOPE,path)
        self.assertEqual(self.select(paths=list(self.rows())+[next(iter(self.rows()))]),scope.FULL_SCOPE)
        for change in ('registration','ancestry','control','frozen'):self.assertEqual(self.select(change=change),scope.FULL_SCOPE,change)

    def test_exact_blob_pairs_raw_modes_types_and_handoffs_fail_closed(self):
        for path,row in self.rows().items():
            for index,value in ((0,':100755'),(1,'100755'),(1,'120000'),(2,'0'*40),(2,'e'*40),(3,'f'*40),(4,'A'),(4,'D')):
                if value==row[index]:continue
                changed=self.rows();changed[path]=row.copy();changed[path][index]=value
                self.assertEqual(self.select(changed),scope.FULL_SCOPE,(path,index,value))
        raw=''.join(' '.join(r)+'\0'+p+'\0' for p,r in self.rows().items())
        for malformed in (raw+raw,raw+'malformed\0',raw.split('\0',2)[2]):self.assertEqual(self.select(raw=malformed),scope.FULL_SCOPE)
        for status in ('A','M'):
            rows=self.rows()|{'handoffs/parser.md':[':000000' if status=='A' else ':100644','100644','0'*40 if status=='A' else 'c'*40,'d'*40,status]}
            self.assertEqual(self.select(rows),planner.MODERATION_RETIRED_SCOPE)
            rows['handoffs/parser.md'][1]='120000';self.assertEqual(self.select(rows),scope.FULL_SCOPE)

    def test_backend_plan_names_current_jobs_and_starts_no_mac_or_evidence_lookup(self):
        import contextlib,io,json
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);event=root/'event.json';event.write_text('{}')
            env={'GITHUB_EVENT_PATH':str(event),'GITHUB_OUTPUT':str(root/'output'),'GITHUB_STEP_SUMMARY':str(root/'summary'),
                'GITHUB_SHA':self.head,'GITHUB_REPOSITORY':'soso-so-27/neko-widget','GITHUB_EVENT_NAME':'push'}
            output=io.StringIO()
            with patch.dict(os.environ,env,clear=True),patch.object(planner,'changed_paths',return_value=list(self.rows())), \
                    patch.object(planner,'runtime_scope',return_value=planner.MODERATION_RETIRED_SCOPE), \
                    patch.object(planner,'github_api') as api,contextlib.redirect_stdout(output):planner.main()
            api.assert_not_called()
            record=json.loads(next(x.split('=',1)[1] for x in output.getvalue().splitlines() if x.startswith('IOS_CI_PLAN_JSON=')))
            self.assertEqual(record['required_backend_runs'],planner.moderation_retired_requirements(self.head))
            self.assertIsNone(record['evidence_sha']);self.assertIsNone(record['evidence_run_id'])
            flags=(root/'output').read_text()
            for flag in ('build','smoke','sharing','app_ui'):self.assertIn(flag+'=false\n',flags)
            for flag in ('lanes','matrix_lanes','app_ui_lanes'):self.assertIn(flag+'=[]\n',flags)

    def test_preflight_is_unmeasured_with_first_measurement_gates_and_no_upload(self):
        import datetime as dt
        spec=importlib.util.spec_from_file_location('bplist_preflight',Path(__file__).with_name('preflight-ci.py'))
        preflight=importlib.util.module_from_spec(spec);spec.loader.exec_module(preflight)
        selected=preflight.planner.MODERATION_RETIRED_SCOPE;history={'observations':[],'upload_minutes':12}
        cost=preflight.observe_cost(selected,history,False)
        self.assertEqual(cost['status'],'unmeasured');self.assertEqual(cost['samples'],[])
        self.assertEqual(cost['measurement_job_timeouts_minutes'],planner.MODERATION_RETIRED_MEASUREMENT_TIMEOUTS)
        with self.assertRaises(ValueError):preflight.observe_cost(selected,history,True)
        now=dt.datetime.now(dt.timezone.utc)
        result={'scope':selected,'head':self.head,'required_jobs':list(planner.MODERATION_RETIRED_JOBS),
                'cost':cost,'target_minutes':30,'ready':False}
        self.assertTrue(preflight.apply_task_gate(copy.deepcopy(result),[],now,measure_baseline=True)['ready'])
        for status,conclusion in (('completed','failure'),('in_progress',None),('completed','success')):
            run={'id':10,'path':preflight.planner.BILLING_WORKFLOW,'head_branch':'codex/parser','head_sha':self.head,
                 'event':'push','status':status,'conclusion':conclusion,'created_at':now.isoformat(),'failed_tests':[],'unsupported_failed_tests':[]}
            self.assertFalse(preflight.apply_task_gate(copy.deepcopy(result),[run],now,measure_baseline=True)['ready'])

class ModerationRetiredDecisionWindowScopeTests(unittest.TestCase):
    base, head = 'b'*40, 'a'*40

    def rows(self):
        return {path:[':000000' if before=='0'*40 else ':100644','100644',before,after,'A' if before=='0'*40 else 'M']
                for path,(before,after) in planner.MODERATION_RETIRED_WINDOW_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, change=None):
        import hashlib
        rows=self.rows() if rows is None else rows
        paths=list(rows) if paths is None else paths
        tree=f'100644 blob {"d"*40}\tunchanged-product.swift\0'
        def git(*args):
            if args[0]=='merge-base':
                if change=='ancestry' and '--is-ancestor' in args:raise subprocess.CalledProcessError(1,args)
                return self.base
            if args[0]=='rev-parse':return self.head if args[1]=='HEAD' else '0'*40
            if args[0]=='diff':return raw if raw is not None else ''.join(' '.join(r)+'\0'+p+'\0' for p,r in rows.items())
            if args[0]=='show':return '' if change=='registration' else 'MODERATION_RETIRED_WINDOW_SCOPE = "moderation-retired-decision-window-v1"'
            if args[:3]==('ls-tree','-r','-z'):
                return tree+(f'100644 blob {"e"*40}\tprivacy.swift\0' if change=='frozen' and args[3]==self.head else '')
            if args[0]=='ls-tree':
                ref,path=args[1],args[-1]
                if path in planner.MODERATION_RETIRED_WINDOW_BLOBS:
                    blob=planner.MODERATION_RETIRED_WINDOW_BLOBS[path][ref==self.head]
                else:blob=('f' if change=='control' and ref==self.head else 'c')*40
                return '' if blob=='0'*40 else f'100644 blob {blob}\t{path}'
            raise AssertionError(args)
        with patch.object(planner,'git',side_effect=git),patch.object(planner,'MODERATION_RETIRED_WINDOW_TREE_SHA256',hashlib.sha256(tree.encode()).hexdigest()):
            return planner.runtime_scope(paths,{}, {'GITHUB_SHA':self.head,'GITHUB_EVENT_NAME':'push','GITHUB_REF':'refs/heads/codex/parser'})

    def test_exact_reviewed_eight_window_changes_require_current_backend_and_reject_release(self):
        selected=planner.MODERATION_RETIRED_WINDOW_SCOPE
        self.assertEqual(self.select(),selected)
        self.assertEqual(planner.required_jobs(list(self.rows()),selected),planner.MODERATION_RETIRED_WINDOW_JOBS)
        self.assertEqual(planner.moderation_retired_window_requirements(self.head),[
            {'workflow':planner.PRESERVATION_WORKFLOW if job==planner.PRESERVATION_JOB else '.github/workflows/sharing-service.yml','job':job,'head_sha':self.head,'event':'push','success_required':True}
            for job in (*planner.MODERATION_OPERATOR_STARTUP_JOBS,planner.PRESERVATION_JOB)])
        self.assertNotIn(selected,scope.SCOPES)
        with self.assertRaises(ValueError):planner.required_jobs_from_scope(selected)
        import json
        package=json.loads((ROOT/'NekoWidget/SharingService/package.json').read_text(encoding='utf-8'))
        command=package['scripts']['check:moderation-tool']
        for name in ('moderation-report-tool','moderation-report-windows-boundary','moderation-bound-review',
                     'moderation-owner-review-host','moderation-owner-r2-transport'):
            self.assertIn(name+'.node-tests.mjs',command)
        workflow=(ROOT/'.github/workflows/sharing-service.yml').read_text(encoding='utf-8')
        self.assertIn('npm run check:moderation-tool',workflow)
        self.assertIn('run: npm run check',workflow)
        for job in planner.MODERATION_RETIRED_WINDOW_JOBS:self.assertIn('name: '+job,workflow)

    def test_partial_unknown_product_control_workflow_and_permission_mix_are_full(self):
        for path in self.rows():self.assertEqual(self.select({p:r for p,r in self.rows().items() if p!=path}),scope.FULL_SCOPE)
        for path in ('NekoWidget/Shared/Privacy.swift','NekoWidget/NekoWidget/Info.plist',
                     'NekoWidget/SharingService/src/index.ts','NekoWidget/SharingService/migrations/0040_new.sql',
                     'NekoWidget/SharingService/scripts/moderation-owner-key-check-client-windows.ps1',
                     '.github/workflows/sharing-service.yml','NekoWidget/ci/plan-ios-ci.py','unknown.txt'):
            self.assertEqual(self.select(self.rows()|{path:[':100644','100644','c'*40,'d'*40,'M']}),scope.FULL_SCOPE,path)
        self.assertEqual(self.select(paths=list(self.rows())+[next(iter(self.rows()))]),scope.FULL_SCOPE)
        for change in ('registration','ancestry','control','frozen'):self.assertEqual(self.select(change=change),scope.FULL_SCOPE,change)

    def test_exact_blob_pairs_raw_modes_types_and_handoffs_fail_closed(self):
        for path,row in self.rows().items():
            for index,value in ((0,':100755'),(1,'100755'),(1,'120000'),(2,'0'*40),(2,'e'*40),(3,'f'*40),(4,'A'),(4,'D')):
                if value==row[index]:continue
                changed=self.rows();changed[path]=row.copy();changed[path][index]=value
                self.assertEqual(self.select(changed),scope.FULL_SCOPE,(path,index,value))
        raw=''.join(' '.join(r)+'\0'+p+'\0' for p,r in self.rows().items())
        for malformed in (raw+raw,raw+'malformed\0',raw.split('\0',2)[2]):self.assertEqual(self.select(raw=malformed),scope.FULL_SCOPE)
        for status in ('A','M'):
            rows=self.rows()|{'handoffs/parser.md':[':000000' if status=='A' else ':100644','100644','0'*40 if status=='A' else 'c'*40,'d'*40,status]}
            self.assertEqual(self.select(rows),planner.MODERATION_RETIRED_WINDOW_SCOPE)
            rows['handoffs/parser.md'][1]='120000';self.assertEqual(self.select(rows),scope.FULL_SCOPE)

    def test_backend_plan_names_current_jobs_and_starts_no_mac_or_evidence_lookup(self):
        import contextlib,io,json
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);event=root/'event.json';event.write_text('{}')
            env={'GITHUB_EVENT_PATH':str(event),'GITHUB_OUTPUT':str(root/'output'),'GITHUB_STEP_SUMMARY':str(root/'summary'),
                'GITHUB_SHA':self.head,'GITHUB_REPOSITORY':'soso-so-27/neko-widget','GITHUB_EVENT_NAME':'push'}
            output=io.StringIO()
            with patch.dict(os.environ,env,clear=True),patch.object(planner,'changed_paths',return_value=list(self.rows())), \
                    patch.object(planner,'runtime_scope',return_value=planner.MODERATION_RETIRED_WINDOW_SCOPE), \
                    patch.object(planner,'github_api') as api,contextlib.redirect_stdout(output):planner.main()
            api.assert_not_called()
            record=json.loads(next(x.split('=',1)[1] for x in output.getvalue().splitlines() if x.startswith('IOS_CI_PLAN_JSON=')))
            self.assertEqual(record['required_backend_runs'],planner.moderation_retired_window_requirements(self.head))
            self.assertIsNone(record['evidence_sha']);self.assertIsNone(record['evidence_run_id'])
            flags=(root/'output').read_text()
            for flag in ('build','smoke','sharing','app_ui'):self.assertIn(flag+'=false\n',flags)
            for flag in ('lanes','matrix_lanes','app_ui_lanes'):self.assertIn(flag+'=[]\n',flags)

    def test_preflight_is_unmeasured_with_first_measurement_gates_and_no_upload(self):
        import datetime as dt
        spec=importlib.util.spec_from_file_location('bplist_preflight',Path(__file__).with_name('preflight-ci.py'))
        preflight=importlib.util.module_from_spec(spec);spec.loader.exec_module(preflight)
        selected=preflight.planner.MODERATION_RETIRED_WINDOW_SCOPE;history={'observations':[],'upload_minutes':12}
        cost=preflight.observe_cost(selected,history,False)
        self.assertEqual(cost['status'],'unmeasured');self.assertEqual(cost['samples'],[])
        self.assertEqual(cost['measurement_job_timeouts_minutes'],planner.MODERATION_RETIRED_WINDOW_MEASUREMENT_TIMEOUTS)
        with self.assertRaises(ValueError):preflight.observe_cost(selected,history,True)
        now=dt.datetime.now(dt.timezone.utc)
        result={'scope':selected,'head':self.head,'required_jobs':list(planner.MODERATION_RETIRED_WINDOW_JOBS),
                'cost':cost,'target_minutes':30,'ready':False}
        self.assertTrue(preflight.apply_task_gate(copy.deepcopy(result),[],now,measure_baseline=True)['ready'])
        for status,conclusion in (('completed','failure'),('in_progress',None),('completed','success')):
            run={'id':10,'path':preflight.planner.BILLING_WORKFLOW,'head_branch':'codex/parser','head_sha':self.head,
                 'event':'push','status':status,'conclusion':conclusion,'created_at':now.isoformat(),'failed_tests':[],'unsupported_failed_tests':[]}
            self.assertFalse(preflight.apply_task_gate(copy.deepcopy(result),[run],now,measure_baseline=True)['ready'])


class ModerationResponseReaderScopeTests(unittest.TestCase):
    base, head = 'b'*40, 'a'*40

    def rows(self):
        return {path:[':000000' if before=='0'*40 else ':100644','100644',before,after,'A' if before=='0'*40 else 'M']
                for path,(before,after) in planner.MODERATION_RESPONSE_READER_BLOBS.items()}

    def select(self, rows=None, *, paths=None, raw=None, change=None):
        import hashlib
        rows=self.rows() if rows is None else rows
        paths=list(rows) if paths is None else paths
        tree=f'100644 blob {"d"*40}\tunchanged-product.swift\0'
        def git(*args):
            if args[0]=='merge-base':
                if change=='ancestry' and '--is-ancestor' in args:raise subprocess.CalledProcessError(1,args)
                return self.base
            if args[0]=='rev-parse':return self.head if args[1]=='HEAD' else '0'*40
            if args[0]=='diff':return raw if raw is not None else ''.join(' '.join(r)+'\0'+p+'\0' for p,r in rows.items())
            if args[0]=='show':return '' if change=='registration' else 'MODERATION_RESPONSE_READER_SCOPE = "moderation-response-reader-v1"'
            if args[:3]==('ls-tree','-r','-z'):
                return tree+(f'100644 blob {"e"*40}\tprivacy.swift\0' if change=='frozen' and args[3]==self.head else '')
            if args[0]=='ls-tree':
                ref,path=args[1],args[-1]
                if path in planner.MODERATION_RESPONSE_READER_BLOBS:
                    blob=planner.MODERATION_RESPONSE_READER_BLOBS[path][ref==self.head]
                else:blob=('f' if change=='control' and ref==self.head else 'c')*40
                return '' if blob=='0'*40 else f'100644 blob {blob}\t{path}'
            raise AssertionError(args)
        with patch.object(planner,'git',side_effect=git),patch.object(planner,'MODERATION_RESPONSE_READER_TREE_SHA256',hashlib.sha256(tree.encode()).hexdigest()):
            return planner.runtime_scope(paths,{}, {'GITHUB_SHA':self.head,'GITHUB_EVENT_NAME':'push','GITHUB_REF':'refs/heads/codex/parser'})

    def test_exact_reviewed_eight_window_changes_require_current_backend_and_reject_release(self):
        selected=planner.MODERATION_RESPONSE_READER_SCOPE
        self.assertEqual(self.select(),selected)
        self.assertEqual(planner.required_jobs(list(self.rows()),selected),planner.MODERATION_RESPONSE_READER_JOBS)
        self.assertEqual(planner.moderation_response_reader_requirements(self.head),[
            {'workflow':planner.PRESERVATION_WORKFLOW if job==planner.PRESERVATION_JOB else '.github/workflows/sharing-service.yml','job':job,'head_sha':self.head,'event':'push','success_required':True}
            for job in (*planner.MODERATION_OPERATOR_STARTUP_JOBS,planner.PRESERVATION_JOB)])
        self.assertNotIn(selected,scope.SCOPES)
        with self.assertRaises(ValueError):planner.required_jobs_from_scope(selected)
        import json
        package=json.loads((ROOT/'NekoWidget/SharingService/package.json').read_text(encoding='utf-8'))
        command=package['scripts']['check:moderation-tool']
        for name in ('moderation-report-tool','moderation-report-windows-boundary','moderation-bound-review',
                     'moderation-owner-review-host','moderation-owner-r2-transport'):
            self.assertIn(name+'.node-tests.mjs',command)
        workflow=(ROOT/'.github/workflows/sharing-service.yml').read_text(encoding='utf-8')
        self.assertIn('npm run check:moderation-tool',workflow)
        self.assertIn('run: npm run check',workflow)
        for job in planner.MODERATION_RESPONSE_READER_JOBS:self.assertIn('name: '+job,workflow)

    def test_partial_unknown_product_control_workflow_and_permission_mix_are_full(self):
        for path in self.rows():self.assertEqual(self.select({p:r for p,r in self.rows().items() if p!=path}),scope.FULL_SCOPE)
        for path in ('NekoWidget/Shared/Privacy.swift','NekoWidget/NekoWidget/Info.plist',
                     'NekoWidget/SharingService/src/index.ts','NekoWidget/SharingService/migrations/0040_new.sql',
                     'NekoWidget/SharingService/scripts/moderation-owner-key-check-client-windows.ps1',
                     '.github/workflows/sharing-service.yml','NekoWidget/ci/plan-ios-ci.py','unknown.txt'):
            self.assertEqual(self.select(self.rows()|{path:[':100644','100644','c'*40,'d'*40,'M']}),scope.FULL_SCOPE,path)
        self.assertEqual(self.select(paths=list(self.rows())+[next(iter(self.rows()))]),scope.FULL_SCOPE)
        for change in ('registration','ancestry','control','frozen'):self.assertEqual(self.select(change=change),scope.FULL_SCOPE,change)

    def test_exact_blob_pairs_raw_modes_types_and_handoffs_fail_closed(self):
        for path,row in self.rows().items():
            for index,value in ((0,':100755'),(1,'100755'),(1,'120000'),(2,'0'*40),(2,'e'*40),(3,'f'*40),(4,'A'),(4,'D')):
                if value==row[index]:continue
                changed=self.rows();changed[path]=row.copy();changed[path][index]=value
                self.assertEqual(self.select(changed),scope.FULL_SCOPE,(path,index,value))
        raw=''.join(' '.join(r)+'\0'+p+'\0' for p,r in self.rows().items())
        for malformed in (raw+raw,raw+'malformed\0',raw.split('\0',2)[2]):self.assertEqual(self.select(raw=malformed),scope.FULL_SCOPE)
        for status in ('A','M'):
            rows=self.rows()|{'handoffs/parser.md':[':000000' if status=='A' else ':100644','100644','0'*40 if status=='A' else 'c'*40,'d'*40,status]}
            self.assertEqual(self.select(rows),planner.MODERATION_RESPONSE_READER_SCOPE)
            rows['handoffs/parser.md'][1]='120000';self.assertEqual(self.select(rows),scope.FULL_SCOPE)

    def test_backend_plan_names_current_jobs_and_starts_no_mac_or_evidence_lookup(self):
        import contextlib,io,json
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);event=root/'event.json';event.write_text('{}')
            env={'GITHUB_EVENT_PATH':str(event),'GITHUB_OUTPUT':str(root/'output'),'GITHUB_STEP_SUMMARY':str(root/'summary'),
                'GITHUB_SHA':self.head,'GITHUB_REPOSITORY':'soso-so-27/neko-widget','GITHUB_EVENT_NAME':'push'}
            output=io.StringIO()
            with patch.dict(os.environ,env,clear=True),patch.object(planner,'changed_paths',return_value=list(self.rows())), \
                    patch.object(planner,'runtime_scope',return_value=planner.MODERATION_RESPONSE_READER_SCOPE), \
                    patch.object(planner,'github_api') as api,contextlib.redirect_stdout(output):planner.main()
            api.assert_not_called()
            record=json.loads(next(x.split('=',1)[1] for x in output.getvalue().splitlines() if x.startswith('IOS_CI_PLAN_JSON=')))
            self.assertEqual(record['required_backend_runs'],planner.moderation_response_reader_requirements(self.head))
            self.assertIsNone(record['evidence_sha']);self.assertIsNone(record['evidence_run_id'])
            flags=(root/'output').read_text()
            for flag in ('build','smoke','sharing','app_ui'):self.assertIn(flag+'=false\n',flags)
            for flag in ('lanes','matrix_lanes','app_ui_lanes'):self.assertIn(flag+'=[]\n',flags)

    def test_preflight_is_unmeasured_with_first_measurement_gates_and_no_upload(self):
        import datetime as dt
        spec=importlib.util.spec_from_file_location('bplist_preflight',Path(__file__).with_name('preflight-ci.py'))
        preflight=importlib.util.module_from_spec(spec);spec.loader.exec_module(preflight)
        selected=preflight.planner.MODERATION_RESPONSE_READER_SCOPE;history={'observations':[],'upload_minutes':12}
        cost=preflight.observe_cost(selected,history,False)
        self.assertEqual(cost['status'],'unmeasured');self.assertEqual(cost['samples'],[])
        self.assertEqual(cost['measurement_job_timeouts_minutes'],planner.MODERATION_RESPONSE_READER_MEASUREMENT_TIMEOUTS)
        with self.assertRaises(ValueError):preflight.observe_cost(selected,history,True)
        now=dt.datetime.now(dt.timezone.utc)
        result={'scope':selected,'head':self.head,'required_jobs':list(planner.MODERATION_RESPONSE_READER_JOBS),
                'cost':cost,'target_minutes':30,'ready':False}
        self.assertTrue(preflight.apply_task_gate(copy.deepcopy(result),[],now,measure_baseline=True)['ready'])
        for status,conclusion in (('completed','failure'),('in_progress',None),('completed','success')):
            run={'id':10,'path':preflight.planner.BILLING_WORKFLOW,'head_branch':'codex/parser','head_sha':self.head,
                 'event':'push','status':status,'conclusion':conclusion,'created_at':now.isoformat(),'failed_tests':[],'unsupported_failed_tests':[]}
            self.assertFalse(preflight.apply_task_gate(copy.deepcopy(result),[run],now,measure_baseline=True)['ready'])


class InternalReportMetadataRepairTests(unittest.TestCase):
    def test_complete_repair_closure_rejects_every_other_input_and_unapproved_controls(self):
        head, source, approved = 'c'*40, planner.INTERNAL_REPORT_METADATA_SOURCE, 'd'*40
        blobs = dict(planner.INTERNAL_REPORT_METADATA_REPAIR_BLOBS)
        blobs['NekoWidget/ci/moderation-v2-readiness.json'] = 'e'*40
        raw = ''.join(f':100644 100644 {"a"*40} {blob} M\0{path}\0' for path,blob in blobs.items())
        def prove(change=None):
            def git(*args):
                if args[0] == 'merge-base': return approved
                if args[0] == 'show': return '' if change == 'registration' else f'INTERNAL_REPORT_METADATA_SOURCE = "{source}"'
                if args[0] == 'diff':
                    value = raw
                    if change == 'extra': value += f':100644 100644 {"a"*40} {"b"*40} M\0NekoWidget/Shared/Privacy.swift\0'
                    if change == 'mode': value = value.replace(':100644',' :100755',1)
                    if change == 'type': value = value.replace('100644','120000',1)
                    if change == 'missing': value = value.split('\0',2)[2]
                    if change == 'duplicate': value += value.split('\0',2)[0]+'\0'+value.split('\0',2)[1]+'\0'
                    return value
                path = args[-1]
                blob = 'a'*40 if args[1] == source else blobs.get(path,'b'*40)
                if change == 'control' and args[1] == head and path in planner.INTERNAL_REPORT_CONTROLS: blob='f'*40
                return f'100644 blob {blob}\t{path}'
            with patch.object(planner,'INTERNAL_REPORT_METADATA_REPAIR_BLOBS',blobs), \
                    patch.object(planner,'internal_report_candidate_inputs',return_value=change != 'source'),patch.object(planner,'git',side_effect=git):
                return planner.internal_report_metadata_repair_inputs(head)
        got = prove(); self.assertEqual(got['candidate_sha'],head)
        self.assertEqual(got['source_sha'],source); self.assertEqual(got['repair_blobs'],blobs)
        # After main integration the merge-base commit changes; identical approved
        # control bytes must keep the candidate's exact release proof stable.
        approved = 'f'*40
        self.assertEqual(prove(),got)
        for change in ('registration','extra','mode','type','missing','duplicate','control','source'):
            self.assertIsNone(prove(change),change)
        # Exercise the zero pin with the otherwise valid source, registration,
        # tracked repair inputs and approved control fixture used above.
        blobs['NekoWidget/ci/moderation-v2-readiness.json'] = '0'*40
        self.assertIsNone(prove())

    def fixture(self):
        import datetime as dt, hashlib
        now=dt.datetime(2026,10,11,14,tzinfo=dt.timezone.utc)
        failure=dict(id=planner.INTERNAL_REPORT_METADATA_FAILURE_RUN,head_sha=planner.INTERNAL_REPORT_METADATA_FAILURE_HEAD,
            head_branch='main',workflow_id=335014239,path='.github/workflows/testflight.yml',event='workflow_dispatch',
            run_attempt=1,status='completed',conclusion='failure',display_title=f'TestFlight build 250 @ {planner.INTERNAL_REPORT_METADATA_SOURCE}',
            created_at='2026-10-11T13:42:18Z',run_started_at='2026-10-11T13:42:18Z',updated_at='2026-10-11T13:52:26Z',
            repository={'full_name':'soso-so-27/neko-widget'},head_repository={'full_name':'soso-so-27/neko-widget'})
        names=re.findall(r'^      - name: (.+)$',(ROOT/'.github/workflows/testflight.yml').read_text(encoding='utf-8'),re.M)
        self.assertEqual(len(names),31)
        names = ['Set up job'] + names + ['Post Set up Node.js for public policy gate','Post Check out repository','Complete job']
        steps=[dict(name=name,status='completed',conclusion='failure' if name=='Generate build-bound moderation release metadata'
            else 'skipped' if 21 <= index < 29 else 'success') for index,name in enumerate(names)]
        steps[names.index('Validate and upload IPA to TestFlight')]['conclusion']='skipped'
        job=dict(id=planner.INTERNAL_REPORT_METADATA_FAILURE_JOB,run_id=failure['id'],head_sha=failure['head_sha'],
            run_attempt=1,name='Archive, export IPA, and upload',status='completed',conclusion='failure',
            started_at='2026-10-11T13:43:13Z',completed_at='2026-10-11T13:52:26Z',steps=steps)
        log='Moderation v2 readiness verification failed: reviewed_code_changed'
        pin=hashlib.sha256(log.encode()).hexdigest()
        prefix='/repos/soso-so-27/neko-widget/actions'
        api={f'{prefix}/runs/{failure["id"]}':failure,
             f'{prefix}/runs/{failure["id"]}/attempts/1/jobs?per_page=100':{'total_count':1,'jobs':[job]},
             f'{prefix}/jobs/{job["id"]}/logs':log}
        return failure,job,log,pin,api,now

    def test_failed_release_keeps_archive_export_success_metadata_failure_and_upload_skipped(self):
        failure,job,log,pin,api,now=self.fixture()
        def prove(values=api,stamp=now):
            with patch.object(planner,'INTERNAL_REPORT_METADATA_FAILURE_LOG',pin):
                return planner.internal_report_metadata_failure_evidence(values.__getitem__,stamp)
        got=prove(); self.assertEqual(got['apple_upload'],'skipped'); self.assertEqual(got['build_number'],250)
        log_key=next(k for k in api if k.endswith('/logs'))
        transported='\ufeff2026-10-11T13:52:21.3063590Z '+log+'\r\n'
        changed=copy.deepcopy(api);changed[log_key]=transported
        self.assertEqual(prove(changed),got)
        for altered in ('\ufeff'+transported,transported+'\ufeff',transported.replace('reviewed_code_changed','unknown_failure')):
            changed=copy.deepcopy(api);changed[log_key]=altered
            self.assertIsNone(prove(changed))
        for field,value in (('id',True),('head_sha','f'*40),('run_attempt',2),('status','in_progress'),('updated_at','2026-10-11T13:52:27Z')):
            changed=copy.deepcopy(api);changed[next(k for k in api if k.endswith(str(failure['id'])))][field]=value
            self.assertIsNone(prove(changed),(field,value))
        key=next(k for k in api if '/attempts/' in k)
        for name,conclusion in (('Archive app and widget','skipped'),('Export IPA','failure'),('Validate and upload IPA to TestFlight','success'),('Generate build-bound moderation release metadata','success')):
            changed=copy.deepcopy(api)
            next(s for s in changed[key]['jobs'][0]['steps'] if s['name']==name)['conclusion']=conclusion
            self.assertIsNone(prove(changed),(name,conclusion))
        changed=copy.deepcopy(api);changed[next(k for k in api if k.endswith('/logs'))]=log+'\nunknown'
        self.assertIsNone(prove(changed))
        self.assertIsNone(prove(stamp=now+planner.dt.timedelta(days=1)))

    def test_graph_checks_original_composite_at_source_and_never_fabricates_candidate_backend(self):
        source=planner.INTERNAL_REPORT_METADATA_SOURCE; head='c'*40
        run={'id':planner.INTERNAL_REPORT_METADATA_RUN,'head_sha':source}
        required=planner.required_jobs_from_scope(planner.INTERNAL_REPORT_SCOPE)
        composite={'native_evidence':{'sha':planner.INTERNAL_REPORT_CORRECTION_SOURCE},
            'backend_evidence':{w:{'run_id':identifier,'sha':source} for w,identifier in planner.INTERNAL_REPORT_METADATA_BACKEND_RUNS.items()}}
        def prove(value=composite,index=None):
            with patch.object(planner,'internal_report_metadata_repair_inputs',return_value={'candidate_sha':head}), \
                    patch.object(planner,'internal_report_correction_graph',return_value=value) as original, \
                    patch.object(planner,'internal_report_metadata_failure_evidence',return_value={'apple_upload':'skipped'}):
                got=planner.internal_report_metadata_repair_graph(run,head,required,lambda _:index or {'total_count':0,'workflow_runs':[]},planner.dt.datetime.now(planner.dt.timezone.utc),[])
                if got is not None:self.assertEqual(original.call_args.args[:3],(run,source,required))
                return got
        got=prove();self.assertEqual(got['backend_evidence'],composite['backend_evidence']);self.assertEqual(got['source_sha'],source)
        self.assertIsNone(prove(None))
        wrong=copy.deepcopy(composite);wrong['backend_evidence']['sharing-service.yml']['sha']=head
        self.assertIsNone(prove(wrong))
        wrong=copy.deepcopy(composite);wrong['backend_evidence']['sharing-service.yml']['run_id']+=1
        self.assertIsNone(prove(wrong))
        self.assertIsNone(prove(index={'total_count':1,'workflow_runs':[{'conclusion':'failure'}]}))

    def test_plan_only_route_outputs_exact_proof_and_no_native_flags(self):
        import contextlib,io,json
        head='c'*40;source={'id':planner.INTERNAL_REPORT_METADATA_RUN,'head_sha':planner.INTERNAL_REPORT_METADATA_SOURCE}
        proof={'kind':'internal-report-source-metadata-repair-v1','candidate_sha':head,'source_sha':source['head_sha']}
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);event=root/'event.json';event.write_text('{}')
            env={'GITHUB_EVENT_PATH':str(event),'GITHUB_OUTPUT':str(root/'output'),'GITHUB_STEP_SUMMARY':str(root/'summary'),
                'GITHUB_SHA':head,'GITHUB_REPOSITORY':'soso-so-27/neko-widget','GITHUB_EVENT_NAME':'push',
                'GITHUB_REF':'refs/heads/'+planner.INTERNAL_REPORT_METADATA_BRANCH,'GITHUB_SERVER_URL':'https://github.com'}
            output=io.StringIO()
            with patch.dict(os.environ,env,clear=True),patch.object(planner,'changed_paths',return_value=sorted(scope.INTERNAL_REPORT_METADATA_REPAIR_PATHS)), \
                    patch.object(planner,'runtime_scope',return_value=scope.INTERNAL_REPORT_SCOPE),patch.object(planner,'internal_report_metadata_repair_inputs',return_value={'candidate_sha':head}), \
                    patch.object(planner,'github_api',return_value=source),patch.object(planner,'executed_jobs',return_value=[]), \
                    patch.object(planner,'internal_report_metadata_repair_graph',return_value=proof),patch.object(planner,'find_evidence') as ordinary, \
                    patch.object(planner,'find_test_correction_evidence') as correction,contextlib.redirect_stdout(output):
                planner.main()
            ordinary.assert_not_called();correction.assert_not_called()
            record=json.loads(next(x.split('=',1)[1] for x in output.getvalue().splitlines() if x.startswith('IOS_CI_PLAN_JSON=')))
            self.assertEqual(record['internal_report_metadata_repair'],proof)
            self.assertEqual((record['evidence_run_id'],record['evidence_sha']),(source['id'],source['head_sha']))
            self.assertEqual(record['required_backend_runs'],planner.internal_report_requirements(source['head_sha']))
            self.assertIsNone(record['test_correction_evidence'])
            flags=(root/'output').read_text()
            for flag in ('build','smoke','sharing','app_ui'):self.assertIn(flag+'=false\n',flags)

    def test_preflight_retains_both_failures_diagnostic_and_first_candidate_cost(self):
        import datetime as dt
        spec=importlib.util.spec_from_file_location('metadata_repair_preflight',Path(__file__).with_name('preflight-ci.py'))
        preflight=importlib.util.module_from_spec(spec);spec.loader.exec_module(preflight)
        p=preflight.planner;head='c'*40;now=dt.datetime(2026,10,11,14,tzinfo=dt.timezone.utc)
        common=dict(status='completed',conclusion='success',created_at=(now-dt.timedelta(minutes=120)).isoformat(),
            updated_at=now.isoformat(),run_attempt=1,event='push',path='.github/workflows/ios-build.yml',failed_tests=[],unsupported_failed_tests=[])
        original=dict(common,id=p.INTERNAL_REPORT_CORRECTION_RUN,head_sha=p.INTERNAL_REPORT_CORRECTION_SOURCE,conclusion='failure',
            unsupported_failed_tests=['privacy_failure'])
        source=dict(common,id=p.INTERNAL_REPORT_METADATA_RUN,head_sha=p.INTERNAL_REPORT_METADATA_SOURCE)
        failure=dict(common,id=p.INTERNAL_REPORT_METADATA_FAILURE_RUN,head_sha=p.INTERNAL_REPORT_METADATA_FAILURE_HEAD,
            conclusion='failure',path='.github/workflows/testflight.yml')
        diagnostic=dict(common,id=p.INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_RUN,head_sha=p.INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_SOURCE,
            event='workflow_dispatch',path=preflight.DIAGNOSTIC_WORKFLOW)
        proof=dict(kind='internal-report-source-metadata-repair-v1',candidate_sha=head,
            source_sha=p.INTERNAL_REPORT_METADATA_SOURCE,source_run_id=p.INTERNAL_REPORT_METADATA_RUN)
        result=dict(scope=p.INTERNAL_REPORT_SCOPE,head=head,required_jobs=list(p.required_jobs_from_scope(p.INTERNAL_REPORT_SCOPE)),
            target_minutes=200,cost={'status':'reference','with_upload_minutes':[1,1]},ready=True)
        runs=[original,source,failure,diagnostic]
        got=preflight.apply_task_gate(copy.deepcopy(result),runs,now,metadata_repair=proof)
        self.assertTrue(got['ready']);self.assertEqual(got['task']['failed_runs'],[original['id'],failure['id']])
        self.assertEqual(got['task']['diagnostic_runs'],[diagnostic['id']]);self.assertEqual(got['task']['projected_total_minutes'],121)
        unknown=dict(common,id=999,head_sha=head,conclusion='failure')
        self.assertIn('internal_report_has_unresolved_candidate_failure',preflight.apply_task_gate(copy.deepcopy(result),runs+[unknown],now,metadata_repair=proof)['task']['blockers'])
        active=dict(common,id=998,head_sha=head,status='in_progress',conclusion=None)
        self.assertIn('ci_already_running',preflight.apply_task_gate(copy.deepcopy(result),runs+[active],now,metadata_repair=proof)['task']['blockers'])
        short=dict(result,target_minutes=30)
        self.assertIn('cumulative_cost_requires_replanning',preflight.apply_task_gate(short,runs,now,metadata_repair=proof)['task']['blockers'])
        for missing in (original,source,failure,diagnostic):
            with self.assertRaises(ValueError):preflight.apply_task_gate(copy.deepcopy(result),[r for r in runs if r is not missing],now,metadata_repair=proof)
        with self.assertRaises(ValueError):preflight.apply_task_gate(copy.deepcopy(result),runs,now,metadata_repair=dict(proof,candidate_sha='f'*40))


class InternalReportNativeBoundaryTests(unittest.TestCase):
    def test_backend_snapshot_requires_registered_main_full_product_controls_and_rest(self):
        import hashlib
        head='c'*40
        tree=f"100644 blob {'d'*40}\tunchanged.swift\0"
        registration=f'INTERNAL_REPORT_CORRECTION_SOURCE = "{planner.INTERNAL_REPORT_CORRECTION_SOURCE}"'
        def prove(changed=None):
            def git(*a):
                if a[0]=='merge-base':return 'approved'
                if a[0]=='show':return '' if changed=='registration' else registration
                if a[:3]==('ls-tree','-r','-z'):return tree + (f"100644 blob {'e'*40}\textra.swift\0" if changed=='rest' else '')
                path=a[3]
                if path in scope.INTERNAL_REPORT_PATHS:
                    return f"{'120000' if changed=='product' else '100644'} blob {scope.INTERNAL_REPORT_BLOBS[path][1]}\t{path}"
                return f"100644 blob {('e' if changed=='control' and a[1]==head else 'd')*40}\t{path}"
            with patch.object(planner,'git',side_effect=git),patch.object(planner,'INTERNAL_REPORT_IMMUTABLE_TREE_SHA256',hashlib.sha256(tree.encode()).hexdigest()):
                return planner.internal_report_candidate_inputs(head)
        self.assertTrue(prove())
        for changed in ('registration','product','control','rest'):self.assertFalse(prove(changed))

    def test_release_correction_inputs_reject_extra_native_or_wrong_release_pair(self):
        head='c'*40
        path='NekoWidget/NekoWidgetShareExtension/Info.Disabled.plist'
        before,after=scope.INTERNAL_REPORT_BLOBS[path]
        def prove(fields=None,extra=''):
            fields=fields or [':100644','100644',before,after,'M']
            ui=planner.INTERNAL_REPORT_CORRECTION_UI_PATH
            raw=' '.join(fields)+'\0'+path+'\0'+f':100644 100644 2ea1c9b7565738f769251e3506003aa5ae9bc723 {scope.INTERNAL_REPORT_BLOBS[ui][1]} M\0{ui}\0'+extra
            def git(*a):
                if a[0]=='merge-base':return ''
                if a[0]=='diff':return raw
                if a[-1]==ui:return f'100644 blob 2ea1c9b7565738f769251e3506003aa5ae9bc723\t{ui}'
                return f'100644 blob {before}\t{path}'
            with patch.object(planner,'internal_report_candidate_inputs',return_value=True),patch.object(planner,'git',side_effect=git):
                return planner.internal_report_correction_inputs(head)
        self.assertTrue(prove())
        self.assertFalse(prove(extra=f":100644 100644 {'d'*40} {'e'*40} M\0NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift\0"))
        for index,value in ((0,':100755'),(1,'120000'),(2,'d'*40),(3,'e'*40),(4,'A')):
            fields=[':100644','100644',before,after,'M'];fields[index]=value
            self.assertFalse(prove(fields))

    def correction_source_fixture(self):
        import datetime as dt
        import hashlib
        sha = planner.INTERNAL_REPORT_CORRECTION_SOURCE
        now = dt.datetime(2026, 10, 11, 13, tzinfo=dt.timezone.utc)
        repository = "soso-so-27/neko-widget"
        prefix = f"/repos/{repository}/actions"
        run = dict(id=planner.INTERNAL_REPORT_CORRECTION_RUN, head_sha=sha,
            head_branch=planner.INTERNAL_REPORT_CORRECTION_BRANCH, workflow_id=335014238,
            path=".github/workflows/ios-build.yml", event="push", run_attempt=1,
            status="completed", conclusion="failure", repository={"full_name":repository},
            head_repository={"full_name":repository}, updated_at=now.isoformat())
        jobs = []
        for name, identifier in planner.INTERNAL_REPORT_CORRECTION_JOB_IDS.items():
            steps = (["Select checks"] if name == planner.PLAN_JOB else
                     ["Check out repository","Run Simulator smoke test","Upload Simulator smoke-test artifacts"] if name == planner.BOOTSTRAP_SMOKE else
                     ["Check out repository","Run sharing runtime matrix","Upload sharing runtime matrix artifacts"])
            jobs.append(dict(id=identifier, name=name, run_id=run['id'], head_sha=sha, run_attempt=1,
                status="completed", conclusion="success", completed_at=now.isoformat(),
                steps=[dict(name=step,status="completed",conclusion="success") for step in steps]))
        ui=next(j for j in jobs if j['id']==planner.INTERNAL_REPORT_CORRECTION_UI_JOB)
        ui['conclusion']='failure';ui['steps'][1]['conclusion']='failure'
        jobs.append(dict(id=planner.INTERNAL_REPORT_CORRECTION_BUILD_JOB, name=planner.BUILD,
            run_id=run['id'], head_sha=sha, run_attempt=1, status="completed", conclusion="failure",
            steps=[dict(name="Verify sharing release privacy gates",status="completed",conclusion="failure")]))
        record = dict(schema_version=1, repository=repository, head_sha=sha, scope=scope.INTERNAL_REPORT_SCOPE,
            required_jobs=list(planner.required_jobs_from_scope(scope.INTERNAL_REPORT_SCOPE)),
            required_backend_runs=planner.moderation_resolution_requirements(sha),
            evidence_run_id=None,evidence_sha=None,test_correction_evidence=None)
        import json
        responses = {f"{prefix}/runs/{run['id']}":run,
            f"{prefix}/runs/{run['id']}/jobs?filter=latest&per_page=100&page=1":dict(total_count=len(jobs),jobs=jobs),
            f"{prefix}/jobs/{planner.INTERNAL_REPORT_CORRECTION_BUILD_JOB}/logs":"the fixed synthetic failure log",
            f"{prefix}/jobs/{planner.INTERNAL_REPORT_CORRECTION_UI_JOB}/logs":"Executed 12 tests, with 1 failure (0 unexpected)\nPhotoPermissionUITests.swift:5864: error: testFamilyRecordKeepsOtherAuthorsWordsWhenPhotoIsWithdrawnAndRevokesAccess",
            f"{prefix}/jobs/{planner.INTERNAL_REPORT_CORRECTION_JOB_IDS[planner.PLAN_JOB]}/logs":"IOS_CI_PLAN_JSON="+json.dumps(record)}
        return run,jobs,responses,repository,now,hashlib.sha256(b"the fixed synthetic failure log").hexdigest()

    def test_correction_requires_two_debug_successes_and_exact_two_failures(self):
        def prove(mutation=None):
            run,jobs,responses,repository,now,digest = self.correction_source_fixture()
            ui_digest=__import__("hashlib").sha256(responses[f"/repos/{repository}/actions/jobs/{planner.INTERNAL_REPORT_CORRECTION_UI_JOB}/logs"].encode()).hexdigest()
            if mutation: mutation(run,jobs,responses)
            for response in responses.values():
                if isinstance(response,dict) and 'jobs' in response: response['total_count']=len(jobs)
            with patch.object(planner,"internal_report_recovery_diagnostic_ready",return_value=True), \
                    patch.object(planner,"INTERNAL_REPORT_CORRECTION_UI_LOG_SHA256",ui_digest), \
                    patch.object(planner,"internal_report_correction_inputs",return_value=True), \
                    patch.object(planner,"INTERNAL_REPORT_CORRECTION_LOG_SHA256",digest), \
                    patch.object(planner,"git",return_value="d"*40):
                return planner.internal_report_correction_source("c"*40,repository,responses.__getitem__,now)
        got=prove()
        self.assertEqual(got['sha'],planner.INTERNAL_REPORT_CORRECTION_SOURCE)
        self.assertEqual(got['candidate_sha'],"c"*40)
        self.assertEqual(len(got['jobs']),2)
        self.assertEqual(got['owning_jobs_to_execute'],[planner.BUILD,planner.lane_job(scope.INTERNAL_REPORT_SCOPE,'app-ui')])
        for mutation in (
            lambda r,j,a:r.update(status="in_progress"),
            lambda r,j,a:r.update(conclusion="success"),
            lambda r,j,a:r.update(head_sha="e"*40),
            lambda r,j,a:r.update(run_attempt=2),
            lambda r,j,a:j[1].update(conclusion="failure"),
            lambda r,j,a:j[2].update(status="in_progress"),
            lambda r,j,a:j[3].update(conclusion="skipped"),
            lambda r,j,a:j[3].update(conclusion="success"),
            lambda r,j,a:j[3].update(id=123),
            lambda r,j,a:a.__setitem__(next(k for k in a if k.endswith('/logs') and str(planner.INTERNAL_REPORT_CORRECTION_UI_JOB) in k),'different UI failure'),
            lambda r,j,a:j[1].update(id=123),
            lambda r,j,a:j[2]['steps'][0].update(conclusion="skipped"),
            lambda r,j,a:j[-1]['steps'][0].update(name="Unknown product failure"),
            lambda r,j,a:j.append(dict(j[-1],id=777)),
            lambda r,j,a:a.__setitem__(next(k for k in a if k.endswith('/logs') and str(planner.INTERNAL_REPORT_CORRECTION_BUILD_JOB) in k),'different failure'),
        ):
            with self.subTest(mutation=mutation): self.assertIsNone(prove(mutation))

    def test_fixed_new_diagnostic_requires_actual_one_case_success(self):
        run,jobs,responses,repository,now,_=self.correction_source_fixture()
        source=planner.INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_SOURCE
        run.update(id=planner.INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_RUN,head_sha=source,
            head_branch='diagnostic/internal-report-ui-20261011',path='.github/workflows/ios-ui-diagnostic.yml',
            event='workflow_dispatch',conclusion='success',display_title='UI diagnosis: MomentDeliveryComposerUITests/testFamilyRecordKeepsOtherAuthorsWordsWhenPhotoIsWithdrawnAndRevokesAccess')
        job=dict(id=planner.INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_JOB,name='Diagnostic only - up to three native UI tests (not release evidence)',run_id=run['id'],head_sha=source,run_attempt=1,status='completed',conclusion='success',completed_at=now.isoformat(),steps=[dict(name=n,status='completed',conclusion='success') for n in ('Validate diagnostic inputs before checkout','Check out the exact diagnostic commit','Run requested diagnostic tests with the existing fixture preparation','Upload diagnostic evidence only')])
        case='NekoWidgetUITests.MomentDeliveryComposerUITests testFamilyRecordKeepsOtherAuthorsWordsWhenPhotoIsWithdrawnAndRevokesAccess'
        log=f"Test Case '-[{case}]' started\nTest Case '-[{case}]' passed\nExecuted 1 test, with 0 failures (0 unexpected)"
        prefix=f'/repos/{repository}/actions'
        def prove(mutation=None):
            r,j=copy.deepcopy(run),copy.deepcopy(job);body=dict(total_count=1,jobs=[j]);logs=[log]
            if mutation:mutation(r,j,body,logs)
            api={f'{prefix}/runs/{r["id"]}':r,f'{prefix}/runs/{r["id"]}/attempts/1/jobs?per_page=100':body,f'{prefix}/jobs/{j["id"]}/logs':logs[0]}
            with patch.object(planner,'internal_report_recovery_diagnostic_inputs',return_value=True):
                return planner.internal_report_recovery_diagnostic_ready('c'*40,repository,api.__getitem__,now)
        self.assertTrue(prove())
        for mutation in (
            lambda r,j,b,l:r.update(status='in_progress',conclusion=None),
            lambda r,j,b,l:r.update(conclusion='failure'),
            lambda r,j,b,l:r.update(head_sha='e'*40),
            lambda r,j,b,l:r.update(run_attempt=2),
            lambda r,j,b,l:r.update(display_title='UI diagnosis: MomentDeliveryComposerUITests/testOther'),
            lambda r,j,b,l:j.update(id=123),
            lambda r,j,b,l:j.update(conclusion='skipped'),
            lambda r,j,b,l:j['steps'][2].update(conclusion='failure'),
            lambda r,j,b,l:b.update(total_count=2),
            lambda r,j,b,l:l.__setitem__(0,l[0].replace('passed','failed')),
            lambda r,j,b,l:l.__setitem__(0,l[0]+f"\nTest Case '-[{case}]' skipped"),
            lambda r,j,b,l:l.__setitem__(0,l[0].replace('Executed 1 test','Executed 2 tests')),
        ):
            with self.subTest(mutation=mutation):self.assertFalse(prove(mutation))

    def test_new_diagnostic_inputs_allow_only_exact_release_pairs_not_ui_changes(self):
        source=planner.INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_SOURCE;head='c'*40
        path='NekoWidget/ci/release-testflight.py';before='d'*40;after=scope.INTERNAL_REPORT_BLOBS[path][1]
        def prove(extra='',approved=True):
            raw=f':100644 100644 {before} {after} M\0{path}\0'+extra
            def git(*a):
                if a[0]=='merge-base':return ''
                if a[0]=='diff':return raw
                return f'100644 blob {before}\t{path}'
            with patch.object(planner,'internal_report_candidate_inputs',return_value=approved),patch.object(planner,'git',side_effect=git):
                return planner.internal_report_recovery_diagnostic_inputs(source,head)
        self.assertTrue(prove());self.assertFalse(prove(approved=False))
        for path in (planner.INTERNAL_REPORT_CORRECTION_UI_PATH,'.github/workflows/ios-ui-diagnostic.yml','NekoWidget/Shared/Sharing/SharingAPIConfiguration.swift'):
            self.assertFalse(prove(f':100644 100644 {before} {after} M\0{path}\0'))

    def test_pending_recovery_diagnostic_never_authorizes_candidate(self):
        run,jobs,responses,repository,now,_=self.correction_source_fixture()
        with patch.object(planner,'internal_report_correction_inputs',return_value=True),patch.object(planner,'internal_report_recovery_diagnostic_inputs',return_value=False):
            self.assertIsNone(planner.internal_report_correction_source('c'*40,repository,responses.__getitem__,now))
        self.assertEqual(planner.correction_owning_jobs(scope.INTERNAL_REPORT_SCOPE,run['head_sha']),
                         (planner.BUILD,planner.lane_job(scope.INTERNAL_REPORT_SCOPE,'app-ui')))

    def test_corrected_graph_requires_fresh_complete_build_and_exact_plan_proof(self):
        import json
        run,_,_,repository,now,_=self.correction_source_fixture()
        head="c"*40
        run.update(id=900,head_sha=head,status="completed",conclusion="success")
        workflow=(ROOT/'.github/workflows/ios-build.yml').read_text(encoding='utf-8')
        block=workflow.split('  build-without-signing:\n',1)[1].split('  simulator-smoke-test:\n',1)[0]
        excluded={'Verify packaged icons and capture first launch','Upload icon display evidence','Upload build result bundle'}
        names=[n for n in re.findall(r'^      - name: (.+)$',block,re.M) if n not in excluded]
        self.assertEqual(len(names),39)
        jobs=[dict(id=901,name=planner.PLAN_JOB,run_id=900,head_sha=head,run_attempt=1,status='completed',conclusion='success',completed_at=now.isoformat(),steps=[dict(name='Select checks',status='completed',conclusion='success')]),
              dict(id=902,name=planner.BUILD,run_id=900,head_sha=head,run_attempt=1,status='completed',conclusion='success',completed_at=now.isoformat(),steps=[dict(name=n,status='completed',conclusion='success') for n in names])]
        jobs.append(dict(id=903,name=planner.lane_job(scope.INTERNAL_REPORT_SCOPE,'app-ui'),run_id=900,head_sha=head,run_attempt=1,status='completed',conclusion='success',completed_at=now.isoformat(),steps=[dict(name=n,status='completed',conclusion='success') for n in ('Check out repository','Run sharing runtime matrix','Upload sharing runtime matrix artifacts')]))
        proof=dict(kind='internal-report-release-plist-ui-correction-v1',sha=planner.INTERNAL_REPORT_CORRECTION_SOURCE,candidate_sha=head)
        record=dict(schema_version=1,repository=repository,head_sha=head,scope=scope.INTERNAL_REPORT_SCOPE,
            required_jobs=list(planner.required_jobs_from_scope(scope.INTERNAL_REPORT_SCOPE)),
            required_backend_runs=planner.internal_report_requirements(head),evidence_run_id=None,evidence_sha=None,test_correction_evidence=proof)
        def prove(changed_jobs=None,changed_record=None,backend_failure=False):
            with patch.object(planner,'internal_report_correction_inputs',return_value=True), \
                    patch.object(planner,'internal_report_correction_source',return_value=proof), \
                    patch.object(planner,'git',return_value=workflow), \
                    patch.object(planner,'internal_report_backend_evidence',side_effect=ValueError('missing current backend') if backend_failure else None,return_value={'fresh_sha':head}) as backend:
                cases=[test.replace('NekoWidgetUITests/','NekoWidgetUITests.',1).replace('/',' ') for test in scope.native_tests(scope.INTERNAL_REPORT_SCOPE)]
                ui_log='\n'.join(f"Test Case '-[{case}]' {status}" for case in cases for status in ('started','passed'))+'\nExecuted 12 tests, with 0 failures (0 unexpected)'
                api=lambda path:ui_log if '/903/' in path else 'IOS_CI_PLAN_JSON='+json.dumps(changed_record or record)
                result=planner.internal_report_correction_graph(run,head,planner.required_jobs_from_scope(scope.INTERNAL_REPORT_SCOPE),api,now,changed_jobs or jobs)
                if result is not None:self.assertEqual(backend.call_args.args[0],head)
                return result
        self.assertEqual(prove(),{'native_evidence':proof,'backend_evidence':{'fresh_sha':head}})
        for index in range(len(names)):
            changed=copy.deepcopy(jobs);changed[1]['steps'][index]['conclusion']='skipped'
            self.assertIsNone(prove(changed_jobs=changed))
        self.assertIsNone(prove(changed_record=dict(record,test_correction_evidence=dict(proof,candidate_sha='e'*40))))
        changed=copy.deepcopy(jobs);changed[1]['head_sha']='e'*40
        self.assertIsNone(prove(changed_jobs=changed))
        changed=copy.deepcopy(jobs);changed[2]['conclusion']='failure'
        self.assertIsNone(prove(changed_jobs=changed))
        changed=copy.deepcopy(jobs);changed[2]['steps'][1]['conclusion']='skipped'
        self.assertIsNone(prove(changed_jobs=changed))
        self.assertIsNone(prove(changed_jobs=jobs[:2]))
        with self.assertRaises(ValueError):prove(backend_failure=True)

    def test_internal_preflight_main_dispatches_correction_and_preserves_failed_history(self):
        import contextlib, datetime as dt, io, json
        spec=importlib.util.spec_from_file_location('internal_preflight_entrypoint',Path(__file__).with_name('preflight-ci.py'))
        preflight=importlib.util.module_from_spec(spec);spec.loader.exec_module(preflight)
        p=preflight.planner;head='c'*40;now=dt.datetime.now(dt.timezone.utc)
        case='MomentDeliveryComposerUITests/testFamilyRecordKeepsOtherAuthorsWordsWhenPhotoIsWithdrawnAndRevokesAccess'
        source=dict(id=p.INTERNAL_REPORT_CORRECTION_RUN,head_sha=p.INTERNAL_REPORT_CORRECTION_SOURCE,
            head_branch=p.INTERNAL_REPORT_CORRECTION_BRANCH,event='push',run_attempt=1,path='.github/workflows/ios-build.yml',
            status='completed',conclusion='failure',created_at=(now-dt.timedelta(minutes=30)).isoformat(),updated_at=now.isoformat(),
            failed_tests=[case],unsupported_failed_tests=['DisabledReleaseConfigTests/test_disabled_permission_copy_and_share_activation_are_truthful'])
        diagnostic=dict(id=p.INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_RUN,head_sha=p.INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_SOURCE,
            head_branch='diagnostic/internal-report-ui-20261011',event='workflow_dispatch',run_attempt=1,path=preflight.DIAGNOSTIC_WORKFLOW,
            display_title='UI diagnosis: '+case,status='completed',conclusion='success',created_at=(now-dt.timedelta(minutes=18)).isoformat(),updated_at=now.isoformat(),
            failed_tests=[],unsupported_failed_tests=[],diagnostic_evidence=dict(head=head,source_sha=p.INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_SOURCE,run_attempt=1,job_id=p.INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_JOB,started_at=(now-dt.timedelta(minutes=18)).isoformat(),results={case:'passed'}))
        proof=dict(kind='internal-report-release-plist-ui-correction-v1',candidate_sha=head,run_id=source['id'],sha=source['head_sha'],
            failed_build_job_id=p.INTERNAL_REPORT_CORRECTION_BUILD_JOB,failed_build_log_sha256=p.INTERNAL_REPORT_CORRECTION_LOG_SHA256,
            failed_ui_job_id=p.INTERNAL_REPORT_CORRECTION_UI_JOB,failed_ui_log_sha256=p.INTERNAL_REPORT_CORRECTION_UI_LOG_SHA256,
            owning_jobs_to_execute=[p.BUILD,p.lane_job(p.INTERNAL_REPORT_SCOPE,'app-ui')],
            jobs=[dict(name=n,job_id=i) for n,i in p.INTERNAL_REPORT_CORRECTION_JOB_IDS.items() if n not in {p.PLAN_JOB,p.lane_job(p.INTERNAL_REPORT_SCOPE,'app-ui')}])
        candidate=dict(scope=p.INTERNAL_REPORT_SCOPE,head=head,required_jobs=list(p.required_jobs_from_scope(p.INTERNAL_REPORT_SCOPE)),
            target_minutes=200,cost={'status':'unmeasured'},ready=False)
        with tempfile.TemporaryDirectory() as directory:
            history=Path(directory)/'history.json';history.write_text(json.dumps({'upload_minutes':0}),encoding='utf-8')
            output=io.StringIO()
            with patch.object(preflight,'candidate_plan',return_value=candidate),patch.object(preflight,'read_task_runs',return_value=[source,diagnostic]), \
                    patch.object(preflight,'read_other_active_ios_runs',return_value=[]),patch.object(preflight.planner,'git',return_value=p.INTERNAL_REPORT_CORRECTION_BRANCH), \
                    patch.object(preflight.planner,'find_test_correction_evidence',return_value=proof) as correction,patch.object(preflight.os,'chdir'),contextlib.redirect_stdout(output):
                code=preflight.main(['--history',str(history),'--target-minutes','200'])
            self.assertEqual(code,0,output.getvalue());result=json.loads(output.getvalue())
        correction.assert_called_once()
        self.assertEqual(correction.call_args.args[:4],(head,p.INTERNAL_REPORT_CORRECTION_BRANCH,preflight.REPOSITORY,tuple(candidate['required_jobs'])))
        self.assertTrue(result['ready']);self.assertEqual(result['cost']['status'],'reference')
        self.assertEqual(result['cost']['owning_jobs'],proof['owning_jobs_to_execute'])
        self.assertEqual(result['full_cost_before_correction'],{'status':'unmeasured'})
        self.assertEqual(result['task']['failed_runs'],[source['id']]);self.assertEqual(result['task']['diagnostic_runs'],[diagnostic['id']])
        self.assertGreaterEqual(result['task']['projected_total_minutes'],90)

    def test_internal_task_gate_preserves_failure_active_unknown_and_cumulative_cost(self):
        import datetime as dt
        spec=importlib.util.spec_from_file_location('internal_report_budget',Path(__file__).with_name('preflight-ci.py'))
        preflight=importlib.util.module_from_spec(spec);spec.loader.exec_module(preflight)
        p=preflight.planner
        now=dt.datetime(2026,10,11,13,tzinfo=dt.timezone.utc)
        head='c'*40
        source=dict(id=p.INTERNAL_REPORT_CORRECTION_RUN,head_sha=p.INTERNAL_REPORT_CORRECTION_SOURCE,
            head_branch=p.INTERNAL_REPORT_CORRECTION_BRANCH,event='push',run_attempt=1,
            path='.github/workflows/ios-build.yml',status='completed',conclusion='failure',
            created_at=(now-dt.timedelta(minutes=30)).isoformat(),updated_at=now.isoformat(),
            failed_tests=[],unsupported_failed_tests=['DisabledReleaseConfigTests/test_disabled_permission_copy_and_share_activation_are_truthful'])
        proof=dict(kind='internal-report-release-plist-ui-correction-v1',candidate_sha=head,
            run_id=source['id'],sha=source['head_sha'],failed_build_job_id=p.INTERNAL_REPORT_CORRECTION_BUILD_JOB,
            failed_build_log_sha256=p.INTERNAL_REPORT_CORRECTION_LOG_SHA256,failed_ui_job_id=p.INTERNAL_REPORT_CORRECTION_UI_JOB,failed_ui_log_sha256=p.INTERNAL_REPORT_CORRECTION_UI_LOG_SHA256,owning_jobs_to_execute=[p.BUILD,p.lane_job(p.INTERNAL_REPORT_SCOPE,'app-ui')],
            jobs=[dict(name=n,job_id=i) for n,i in p.INTERNAL_REPORT_CORRECTION_JOB_IDS.items() if n not in {p.PLAN_JOB,p.lane_job(p.INTERNAL_REPORT_SCOPE,"app-ui")}])
        result=dict(scope=p.INTERNAL_REPORT_SCOPE,head=head,required_jobs=list(p.required_jobs_from_scope(p.INTERNAL_REPORT_SCOPE)),
            target_minutes=200,cost={'status':'unmeasured'},ready=False)
        measured=preflight.internal_report_correction_cost(result,proof,False,{'upload_minutes':0})
        got=preflight.apply_task_gate(copy.deepcopy(measured),[source],now,correction_evidence=proof)
        self.assertTrue(got['ready']);self.assertEqual(got['task']['failed_runs'],[source['id']])
        self.assertEqual(got['task']['projected_total_minutes'],90)
        active=dict(source,id=999,status='in_progress',conclusion=None,head_sha=head)
        self.assertIn('ci_already_running',preflight.apply_task_gate(copy.deepcopy(measured),[source,active],now,correction_evidence=proof)['task']['blockers'])
        unknown=dict(source,id=998,head_sha=head,unsupported_failed_tests=[])
        self.assertIn('internal_report_has_unresolved_candidate_failure',preflight.apply_task_gate(copy.deepcopy(measured),[source,unknown],now,correction_evidence=proof)['task']['blockers'])
        small=dict(measured,target_minutes=45)
        self.assertIn('cumulative_cost_requires_replanning',preflight.apply_task_gate(small,[source],now,correction_evidence=proof)['task']['blockers'])
        for wrong in (dict(proof,failed_build_log_sha256='e'*64),dict(proof,jobs=[]),dict(proof,candidate_sha='d'*40)):
            with self.assertRaises(ValueError):preflight.apply_task_gate(copy.deepcopy(measured),[source],now,correction_evidence=wrong)
        with self.assertRaises(ValueError):preflight.apply_task_gate(copy.deepcopy(measured),[dict(source,run_attempt=2)],now,correction_evidence=proof)

    def backend_fixture(self):
        spec = importlib.util.spec_from_file_location("internal_report_backend_fixture", Path(__file__).with_name("test-plan-ios-ci.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        fixture = module.ModerationResolutionBackendEvidenceTests()
        fixture.setUp()
        return fixture

    def test_internal_backends_accept_dispatch_only_for_strictly_absent_push(self):
        fixture = self.backend_fixture()
        responses = fixture.responses
        for index in fixture.indexes:
            dispatch = index.replace("event=push", "event=workflow_dispatch")
            responses[dispatch] = copy.deepcopy(responses[index])
            for run in responses[dispatch]["workflow_runs"]:
                run["event"] = "workflow_dispatch"
            responses[index] = {"total_count": 0, "workflow_runs": []}
        with patch.object(planner, "internal_report_candidate_inputs", return_value=True):
            result = planner.internal_report_backend_evidence(fixture.sha, fixture.fixture.repo, responses.__getitem__, fixture.now)
            self.assertEqual(sum(len(value["job_ids"]) for value in result.values()), 5)
            self.assertTrue(all(value["sha"] == fixture.sha and value["event"] == "workflow_dispatch" for value in result.values()))
            with self.assertRaises(ValueError):
                planner.moderation_resolution_backend_evidence(fixture.sha, fixture.fixture.repo, responses.__getitem__, fixture.now)
        with patch.object(planner, "internal_report_candidate_inputs", return_value=False), self.assertRaises(ValueError):
            planner.internal_report_backend_evidence(fixture.sha, fixture.fixture.repo, responses.__getitem__, fixture.now)

    def test_internal_backends_never_replace_failed_pending_incomplete_or_wrong_source_push(self):
        for value in ("failure", "in_progress", "wrong_sha", "incomplete", "extra_index_field", "boolean_count"):
            fixture = self.backend_fixture()
            key = fixture.indexes[0]
            response = fixture.responses[key]
            if value == "failure": response["workflow_runs"][0]["conclusion"] = "failure"
            elif value == "in_progress": response["workflow_runs"][0]["status"] = "in_progress"
            elif value == "wrong_sha": response["workflow_runs"][0]["head_sha"] = "e" * 40
            elif value == "incomplete": response["total_count"] += 1
            elif value == "extra_index_field": fixture.responses[key] = {"total_count": 0, "workflow_runs": [], "unknown": True}
            else: fixture.responses[key] = {"total_count": False, "workflow_runs": []}
            calls = []
            def api(path):
                calls.append(path)
                return fixture.responses[path]
            with patch.object(planner, "internal_report_candidate_inputs", return_value=True), self.assertRaises(ValueError):
                planner.internal_report_backend_evidence(fixture.sha, fixture.fixture.repo, api, fixture.now)
            self.assertFalse(any("event=workflow_dispatch" in path for path in calls))

    def diagnostic_fixture(self, *, source=None, raw_change=None, extra=None, approved=True, ancestor=True):
        spec = importlib.util.spec_from_file_location("internal_report_preflight", Path(__file__).with_name("preflight-ci.py"))
        preflight = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(preflight)
        source = source or preflight.INTERNAL_REPORT_DIAGNOSTIC_SOURCE
        head = "c" * 40
        fixture = preflight.INTERNAL_REPORT_RELEASE_FIXTURE
        before = preflight.INTERNAL_REPORT_RELEASE_FIXTURE_BLOBS[0]
        after = scope.INTERNAL_REPORT_BLOBS[fixture][1]
        fields = [":100644", "100644", before, after, "M"]
        if raw_change:
            raw_change(fields)
        records = [" ".join(fields), fixture]
        for path in sorted(scope.INTERNAL_REPORT_CONTROLS):
            records.extend([f":100644 100644 {'d' * 40} {'e' * 40} M", path])
        if extra is not None:
            records.extend(extra)
        raw = "\0".join(records) + "\0"

        def git(*arguments):
            if arguments == ("ls-tree", source, "--", fixture):
                return f"100644 blob {before}\t{fixture}"
            if arguments == ("merge-base", "--is-ancestor", source, head):
                if not ancestor:
                    raise subprocess.CalledProcessError(1, ["git", *arguments])
                return ""
            if arguments == ("merge-base", "refs/remotes/origin/main", head):
                return "base"
            if arguments == ("diff", "--name-only", "base", head):
                return "\n".join(sorted(scope.INTERNAL_REPORT_PATHS))
            if arguments == ("diff", "--raw", "--no-renames", "--no-abbrev", "-z", source, head):
                return raw
            raise AssertionError("Unexpected diagnostic fixture lookup: " + repr(arguments))

        with patch.object(preflight.planner, "git", side_effect=git), patch.object(
                preflight.planner, "internal_report_only", return_value=approved) as selector:
            result = preflight.diagnostic_source_matches(source, head)
            if source == preflight.INTERNAL_REPORT_DIAGNOSTIC_SOURCE:
                selector.assert_not_called()
            return result

    def test_fixed_diagnostic_forwards_only_complete_approved_candidate(self):
        self.assertFalse(self.diagnostic_fixture())
        self.assertFalse(self.diagnostic_fixture(approved=False))
        self.assertFalse(self.diagnostic_fixture(ancestor=False))
        self.assertFalse(self.diagnostic_fixture(source="b" * 40))

    def test_diagnostic_rejects_wrong_fixture_modes_duplicates_and_native_changes(self):
        for index, value in ((0, ":100755"), (1, "120000"), (2, "1" * 40),
                             (3, "2" * 40), (4, "A")):
            self.assertFalse(self.diagnostic_fixture(raw_change=lambda fields, i=index, v=value: fields.__setitem__(i, v)))
        for path in ("NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift",
                     ".github/workflows/ios-ui-diagnostic.yml", "NekoWidget/Shared/Sharing/SharingAPIConfiguration.swift"):
            self.assertFalse(self.diagnostic_fixture(extra=[f":100644 100644 {'d' * 40} {'e' * 40} M", path]))
        self.assertFalse(self.diagnostic_fixture(extra=[
            f":100644 100644 {'d' * 40} {'e' * 40} M", sorted(scope.INTERNAL_REPORT_CONTROLS)[0]]))

    def selector_fixture(self, *, raw_change=None, changed_control=False, changed_tree=False):
        paths = sorted(scope.INTERNAL_REPORT_PATHS)
        records = []
        for path in paths:
            before, after = scope.INTERNAL_REPORT_BLOBS[path]
            mode, status = ("000000", "A") if before == "0" * 40 else ("100644", "M")
            fields = [":" + mode, "100644", before, after, status]
            if raw_change is not None and path == paths[0]:
                raw_change(fields)
            records += [" ".join(fields), path]
        raw = "\0".join(records) + "\0"
        tree = "100644 blob " + "d" * 40 + "\tNekoWidget/Shared/Unchanged.swift\0"
        control = "100644 blob " + "e" * 40 + "\t"

        def git(*arguments):
            if arguments[:1] == ("diff",):
                return raw
            if arguments[:1] == ("merge-base",):
                return "approved"
            if arguments[:3] == ("ls-tree", "-r", "-z"):
                return tree + ("100644 blob " + "f" * 40 + "\textra.swift\0"
                               if changed_tree and arguments[3] == "head" else "")
            if arguments[:1] == ("ls-tree",) and arguments[2] == "--":
                return control + arguments[3] + ("changed" if changed_control and arguments[1] == "head" else "")
            raise AssertionError("Unexpected fixture git lookup: " + repr(arguments))

        import hashlib
        with patch.object(planner, "git", side_effect=git), patch.object(
            planner, "INTERNAL_REPORT_IMMUTABLE_TREE_SHA256", hashlib.sha256(tree.encode()).hexdigest()
        ):
            return planner.internal_report_only(paths, "base", "head")

    def test_exact_raw_blobs_and_approved_controls_accept(self):
        self.assertTrue(self.selector_fixture())

    def test_changed_blob_mode_type_or_status_refuse(self):
        for index, value in ((0, ":100755"), (1, "120000"), (2, "1" * 40),
                             (3, "2" * 40), (4, "D")):
            self.assertFalse(self.selector_fixture(raw_change=lambda fields, i=index, v=value: fields.__setitem__(i, v)), (index, value))

    def test_unapproved_controls_and_changed_remaining_tree_refuse(self):
        self.assertFalse(self.selector_fixture(changed_control=True))
        self.assertFalse(self.selector_fixture(changed_tree=True))

    def test_complete_graph_keeps_build_photos_runtime_and_owning_ui(self):
        selected = scope.INTERNAL_REPORT_SCOPE
        self.assertIn(selected, scope.SCOPES)
        expected = scope.MODERATION_RESOLUTION_TESTS + ("NekoWidgetUITests/MomentDeliveryComposerUITests/testInternalReportActionUsesExplicitAvailabilityAndConsent",)
        self.assertEqual(scope.native_tests(selected), expected)
        self.assertEqual(scope.lanes(selected), ("runtime", "app-ui"))
        self.assertEqual(planner.required_jobs_from_scope(selected), (planner.BUILD, planner.BOOTSTRAP_SMOKE, scope.lane_job(selected, "runtime"), scope.lane_job(selected, "app-ui")))
        self.assertEqual(planner.required_jobs(sorted(scope.INTERNAL_REPORT_PATHS), selected), planner.required_jobs_from_scope(selected))

    def test_partial_extra_duplicate_or_wrong_inputs_use_full(self):
        selected = scope.INTERNAL_REPORT_SCOPE
        paths = sorted(scope.INTERNAL_REPORT_PATHS)
        self.assertTrue(scope.accepts_paths(selected, paths))
        for path in paths:
            self.assertFalse(scope.accepts_paths(selected, set(paths) - {path}))
            self.assertEqual(planner.required_jobs(sorted(set(paths) - {path}), selected), planner.FULL)
        for extra in ("NekoWidget/NekoWidget/App/NekoWidgetApp.swift", "NekoWidget/SharingService/src/index.ts"):
            self.assertFalse(scope.accepts_paths(selected, paths + [extra]))
        self.assertFalse(scope.accepts_paths(selected, paths + [paths[0]]))
        with patch.object(planner, "reviewed_hub_only", return_value=False):
            self.assertFalse(planner.internal_report_only(paths, "a" * 40, "b" * 40))


if __name__ == "__main__":
    unittest.main()
