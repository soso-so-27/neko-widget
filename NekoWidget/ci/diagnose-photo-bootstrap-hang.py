#!/usr/bin/env python3
"""Observe the unchanged Photos grant; diagnostic only, never release evidence."""
from pathlib import Path
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import uuid

CI = Path(__file__).resolve().parent
BASE = "fb5a1dce3696703e3942c77c34287c9319886eb1"
BRANCH = "refs/heads/diagnostic/photo-bootstrap-stacks-20261015"
HELPER = "NekoWidget/ci/diagnose-photo-bootstrap-hang.py"
WORKFLOW = ".github/workflows/ios-ui-diagnostic.yml"
HARNESS = CI / "run-simulator-smoke.sh"
HARNESS_SHA256 = "11a1dac0485a951c4a55ffabc50f8d0f7225601210c7fc32601ea00f309c92d9"
CASE = "NekoWidgetUITests.PhotoPermissionUITests testGrantFullPhotoLibraryAccess"
EVENT = re.compile(r"Test Case '-\[([^\]]+)\]' (started|passed|failed|skipped)")


def replace_once(text, anchor, replacement):
    if text.count(anchor) != 1:
        raise ValueError("Original smoke anchor differs")
    return text.replace(anchor, replacement, 1)


def instrument(source):
    if hashlib.sha256(source.encode()).hexdigest() != HARNESS_SHA256:
        raise ValueError("Original smoke script differs")
    source = replace_once(source, 'MEMORY_SAMPLER_STOP_FILE=""\n',
        'MEMORY_SAMPLER_STOP_FILE=""\nPHOTO_HANG_MONITOR_PID=""\n')
    cleanup = '    trap - EXIT\n    set +e\n'
    source = replace_once(source, cleanup, cleanup + '''
    if [[ -n "${PHOTO_HANG_MONITOR_PID:-}" ]]; then
        touch "$ARTIFACT_DIRECTORY/photo-hang-stop"
        wait "$PHOTO_HANG_MONITOR_PID"
        printf '%s\\n' "$?" > "$ARTIFACT_DIRECTORY/photo-hang-monitor-exit-code.txt"
        PHOTO_HANG_MONITOR_PID=""
    fi
''')
    phase = '# BEGIN CI_SMOKE_PERMISSION_PHASE\n'
    source = replace_once(source, phase, phase + '''python3 "$PROJECT_DIRECTORY/ci/diagnose-photo-bootstrap-hang.py" monitor \\
    --udid "$SIMULATOR_UDID" --artifact "$ARTIFACT_DIRECTORY" &
PHOTO_HANG_MONITOR_PID=$!
''')
    checkpoint = '''python3 "$PHOTO_PERMISSION_VALIDATOR" \\
    --tcc-report "$ARTIFACT_DIRECTORY/tcc-permission-checkpoint.json" \\
    --log-directory "$PERMISSION_EVIDENCE_DIRECTORY/diagnostic-logs" \\
    --bundle-identifier "$APP_BUNDLE_ID"
'''
    return replace_once(source, checkpoint, checkpoint + '''
printf 'Diagnostic only: original grant and permission checkpoint completed.\\n'
exit 0
''')


def process_candidates(ps_text, udid, role='app'):
    # comm is executable path, never arguments. Refuse another Simulator,
    # UI runner, build process, basename-only match or multiple matches.
    names = {'app': 'NekoWidget', 'test': 'NekoWidgetUITests-Runner'}
    executable_name = names[role]
    pattern = re.compile(r"^/Users/[^/]+/Library/Developer/CoreSimulator/Devices/"
        + re.escape(udid) + r"/data/Containers/Bundle/Application/[0-9A-Fa-f-]{36}/"
        + re.escape(executable_name) + r"\.app/" + re.escape(executable_name) + r"$")
    candidates = []
    for line in ps_text.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[0].isdigit() and pattern.fullmatch(fields[1]):
            candidates.append((int(fields[0]), fields[1]))
    return candidates


