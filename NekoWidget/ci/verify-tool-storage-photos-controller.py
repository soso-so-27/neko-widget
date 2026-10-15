#!/usr/bin/env python3
"""Read-only source gate for one formal full Photos execution; no retry/mutation."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.parse

REPOSITORY = 'soso-so-27/neko-widget'
WORKFLOW = '.github/workflows/tool-storage-photos-validation.yml'
SOURCE = 'fb5a1dce3696703e3942c77c34287c9319886eb1'
TREE = '6720274ee20b7d7649c86c62687f425455f1d28f'
PARENTS = ['052910e36722874685c6dc4295f01e50dfc40e19', 'c033abe3de5dabb04636d4707ceb370a4a0fd3e5']
HARNESS = 'NekoWidget/ci/run-simulator-smoke.sh'
HARNESS_SHA256 = '11a1dac0485a951c4a55ffabc50f8d0f7225601210c7fc32601ea00f309c92d9'
RUN = 38667725132
MARKER = 'FORMAL_PHOTOS_SOURCE_JSON='
ORIGINAL = {'id': 38667725132, 'head_sha': 'fb5a1dce3696703e3942c77c34287c9319886eb1', 'head_branch': 'codex/tool-storage-fresh-validation-20261015', 'event': 'push', 'workflow_id': 335014238, 'path': '.github/workflows/ios-build.yml', 'run_number': 1857, 'run_attempt': 1, 'created_at': '2026-10-15T01:49:33Z', 'run_started_at': '2026-10-15T01:49:33Z', 'updated_at': '2026-10-15T02:27:23Z', 'status': 'completed', 'conclusion': 'failure', 'repository': {'id': 1335079243, 'full_name': 'soso-so-27/neko-widget'}, 'head_repository': {'id': 1335079243, 'full_name': 'soso-so-27/neko-widget'}, 'head_commit': {'id': 'fb5a1dce3696703e3942c77c34287c9319886eb1', 'tree_id': '6720274ee20b7d7649c86c62687f425455f1d28f'}}
QUEUED = {'id': 38667725132, 'head_sha': 'fb5a1dce3696703e3942c77c34287c9319886eb1', 'head_branch': 'codex/tool-storage-fresh-validation-20261015', 'event': 'push', 'workflow_id': 335014238, 'path': '.github/workflows/ios-build.yml', 'run_number': 1857, 'run_attempt': 1, 'created_at': '2026-10-15T01:49:33Z', 'run_started_at': '2026-10-15T02:37:02Z', 'updated_at': '2026-10-15T02:37:02Z', 'status': 'queued', 'conclusion': None, 'repository': {'id': 1335079243, 'full_name': 'soso-so-27/neko-widget'}, 'head_repository': {'id': 1335079243, 'full_name': 'soso-so-27/neko-widget'}, 'head_commit': {'id': 'fb5a1dce3696703e3942c77c34287c9319886eb1', 'tree_id': '6720274ee20b7d7649c86c62687f425455f1d28f'}}
ORIGINAL_JOB_IDS = [116203398345, 116203650095, 116203650126, 116203650168, 116203650195, 116207475176, 116210547790]
ORIGINAL_JOBS_SHA256 = '6af2c2b3626df05a7635cb82f4681508c52b9b6974d06d53a13259df4b07f3ee'
ORIGINAL_ATTEMPT1_SHA256 = '4589373b8f337bd1e175521f74a574bbce697de771d8e7aea430ab1db30b9d2e'
# Exact failed preparation: Linux parent check only; Mac never executed.
FIRST_CONTROLLER = {'id': 38676316408, 'head_sha': 'd6b11049e128eb2d8f45434e7a5d61be52af8ba2', 'head_branch': 'main', 'event': 'workflow_dispatch', 'workflow_id': 385071462, 'path': '.github/workflows/tool-storage-photos-validation.yml', 'run_number': 1, 'run_attempt': 1, 'created_at': '2026-10-15T03:26:57Z', 'run_started_at': '2026-10-15T03:26:57Z', 'updated_at': '2026-10-15T03:27:11Z', 'status': 'completed', 'conclusion': 'failure', 'repository': {'id': 1335079243, 'full_name': 'soso-so-27/neko-widget'}, 'head_repository': {'id': 1335079243, 'full_name': 'soso-so-27/neko-widget'}, 'head_commit': {'id': 'd6b11049e128eb2d8f45434e7a5d61be52af8ba2', 'tree_id': 'd51aa017f87ee89006fd35d14f1837e897572e74'}}
FIRST_CONTROLLER_CRITICAL_SHA256 = '2a46f47f798e0371e981704fa0f3e6e5ba3e1b11a6ffc402718efa755c2d58f8'
FIRST_CONTROLLER_JOBS_SHA256 = '80e00027012f399929bc28fd078cc46ffd22151f5f9da9f7048853dac1beb08b'
FIRST_CONTROLLER_PAYLOAD_SHA256 = '3a0254b4dd137f21fabd9c45825a1b1081ba43de1721ee4c1b38c133fefbe4be'
FIRST_CONTROLLER_FAILURE_RAW_SHA256 = 'e83d162ec6c2f0610aa042f37e96ad9294cd336ab9e7811e1fa0bef8f64c2718'
FIRST_CONTROLLER_JOB_IDS = [116230623798, 116230680503]


def require(ok, message):
    if not ok:
        raise ValueError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'))


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def critical(value):
    require(isinstance(value, dict), 'Run response missing')
    result = {key: value.get(key) for key in (
        'id', 'head_sha', 'head_branch', 'event', 'workflow_id', 'path', 'run_number',
        'run_attempt', 'created_at', 'run_started_at', 'updated_at', 'status', 'conclusion')}
    for key in ('repository', 'head_repository'):
        require(isinstance(value.get(key), dict), 'Run repository missing')
        result[key] = {field: value[key].get(field) for field in ('id', 'full_name')}
    require(isinstance(value.get('head_commit'), dict), 'Run commit missing')
    result['head_commit'] = {key: value['head_commit'].get(key) for key in ('id', 'tree_id')}
    for key in ('id', 'workflow_id', 'run_number', 'run_attempt'):
        require(type(result[key]) is int, 'Run numeric identity must be an integer')
    return result


def validate_history(current, attempt1, payload, now):
    require(critical(current) == QUEUED, 'Original queued row changed; do not replace new execution')
    require(critical(attempt1) == ORIGINAL, 'Immutable original attempt1 failure changed')
    require(digest(critical(attempt1)) == ORIGINAL_ATTEMPT1_SHA256, 'Original attempt digest changed')
    require(isinstance(payload, dict) and type(payload.get('total_count')) is int
        and payload['total_count'] == 7 and isinstance(payload.get('jobs'), list)
        and len(payload['jobs']) == 7, 'Original full seven-job history missing or extended')
    records = payload['jobs']
    require(all(isinstance(job, dict) and type(job.get('id')) is int for job in records), 'Invalid job identity')
    require([job['id'] for job in records] == ORIGINAL_JOB_IDS
        and digest(records) == ORIGINAL_JOBS_SHA256, 'Original complete job records changed')
    finished = dt.datetime.fromisoformat(ORIGINAL['updated_at'].replace('Z', '+00:00'))
    require(dt.timedelta(0) <= now - finished <= dt.timedelta(hours=24), 'Original history is stale')


def validate_environment(env):
    require(env.get('GITHUB_EVENT_NAME') == 'workflow_dispatch'
        and env.get('GITHUB_REF') == 'refs/heads/main'
        and env.get('GITHUB_REPOSITORY') == REPOSITORY
        and env.get('GITHUB_RUN_ATTEMPT') == '1', 'Expected one main controller dispatch')
    sha = env.get('GITHUB_SHA', '')
    require(re.fullmatch('[0-9a-f]{40}', sha) is not None
        and env.get('NEKO_FORMAL_PHOTOS_CONTROLLER_REF') == sha
        and env.get('NEKO_FORMAL_PHOTOS_SOURCE_REF') == SOURCE, 'Unapproved controller/source input')
    require(re.fullmatch('[1-9][0-9]*', env.get('GITHUB_RUN_ID', '')) is not None, 'Controller run missing')
    return sha, int(env['GITHUB_RUN_ID'])


def git(root, *args):
    return subprocess.check_output(['git', *args], cwd=root, text=True, encoding='utf-8', timeout=30).strip()


def verify_local(controller, product, env):
    sha, run_id = validate_environment(env)
    require(git(controller, 'rev-parse', 'HEAD') == sha, 'Controller checkout changed')
    require(git(controller, 'status', '--porcelain=v1', '--untracked-files=all') == '', 'Controller checkout dirty')
    require(git(product, 'rev-parse', 'HEAD') == SOURCE
        and git(product, 'rev-parse', 'HEAD^{tree}') == TREE
        and git(product, 'show', '-s', '--format=%P', 'HEAD').split() == PARENTS, 'Product checkout/tree/parents changed')
    require(git(product, 'status', '--porcelain=v1', '--untracked-files=all') == '', 'Product checkout dirty')
    require(hashlib.sha256((product / HARNESS).read_bytes()).hexdigest() == HARNESS_SHA256, 'Original smoke harness changed')
    return sha, run_id


def read_api(path):
    # Fixed GET paths only; no retries, output echo or token/header logging.
    require(path.startswith('repos/' + REPOSITORY + '/actions/'), 'Unexpected API recipient')
    result = subprocess.run(['gh', 'api', '--hostname', 'github.com', '--method', 'GET', path],
        text=True, encoding='utf-8', capture_output=True, timeout=45,
        env={**os.environ, 'GH_PROMPT_DISABLED': '1', 'GH_DEBUG': ''})
    require(result.returncode == 0, 'Read-only GitHub observation failed; stop without retry')
    value = json.loads(result.stdout)
    require(isinstance(value, dict), 'Invalid API observation')
    return value


def first_failure_log_digest(raw):
    require(isinstance(raw, str), 'First failure raw log missing')
    # Match the approved planner's exact raw-log digest, retaining any BOM.
    return hashlib.sha256((raw.replace('\r\n', '\n').rstrip('\n') + '\n').encode()).hexdigest()


def validate_first_controller(run, payload, raw):
    require(critical(run) == FIRST_CONTROLLER
        and digest(critical(run)) == FIRST_CONTROLLER_CRITICAL_SHA256,
        'Known first controller failure changed')
    require(isinstance(payload, dict) and type(payload.get('total_count')) is int
        and payload['total_count'] == 2 and isinstance(payload.get('jobs'), list)
        and len(payload['jobs']) == 2 and digest(payload) == FIRST_CONTROLLER_PAYLOAD_SHA256
        and digest(payload['jobs']) == FIRST_CONTROLLER_JOBS_SHA256,
        'First controller complete two-job history changed')
    jobs = payload['jobs']
    require([job.get('id') for job in jobs] == FIRST_CONTROLLER_JOB_IDS,
        'Known first controller jobs differ')
    linux, mac = jobs
    require((linux.get('status'), linux.get('conclusion')) == ('completed', 'failure')
        and (mac.get('status'), mac.get('conclusion')) == ('completed', 'skipped')
        and mac.get('steps') == []
        and all(step.get('status') == 'completed' for step in linux.get('steps', []))
        and [(step.get('name'), step.get('number'), step.get('conclusion'))
            for step in linux.get('steps', []) if step.get('conclusion') != 'success']
            == [('Verify fixed source and original history', 4, 'failure')],
        'Known first failure was not solely pre-native source verification')
    require(first_failure_log_digest(raw) == FIRST_CONTROLLER_FAILURE_RAW_SHA256,
        'Known first failure log changed')


def read_api_raw(path):
    require(path == 'repos/' + REPOSITORY + '/actions/jobs/116230623798/logs', 'Unexpected raw recipient')
    result = subprocess.run(['gh', 'api', '--hostname', 'github.com', '--method', 'GET',
        '--allow-escape-sequences', path], text=True, encoding='utf-8', capture_output=True, timeout=45,
        env={**os.environ, 'GH_PROMPT_DISABLED': '1', 'GH_DEBUG': ''})
    require(result.returncode == 0, 'First failure raw observation failed; stop without retry')
    return result.stdout


def validate_controller(identity, run, index, sha, run_id, first_run, first_jobs, first_raw):
    validate_first_controller(first_run, first_jobs, first_raw)
    require(identity.get('state') == 'active' and identity.get('path') == WORKFLOW
        and type(identity.get('id')) is int and identity['id'] == FIRST_CONTROLLER['workflow_id'],
        'Formal controller workflow differs')
    records = index.get('workflow_runs')
    require(type(index.get('total_count')) is int and index['total_count'] == 2
        and isinstance(records, list) and len(records) == 2
        and all(isinstance(row, dict) and type(row.get('id')) is int for row in records)
        and {row['id'] for row in records} == {FIRST_CONTROLLER['id'], run_id}
        and run_id != FIRST_CONTROLLER['id'] and sha != FIRST_CONTROLLER['head_sha'],
        'Expected only known failed controller and one corrected dispatch')
    by_id = {row['id']: row for row in records}
    require(critical(by_id[FIRST_CONTROLLER['id']]) == FIRST_CONTROLLER
        and critical(by_id[run_id]) == critical(run), 'Controller index metadata changed')
    require(type(run.get('id')) is int and run['id'] == run_id
        and run.get('head_sha') == sha and run.get('head_branch') == 'main'
        and run.get('event') == 'workflow_dispatch' and run.get('path') == WORKFLOW
        and run.get('workflow_id') == identity['id'] and type(run.get('run_attempt')) is int
        and run['run_attempt'] == 1 and run.get('status') == 'in_progress' and run.get('conclusion') is None
        and all(run.get(key, {}).get('full_name') == REPOSITORY
            and run[key].get('id') == 1335079243 for key in ('repository', 'head_repository')),
        'Actual corrected formal controller identity differs')


def controller_index_path():
    query = urllib.parse.urlencode({'event': 'workflow_dispatch', 'per_page': 100})
    return 'repos/' + REPOSITORY + '/actions/workflows/tool-storage-photos-validation.yml/runs?' + query


def precheck(controller, product, output, phase):
    require(phase in ('precheck', 'pre-native'), 'Invalid phase')
    sha, run_id = verify_local(controller, product, os.environ)
    prefix = 'repos/' + REPOSITORY + '/actions'
    identity = read_api(prefix + '/workflows/tool-storage-photos-validation.yml')
    index = read_api(controller_index_path())
    controller_run = read_api(prefix + '/runs/' + str(run_id))
    first_run = read_api(prefix + '/runs/' + str(FIRST_CONTROLLER['id']))
    first_jobs = read_api(prefix + '/runs/' + str(FIRST_CONTROLLER['id']) + '/jobs?filter=all&per_page=100&page=1')
    first_raw = read_api_raw(prefix + '/jobs/116230623798/logs')
    current = read_api(prefix + '/runs/' + str(RUN))
    attempt1 = read_api(prefix + '/runs/' + str(RUN) + '/attempts/1')
    jobs = read_api(prefix + '/runs/' + str(RUN) + '/jobs?filter=all&per_page=100&page=1')
    now = dt.datetime.now(dt.timezone.utc)
    observations = {'currentRun': current, 'originalAttempt1': attempt1, 'originalAllJobs': jobs,
        'controllerIdentity': identity, 'controllerRun': controller_run, 'controllerIndex': index,
        'firstControllerRun': first_run, 'firstControllerAllJobs': first_jobs,
        'firstControllerFailureLogSHA256': first_failure_log_digest(first_raw)}
    output.mkdir(parents=True, exist_ok=False)
    # Save the full read responses before validation, including rejected drift.
    (output / 'observations.json').write_text(json.dumps(observations, indent=2) + '\n', encoding='utf-8')
    (output / 'first-controller-failure.log').write_text(first_raw, encoding='utf-8')
    validate_controller(identity, controller_run, index, sha, run_id, first_run, first_jobs, first_raw)
    validate_history(current, attempt1, jobs, now)
    manifest = {'schema_version': 1, 'kind': 'tool-storage-formal-photos-source-precheck-v1',
        'repository': REPOSITORY, 'controller_sha': sha, 'controller_ref': 'refs/heads/main',
        'controller_run_id': run_id, 'controller_run_attempt': 1, 'phase': phase,
        'product_sha': SOURCE, 'product_tree': TREE, 'product_parents': PARENTS,
        'harness_sha256': HARNESS_SHA256, 'original_run_id': RUN, 'original_run_attempt': 1,
        'original_status': current['status'], 'original_updated_at': current['updated_at'],
        'original_attempt1_conclusion': attempt1['conclusion'],
        'original_attempt1_created_at': attempt1['created_at'],
        'original_attempt1_finished_at': attempt1['updated_at'],
        'original_job_ids': ORIGINAL_JOB_IDS, 'original_jobs_sha256': ORIGINAL_JOBS_SHA256,
        'original_attempt1_sha256': ORIGINAL_ATTEMPT1_SHA256,
        'first_controller_run_id': FIRST_CONTROLLER['id'],
        'first_controller_sha': FIRST_CONTROLLER['head_sha'],
        'first_controller_run_critical_sha256': FIRST_CONTROLLER_CRITICAL_SHA256,
        'first_controller_jobs_sha256': FIRST_CONTROLLER_JOBS_SHA256,
        'first_controller_failure_raw_sha256': FIRST_CONTROLLER_FAILURE_RAW_SHA256,
        'observations_sha256': digest(observations),
        'checked_at': now.isoformat()}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(MARKER + canonical(manifest))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('precheck',))
    parser.add_argument('--controller', type=Path, required=True)
    parser.add_argument('--product', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--phase', choices=('precheck', 'pre-native'), required=True)
    args = parser.parse_args()
    precheck(args.controller.resolve(), args.product.resolve(), args.output.resolve(), args.phase)
