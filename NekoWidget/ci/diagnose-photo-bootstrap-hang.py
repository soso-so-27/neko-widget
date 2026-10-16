#!/usr/bin/env python3
"""Observe the unchanged Photos grant; diagnostic only, never release evidence."""
from pathlib import Path
import argparse
import collections
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid

if sys.flags.optimize: raise RuntimeError('Do not disable source validation with optimized Python')
CI = Path(__file__).resolve().parent
BASE = "9c7149f712e53c77f946095b6c8d6bdd8834fc57"
BRANCH = "refs/heads/diagnostic/automatic-membership-photos-trials-20261016"
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
    phase = '    BOOTSTRAP_TEST_ACTION=test-without-building\nfi\n\n'
    start = source.index(phase) + len(phase)
    checkpoint = '''python3 "$PHOTO_PERMISSION_VALIDATOR" \\
    --tcc-report "$ARTIFACT_DIRECTORY/tcc-permission-checkpoint.json" \\
    --log-directory "$PERMISSION_EVIDENCE_DIRECTORY/diagnostic-logs" \\
    --bundle-identifier "$APP_BUNDLE_ID"
'''
    if source.count(checkpoint) != 1:
        raise ValueError('Permission checkpoint differs')
    end = source.index(checkpoint) + len(checkpoint)
    original = source[start:end]
    if not original.startswith('TEST_RUNNER_NEKO_EXPECT_DISABLED_RELEASE=1 xcodebuild \\\n'):
        raise ValueError('Original grant command differs')
    replacement = '''python3 "$PROJECT_DIRECTORY/ci/diagnose-photo-bootstrap-hang.py" trials \\
    --udid "$SIMULATOR_UDID" --artifact "$ARTIFACT_DIRECTORY" \\
    --container "$(resolve_group_container)" --derived "$DERIVED_DATA_DIRECTORY" \\
    --bundle "$APP_BUNDLE_ID" --bootstrap "$BOOTSTRAP_TEST_ACTION" \\
    --selector="${SMOKE_BOOTSTRAP_ARGUMENTS[0]}"
exit $?
'''
    return source[:start] + replacement + source[end:]


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


def valid_sample(path, pid):
    if not path.is_file() or path.stat().st_size > 8 * 1024 * 1024:
        return False
    content = path.read_text(encoding='utf-8', errors='replace')
    process = re.search(r'^Process:\s+.+\[(\d+)\]\s*$', content, re.MULTILINE)
    return bool(process and int(process[1]) == pid and pid > 0
                and 'Call graph:' in content and re.search(r'\bThread[_ ]', content))


def sample_preflight(output):
    path = output / 'sampler-self-preflight.txt'
    with (output / 'sampler-self-preflight-command.log').open('w') as log:
        result = subprocess.run(['/usr/bin/sample', str(os.getpid()), '1', '-file', str(path)],
            stdout=log, stderr=subprocess.STDOUT, timeout=8)
    accepted = result.returncode == 0 and valid_sample(path, os.getpid())
    (output / 'sampler-self-preflight.json').write_text(json.dumps({
        'pid': os.getpid(), 'exitStatus': result.returncode,
        'nonemptyCorrectPIDAndCallGraph': accepted, 'beforeBuild': True}, indent=2) + '\n')
    if not accepted:
        raise ValueError('Sampling is unavailable; refuse an expensive build without usable stacks')


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
        path = artifact / (prefix+'-sample.txt')
        duration = '1' if target == 'baseline' else '3'
        with (artifact / (prefix+'-sample-command.log')).open('w', encoding='utf-8') as output:
            result = subprocess.run(['/usr/bin/sample', str(pid), duration, '-file',
                str(path)], stdout=output, stderr=subprocess.STDOUT, timeout=8)
        item['sampleExitStatus'] = result.returncode
        item['usableStack'] = result.returncode == 0 and valid_sample(path, pid)
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
    with (artifact / 'xcodebuild.log').open(encoding='utf-8', errors='replace') as log:
        try:
            while not stop.exists() and time.monotonic() - started < 8 * 60:
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
                    for target in ('baseline', 25, 35, 45):
                        if target in captured or terminal or (target != 'baseline' and elapsed < target):
                            continue
                        captured.add(target)
                        item = {'targetSeconds': target, 'observedSeconds': elapsed,
                                'at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
                        try:
                            ps = subprocess.check_output(['/bin/ps', '-ww', '-axo', 'pid=,comm='],
                                text=True, encoding='utf-8', timeout=5)
                            if target == 'baseline' and not process_candidates(ps, udid, 'app'):
                                captured.remove(target)
                                continue
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
                'sampleDurationSeconds': 3, 'baselineSampleDurationSeconds': 1,
                'sampleTargetsRelativeToXCTestStart': [25, 35, 45],
                'sampleRoles': ['app','test'], 'processSamplesParallel': True,
                'eventsObserved': events, 'observations': observations,
                'stopRequested': stop.exists(), 'durationSeconds': time.monotonic() - started}, indent=2) + '\n', encoding='utf-8')