def sample_process(role, ps, udid, artifact, target):
    item = {'role': role}
    try:
        candidates = process_candidates(ps, udid, role)
        item['candidateCount'] = len(candidates)
        if len(candidates) != 1:
            raise ValueError('Target executable unavailable or ambiguous')
        pid, executable = candidates[0]
        item.update(pid=pid, executable=executable)
        metrics = subprocess.check_output(['/bin/ps', '-ww', '-p', str(pid),
            '-o', 'pid=,pcpu=,rss=,state=,comm='], text=True, encoding='utf-8', timeout=5)
        fields = metrics.strip().split(None, 4)
        if len(fields) != 5 or fields[0] != str(pid) or fields[4] != executable:
            raise ValueError('Target changed before sampling')
        prefix = f'photo-hang-{target}s-{role}'
        (artifact / (prefix+'-process.txt')).write_text(metrics, encoding='utf-8')
        with (artifact / (prefix+'-sample-command.log')).open('w', encoding='utf-8') as output:
            result = subprocess.run(['/usr/bin/sample', str(pid), '3', '-file',
                str(artifact / (prefix+'-sample.txt'))], stdout=output, stderr=subprocess.STDOUT, timeout=8)
        item['sampleExitStatus'] = result.returncode
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        item['error'] = type(error).__name__ + ': ' + str(error)
    return item


def monitor(udid, artifact):
    if str(uuid.UUID(udid)).upper() != udid:
        raise ValueError("Expected the exact Simulator UDID")
    stop = artifact / 'photo-hang-stop'
    if stop.exists():
        raise ValueError("Stale diagnostic monitor marker")
    started = time.monotonic()
    test_started = None
    captured, observations, events, pending = set(), [], [], ''
    with (artifact / 'smoke-test.log').open(encoding='utf-8', errors='replace') as log:
        try:
            while not stop.exists() and time.monotonic() - started < 27 * 60:
                pending += log.read()
                lines = pending.split('\n')
                pending = lines.pop()
                for line in lines:
                    for case, outcome in EVENT.findall(line):
                        events.append([case, outcome])
                        if case == CASE and outcome == 'started' and test_started is None:
                            test_started = time.monotonic()
                if test_started is not None:
                    elapsed = time.monotonic() - test_started
                    terminal = any(case == CASE and state in ('passed', 'failed', 'skipped') for case, state in events)
                    for target in (25, 35, 45):
                        if target in captured or elapsed < target or terminal:
                            continue
                        captured.add(target)
                        item = {'targetSeconds': target, 'observedSeconds': elapsed,
                                'at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
                        try:
                            ps = subprocess.check_output(['/bin/ps', '-ww', '-axo', 'pid=,comm='],
                                text=True, encoding='utf-8', timeout=5)
                            with ThreadPoolExecutor(max_workers=2) as pool:
                                futures = [pool.submit(sample_process, role, ps, udid, artifact, target) for role in ('app','test')]
                                item['processes'] = [future.result() for future in futures]
                        except (OSError, ValueError, subprocess.SubprocessError) as error:
                            item['error'] = type(error).__name__ + ': ' + str(error)
                        observations.append(item)
                time.sleep(0.25)
        finally:
            (artifact / 'photo-hang-monitor.json').write_text(json.dumps({
                'diagnosticOnly': True, 'releaseEvidence': False, 'udid': udid,
                'sampleDurationSeconds': 3, 'sampleTargetsRelativeToXCTestStart': [25, 35, 45],
                'sampleRoles': ['app','test'], 'processSamplesParallel': True,
                'eventsObserved': events, 'observations': observations,
                'stopRequested': stop.exists(), 'durationSeconds': time.monotonic() - started}, indent=2) + '\n', encoding='utf-8')


def case_result(log):
    return EVENT.findall(log) == [(CASE, 'started'), (CASE, 'passed')]


def validate_source():
    if (os.environ.get('GITHUB_EVENT_NAME') != 'workflow_dispatch'
            or os.environ.get('GITHUB_REF') != BRANCH or os.environ.get('GITHUB_RUN_ATTEMPT') != '1'
            or os.environ.get('NEKO_PHOTO_HANG_SOURCE_SHA') != os.environ.get('GITHUB_SHA')):
        raise ValueError("Expected the exact one-off dispatch identity")
    def git(*argv):
        return subprocess.check_output(['git', *argv], cwd=CI, text=True, encoding='utf-8').rstrip('\n')
    head = git('rev-parse', 'HEAD')
    if not re.fullmatch(r'[0-9a-f]{40}', head) or head != os.environ['GITHUB_SHA']:
        raise ValueError("Diagnostic checkout differs")
    if git('show', '-s', '--format=%P', head) != BASE:
        raise ValueError("Expected one diagnostic commit directly on the frozen product")
    git('merge-base', '--is-ancestor', BASE, head)
    rows = git('diff', '--raw', '--no-renames', '--no-abbrev', '-z', BASE, head).split('\0')
    if rows[-1:] == ['']: rows.pop()
    expected = {WORKFLOW: ('M', ':100644', '100644'), HELPER: ('A', ':000000', '100644')}
    seen = set()
    if len(rows) != 2 * len(expected): raise ValueError("Unexpected diagnostic inputs")
    for index in range(0, len(rows), 2):
        fields, path = rows[index].split(), rows[index + 1]
        if path in seen or path not in expected or len(fields) != 5 or (fields[4], fields[0], fields[1]) != expected[path]:
            raise ValueError("Product, test or harness inputs changed")
        seen.add(path)
    if git('status', '--porcelain=v1', '--untracked-files=no'):
        raise ValueError("Diagnostic tracked checkout is dirty")
    return head


def run():
    head = validate_source()
    import ios_ci_scope as scope
    if scope.smoke_tests(scope.TOOL_STORAGE_SCOPE) != (
            'NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess',
            'NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary'):
        raise ValueError("Original smoke selection differs")
    expected_env = {'DEVELOPER_DIR': '/Applications/Xcode_26.3.app/Contents/Developer',
        'SMOKE_IOS_RUNTIME': 'com.apple.CoreSimulator.SimRuntime.iOS-18-6',
        'NEKO_IOS_RUNTIME_SCOPE': scope.TOOL_STORAGE_SCOPE}
    if any(os.environ.get(key) != value for key, value in expected_env.items()):
        raise ValueError("Original diagnostic runtime/config selection differs")
    output = Path(os.environ['RUNNER_TEMP']) / 'neko-photo-hang-diagnostic'
    output.mkdir()
    script = instrument(HARNESS.read_text(encoding='utf-8'))
    (output / 'plan.json').write_text(json.dumps({'diagnosticOnly': True, 'releaseEvidence': False,
        'sourceSHA': head, 'productSourceSHA': BASE, 'firstCandidateAt': '2026-10-14T12:59:13Z',
        'retainedFailures': [38653609078,38667725132], 'actualDiagnosticReferenceSeconds': 14 * 60 + 13,
        'workflowBudgetMinutes': 30,
        'harnessSHA256': HARNESS_SHA256, 'temporaryScriptSHA256': hashlib.sha256(script.encode()).hexdigest(),
        'changedBehavior': 'three bounded observations of exact app and XCTest runner; stop after original permission validator',
        'requiredCase': CASE, 'remainingUncertainty': ['Photos/Vision/AX execution on the hosted Simulator',
            'sampling adds overhead and may affect timing; a passing probe does not establish the original cause']}, indent=2) + '\n')
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', newline='\n', prefix='.photo-hang-',
            suffix='.sh', dir=CI, delete=False) as stream:
        stream.write(script)
        temporary = Path(stream.name)
    try:
        native = subprocess.run(['bash', str(temporary)]).returncode
    finally:
        temporary.unlink()
    log_path = Path(os.environ['RUNNER_TEMP']) / 'neko-smoke-artifacts/smoke-test.log'
    passed = case_result(log_path.read_text(encoding='utf-8', errors='replace'))
    (output / 'result.json').write_text(json.dumps({'diagnosticOnly': True, 'releaseEvidence': False,
        'nativeExitStatus': native, 'soleOriginalXCTestPassedExactlyOnce': passed}, indent=2) + '\n')
    return native if native else (0 if passed else 2)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=('run', 'prepare', 'monitor'))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--udid')
    parser.add_argument('--artifact', type=Path)
    args = parser.parse_args()
    if args.mode == 'prepare':
        if args.output is None: parser.error('--output required')
        args.output.write_text(instrument(HARNESS.read_text(encoding='utf-8')), encoding='utf-8', newline='\n')
    elif args.mode == 'monitor':
        if args.udid is None or args.artifact is None: parser.error('--udid/--artifact required')
        monitor(args.udid, args.artifact)
    else:
        sys.exit(run())