def case_result(log, trial_count=3):
    import ios_ci_scope as scope
    source = (CI.parent / 'NekoWidgetUITests/PhotoPermissionUITests.swift').read_text(encoding='utf-8')
    prepared = set()
    for owner in ('OfficialWindowUITests', 'PersonalRediscoveryUITests'):
        methods = scope.family_window_test_methods(source, owner_class=owner, required_names=frozenset())
        if methods is None: return False
        prepared.update(f'NekoWidgetUITests.{owner} {name}' for name, body in methods.items()
                        if name.startswith('test') and not body[5])
    if len(prepared) != 27: return False
    skipped = 'NekoWidgetUITests.OfficialWindowUITests testSyntheticMovieShippingExportsSoundOnAndOff'
    if skipped not in prepared: return False
    events = EVENT.findall(log)
    expected = prepared | {CASE}
    counts = collections.Counter(events)
    return ({name for name, state in events} == expected
            and len(events) == 2 * (len(prepared) + trial_count)
            and all(counts[(name, 'started')] == 1
                    and counts[(name, 'skipped' if name == skipped else 'passed')] == 1
                    for name in prepared)
            and counts[(CASE, 'started')] == trial_count and counts[(CASE, 'passed')] == trial_count)


def selected_container(container, udid):
    prefix = Path.home() / 'Library/Developer/CoreSimulator/Devices' / udid / 'data/Containers/Shared/AppGroup'
    absolute = container.absolute()
    if (not absolute.is_dir() or absolute.is_symlink() or absolute.resolve() != absolute
            or absolute.parent != prefix or str(uuid.UUID(absolute.name)).upper() != absolute.name.upper()):
        raise ValueError('Refuse an unexpected synthetic Simulator App Group path')
    return absolute


def no_app(udid):
    ps = subprocess.check_output(['/bin/ps', '-ww', '-axo', 'pid=,comm='],
        text=True, encoding='utf-8', timeout=5)
    if process_candidates(ps, udid, 'app'):
        raise ValueError('AUT still alive; refuse snapshot reset or baseline capture')


def snapshot_bytes(container):
    path = container / 'library-snapshot.json'
    if path.is_symlink():
        raise ValueError('Snapshot must not be a symlink')
    if not path.exists():
        return None
    if not path.is_file() or path.stat().st_size > 8 * 1024 * 1024:
        raise ValueError('Unexpected snapshot size/type')
    return path.read_bytes()


def snapshot_identity(data):
    return {'exists': data is not None, 'size': 0 if data is None else len(data),
            'sha256': None if data is None else hashlib.sha256(data).hexdigest()}


def restore_snapshot(container, baseline, udid):
    container = selected_container(container, udid)
    no_app(udid)
    path = container / 'library-snapshot.json'
    snapshot_bytes(container)  # Validate the current target before this one-file mutation.
    if baseline is None:
        path.unlink(missing_ok=True)
    else:
        path.write_bytes(baseline)
    if snapshot_bytes(container) != baseline:
        raise ValueError('Synthetic snapshot reset failed')


def trial_entries(container, previous_names, output):
    logs = container / 'diagnostic-logs'
    pattern = re.compile(r'^(app-\d+-\d+-[a-zA-Z0-9]+)(?:\.\d+)?\.jsonl$')
    selected = [path for path in logs.glob('*.jsonl')
                if path.name not in previous_names and pattern.fullmatch(path.name)]
    stems = {pattern.fullmatch(path.name)[1] for path in selected}
    if len(stems) != 1:
        raise ValueError('Expected exactly one fresh AUT log session')
    destination = output / 'diagnostic-logs'
    destination.mkdir()
    entries = []
    for path in selected:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 16 * 1024 * 1024:
            raise ValueError('Unexpected fresh session log')
        shutil.copyfile(path, destination / path.name)
        entries.extend(json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line)
    return entries, next(iter(stems))


def fresh_scan(entries, completed):
    def events(message):
        return [entry.get('metadata', {}) for entry in entries
                if entry.get('process') == 'app' and entry.get('message') == message]
    loaded, generations, fetches = (events(message) for message in
        ('Snapshot loaded', 'Scan generation started', 'Photo library fetch completed'))
    if (len(loaded) != 1 or loaded[0].get('assets') != '0' or not generations
            or any(item.get('existingRecords') != '0' for item in generations)
            or not fetches or any(item.get('assets') != '6' for item in fetches)):
        raise ValueError('Fresh zero-cache six-photo conditions were not observed')
    if completed:
        vision = events('Vision phase summary')
        if (len(vision) != 1 or vision[0].get('newlyAnalyzed') != '6'
                or vision[0].get('reused') != '0' or not events('Final scan result applied')):
            raise ValueError('Successful trial did not freshly analyze all six photos')
    return {'loadedAssets': 0, 'allExistingRecordCounts': 0, 'allFetchCounts': 6,
            'freshlyAnalyzedSixOnSuccess': completed}


def live_baseline_accepted(report):
    baseline = [item for item in report.get('observations', []) if item.get('targetSeconds') == 'baseline']
    if len(baseline) != 1:
        return False
    processes = baseline[0].get('processes', [])
    return (len(processes) == 2 and {item.get('role') for item in processes} == {'app', 'test'}
            and all(item.get('usableStack') is True and item.get('sampleExitStatus') == 0 for item in processes))


def tcc_report(udid, bundle, output):
    database = Path.home() / 'Library/Developer/CoreSimulator/Devices' / udid / 'data/Library/TCC/TCC.db'
    connection = sqlite3.connect(f'file:{database}?mode=ro', uri=True, timeout=2)
    try:
        connection.row_factory = sqlite3.Row
        rows = connection.execute('SELECT * FROM access WHERE client = ? ORDER BY service', (bundle,)).fetchall()
        report = {'bundleIdentifier': bundle, 'rows': [
            {key: value.hex() if isinstance(value, bytes) else value for key, value in dict(row).items()}
            for row in rows]}
        output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    finally:
        connection.close()


def trials(args):
    validate_source()
    if (str(uuid.UUID(args.udid)).upper() != args.udid or args.bootstrap != 'test-without-building'
            or args.selectors != ['-only-testing:NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess']
            or os.environ.get('GITHUB_REF') != BRANCH or os.environ.get('GITHUB_RUN_ATTEMPT') != '1'):
        raise ValueError('Exact original grant/fresh diagnostic identity required')
    container = selected_container(args.container, args.udid)
    no_app(args.udid)
    baseline = snapshot_bytes(container)
    if baseline is not None and json.loads(baseline).get('assets') != []:
        raise ValueError('Preparation left an analyzed asset cache; refuse to redefine baseline')
    root = args.artifact / 'bounded-photo-trials'
    root.mkdir()
    (root / 'baseline.json').write_text(json.dumps(snapshot_identity(baseline), indent=2) + '\n')
    if baseline is not None:
        (root / 'initial-library-snapshot.json').write_bytes(baseline)
    env = dict(os.environ, TEST_RUNNER_NEKO_EXPECT_DISABLED_RELEASE='1')
    for number in range(1, 4):
        no_app(args.udid)
        if snapshot_bytes(container) != baseline:
            raise ValueError('Baseline changed before next original grant')
        output = root / f'trial-{number}'
        output.mkdir()
        log_path = output / 'xcodebuild.log'
        log_path.touch()
        previous_names = {path.name for path in (container / 'diagnostic-logs').glob('*.jsonl')}
        command = ['xcodebuild', '-project', 'NekoWidget.xcodeproj', '-scheme', 'NekoWidget',
            '-configuration', 'Debug', '-xcconfig', str(CI.parent / 'Config.Disabled.xcconfig'),
            '-sdk', 'iphonesimulator', '-destination', f'platform=iOS Simulator,id={args.udid}',
            '-derivedDataPath', str(args.derived), '-resultBundlePath', str(output / 'Grant.xcresult'),
            *args.selectors, '-parallel-testing-enabled', 'NO', 'COMPILER_INDEX_STORE_ENABLE=NO',
            'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'AD_HOC_CODE_SIGNING_ALLOWED=YES', args.bootstrap]
        observer = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), 'monitor',
            '--udid', args.udid, '--artifact', str(output)])
        native = 2
        observer_status = None
        observer_error = None
        try:
            with log_path.open('w', encoding='utf-8') as log:
                process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True, encoding='utf-8', errors='replace', env=env)
                for line in process.stdout:
                    log.write(line)
                    log.flush()
                    print(line, end='', flush=True)
                native = process.wait()
        finally:
            (output / 'native-exit.json').write_text(json.dumps({'nativeExitStatus': native}) + '\n')
            (output / 'photo-hang-stop').touch()
            try:
                observer_status = observer.wait(timeout=15)
            except subprocess.TimeoutExpired:
                observer_error = 'Diagnostic observer did not finish within 15 seconds after native completion'
                observer.terminate()
                try:
                    observer_status = observer.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    observer.kill()
                    observer_status = observer.wait(timeout=5)
        report = {'trial': number, 'nativeExitStatus': native, 'diagnosticOnly': True, 'releaseEvidence': False,
                  'observerExitStatus': observer_status, 'observerError': observer_error}
        try:
            monitor_report = json.loads((output / 'photo-hang-monitor.json').read_text(encoding='utf-8'))
            report['liveBaselineStacksAccepted'] = (observer_status == 0 and observer_error is None
                and live_baseline_accepted(monitor_report))
        except (OSError, ValueError) as error:
            report['liveBaselineStacksAccepted'] = False
            report['observerReportError'] = type(error).__name__ + ': ' + str(error)
        try:
            no_app(args.udid)
            current = snapshot_bytes(container)
            report['resultSnapshot'] = snapshot_identity(current)
            if current is not None:
                (output / 'result-library-snapshot.json').write_bytes(current)
            entries, session = trial_entries(container, previous_names, output)
            report['freshSession'] = session
            report['freshScan'] = fresh_scan(entries, native == 0)
            tcc_report(args.udid, args.bundle, output / 'tcc-permission-checkpoint.json')
            sys.path.insert(0, str(CI))
            import importlib.util
            spec = importlib.util.spec_from_file_location('permission_validator', CI / 'validate-photo-permission-bootstrap.py')
            validator = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(validator)
            report['permission'] = validator.validate_permission_bootstrap(
                output / 'tcc-permission-checkpoint.json', output / 'diagnostic-logs', args.bundle)
            report['freshConditionsAccepted'] = True
        except (OSError, ValueError, sqlite3.Error, subprocess.SubprocessError) as error:
            report['freshConditionsAccepted'] = False
            report['error'] = type(error).__name__ + ': ' + str(error)
        (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        if (output / 'Grant.xcresult').is_dir():
            subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(output / 'Grant.xcresult'),
                '--output-path', str(output / 'screen-attachments')], check=True)
        if native or not report['freshConditionsAccepted'] or not report['liveBaselineStacksAccepted']:
            print(f'Diagnostic stopped at trial {number}; native status {native}, fresh evidence and sampler status retained.', flush=True)
            return native or 2
        if number < 3:
            restore_snapshot(container, baseline, args.udid)
    print('Diagnostic only: three fresh grants completed; original CI failure is unresolved.', flush=True)
    return 0


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
    if scope.smoke_tests(scope.FULL_SCOPE) != (
            'NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess',
            'NekoWidgetUITests/PhotoPermissionUITests/testMainlineAcceptanceScreensWithAuthorizedLibrary',
            'NekoWidgetUITests/OfficialWindowUITests',
            'NekoWidgetUITests/PersonalRediscoveryUITests'):
        raise ValueError("Original smoke selection differs")
    expected_env = {'DEVELOPER_DIR': '/Applications/Xcode_26.3.app/Contents/Developer',
        'SMOKE_IOS_RUNTIME': 'com.apple.CoreSimulator.SimRuntime.iOS-18-6',
        'NEKO_IOS_RUNTIME_SCOPE': scope.FULL_SCOPE}
    if any(os.environ.get(key) != value for key, value in expected_env.items()):
        raise ValueError("Original diagnostic runtime/config selection differs")
    output = Path(os.environ['RUNNER_TEMP']) / 'neko-photo-hang-diagnostic'
    output.mkdir()
    sample_preflight(output)
    script = instrument(HARNESS.read_text(encoding='utf-8'))
    (output / 'plan.json').write_text(json.dumps({'diagnosticOnly': True, 'releaseEvidence': False,
        'sourceSHA': head, 'productSourceSHA': BASE, 'firstCandidateAt': '2026-10-15T23:31:48.229Z',
        'retainedFailureRun': 38825512712, 'retainedFailureAttempts': [1, 2],
        'currentFullSmokeReferencesSeconds': [1809, 1655, 1943], 'referenceIsNotGuarantee': True,
        'workflowBudgetMinutes': 45,
        'harnessSHA256': HARNESS_SHA256, 'temporaryScriptSHA256': hashlib.sha256(script.encode()).hexdigest(),
        'changedBehavior': 'one unchanged full-v1 preparation; maximum three original grants without rebuilding; stop first failure; restore only exact zero-asset initial library snapshot between passed trials; trial-only session validation; live baseline and 25/35/45-second app/test samples',
        'requiredCase': CASE, 'remainingUncertainty': ['Photos/Vision/AX execution on the hosted Simulator',
            'sampling adds overhead and may affect timing; three passing probes do not establish the original cause',
            'OS PhotoKit/Vision caches are warm on later trials and are not reset']}, indent=2) + '\n')
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
        'nativeExitStatus': native, 'fullPreparationAndOriginalGrantInventoryAccepted': passed}, indent=2) + '\n')
    return native if native else (0 if passed else 2)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=('run', 'prepare', 'monitor', 'trials'))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--udid')
    parser.add_argument('--artifact', type=Path)
    parser.add_argument('--container', type=Path)
    parser.add_argument('--derived', type=Path)
    parser.add_argument('--bundle')
    parser.add_argument('--bootstrap')
    parser.add_argument('--selector', dest='selectors', action='append', default=[])
    args = parser.parse_args()
    if args.mode == 'prepare':
        if args.output is None: parser.error('--output required')
        args.output.write_text(instrument(HARNESS.read_text(encoding='utf-8')), encoding='utf-8', newline='\n')
    elif args.mode == 'monitor':
        if args.udid is None or args.artifact is None: parser.error('--udid/--artifact required')
        monitor(args.udid, args.artifact)
    elif args.mode == 'trials':
        if any(value is None for value in (args.udid, args.artifact, args.container, args.derived, args.bundle, args.bootstrap)):
            parser.error('All original grant context arguments required')
        sys.exit(trials(args))
    else:
        sys.exit(run())
