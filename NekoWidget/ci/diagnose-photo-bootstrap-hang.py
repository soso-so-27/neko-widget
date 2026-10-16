#!/usr/bin/env python3
"""Observe the unchanged Photos grant; diagnostic only, never release evidence."""
from __future__ import annotations
from pathlib import Path
from dataclasses import asdict, dataclass
import argparse
import collections
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import math
import os
import re
import signal
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
BRANCH = "refs/heads/diagnostic/automatic-membership-fetch-probe-20261016"
HELPER = "NekoWidget/ci/diagnose-photo-bootstrap-hang.py"
WORKFLOW = ".github/workflows/ios-ui-diagnostic.yml"
HARNESS = CI / "run-simulator-smoke.sh"
HARNESS_SHA256 = "11a1dac0485a951c4a55ffabc50f8d0f7225601210c7fc32601ea00f309c92d9"
CASE = "NekoWidgetUITests.PhotoPermissionUITests testGrantFullPhotoLibraryAccess"
EVENT = re.compile(r"Test Case '-\[([^\]]+)\]' (started|passed|failed|skipped)")


SESSION = re.compile(r"app-([0-9]+)-([0-9]+)-(p[a-zA-Z0-9]+)\.jsonl")
FETCH = "Photo library fetch completed"
MAX_BYTES = 16 * 1024 * 1024
MAX_LINE = 64 * 1024


class TriggerRejected(ValueError):
    """Wrong/ambiguous session or incompatible complete evidence: stop."""


@dataclass(frozen=True)
class LogSnapshot:
    name: str
    data: bytes


@dataclass(frozen=True)
class FetchTrigger:
    session: str
    pid: int
    line: int
    event_id: str
    timestamp_seconds: float
    seconds_after_case_start: float
    preceding_generation: str | None
    complete_prefix_sha256: str
    ignored_partial_tail_bytes: int
    app_alive_at_trigger: None = None


def first_fetch_trigger(
    sessions: list[LogSnapshot], *, expected_pid: int, case_started_ms: int
) -> FetchTrigger | None:
    """Return the first COMPLETE fetch event in one fresh exact-PID session.

    None means no complete fetch yet, not success. Callers may poll the same
    growing snapshot until their existing deadline; they must not retrigger
    after a result. Old/wrong-PID candidates and multiple sessions are errors,
    never silently replaced with another candidate. Discovery/path security
    belongs to the caller, which must supply the one exact App Group session.
    A first fetch with anything other than metadata.assets == '6' is rejected.
    A second scan generation is not required: real success/failure logs both
    first fetch six assets in generation 1.
    """
    if type(expected_pid) is not int or expected_pid <= 0:
        raise TriggerRejected("Invalid expected PID")
    if type(case_started_ms) is not int or case_started_ms <= 0:
        raise TriggerRejected("Invalid case start")
    if len(sessions) != 1:
        raise TriggerRejected("Require exactly one selected app session")
    snapshot = sessions[0]
    match = SESSION.fullmatch(snapshot.name)
    if match is None or int(match[2]) != expected_pid:
        raise TriggerRejected("Wrong session name or PID")
    if int(match[1]) < case_started_ms:
        raise TriggerRejected("Session predates this case")
    if not isinstance(snapshot.data, bytes) or len(snapshot.data) > MAX_BYTES:
        raise TriggerRejected("Unexpected session size/type")

    # Split bytes before decoding. An incomplete UTF-8/JSON trailing line is
    # neither parsed nor considered a trigger, even if valid JSON sans LF.
    complete, separator, tail = snapshot.data.rpartition(b"\n")
    if not separator:
        return None
    prefix = complete + separator
    generation = None
    for number, raw in enumerate(complete.split(b"\n"), start=1):
        if not raw or len(raw) > MAX_LINE:
            raise TriggerRejected("Empty or oversized complete JSONL line")
        try:
            entry = json.loads(raw.decode("utf-8"))
        except (UnicodeError, ValueError) as error:
            raise TriggerRejected("Malformed complete JSONL line") from error
        if not isinstance(entry, dict) or entry.get("process") != "app":
            raise TriggerRejected("Complete line is not an app event")
        timestamp = entry.get("timestamp")
        if (type(timestamp) not in (int, float) or not math.isfinite(timestamp)
                or timestamp * 1000 < case_started_ms):
            raise TriggerRejected("Complete event predates case or has invalid time")
        metadata = entry.get("metadata")
        if not isinstance(metadata, dict):
            raise TriggerRejected("Invalid metadata")
        if entry.get("message") == "Scan generation started":
            generation = metadata.get("generation")
        if entry.get("message") != FETCH:
            continue
        if entry.get("category") != "scan" or metadata.get("assets") != "6":
            raise TriggerRejected("First fetch is not the expected six-asset scan")
        event_id = entry.get("id")
        if not isinstance(event_id, str) or not event_id:
            raise TriggerRejected("Fetch has no event identity")
        return FetchTrigger(
            snapshot.name, expected_pid, number, event_id, float(timestamp),
            round(timestamp - case_started_ms / 1000, 6), generation,
            hashlib.sha256(prefix).hexdigest(), len(tail),
        )
    return None


def replace_once(text, anchor, replacement):
    if text.count(anchor) != 1:
        raise ValueError("Original smoke anchor differs")
    return text.replace(anchor, replacement, 1)


def instrument(source):
    if hashlib.sha256(source.encode()).hexdigest() != HARNESS_SHA256:
        raise ValueError("Original smoke script differs")
    phase = '    BOOTSTRAP_TEST_ACTION=test-without-building\nfi\n\n'
    start = source.index(phase) + len(phase)
    prep = source.index('if (( ${#SMOKE_PREPARATION_ARGUMENTS[@]} > 0 )); then\n')
    source = source[:prep] + source[start:]
    source = replace_once(source, 'xcrun simctl erase "$SIMULATOR_UDID"\nxcrun simctl boot "$SIMULATOR_UDID"\n',
        'xcrun simctl erase "$SIMULATOR_UDID"\nprintf \'%s\\n\' "$SIMULATOR_UDID" > "$ARTIFACT_DIRECTORY/photo-erased-udid.txt"\nxcrun simctl boot "$SIMULATOR_UDID"\n')
    start = source.index('TEST_RUNNER_NEKO_EXPECT_DISABLED_RELEASE=1 xcodebuild \\\n', prep)
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
    --group "$APP_GROUP_ID" --derived "$DERIVED_DATA_DIRECTORY" \\
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


def sample_process(role, ps, udid, artifact, trigger, container, case_started_ms):
    item = {'role': role}
    try:
        candidates = process_candidates(ps, udid, role)
        item['candidateCount'] = len(candidates)
        if len(candidates) != 1:
            raise ValueError('Target executable unavailable or ambiguous')
        pid, executable = candidates[0]
        if role == 'app' and pid != trigger.pid:
            raise ValueError('Trigger app PID changed')
        item.update(pid=pid, executable=executable)
        metrics = subprocess.check_output(['/bin/ps', '-ww', '-p', str(pid),
            '-o', 'pid=,pcpu=,rss=,state=,comm='], text=True, encoding='utf-8', timeout=10)
        fields = metrics.strip().split(None, 4)
        if len(fields) != 5 or fields[0] != str(pid) or fields[4] != executable:
            raise ValueError('Target changed before sampling')
        if any(state in fields[3] for state in 'TZ'):
            raise ValueError('Target is suspended or defunct; not a ready process')
        if role == 'app':
            ready = read_fetch_trigger(container, udid, pid, case_started_ms)
            if ready is None or (ready.session, ready.event_id) != (trigger.session, trigger.event_id):
                raise ValueError('Fresh same-PID trigger evidence changed before sampling')
            item['readyAppLogSession'] = ready.session
        prefix = f'photo-hang-first-fetch-{role}'
        (artifact / (prefix+'-process.txt')).write_text(metrics, encoding='utf-8')
        path = artifact / (prefix+'-sample.txt')
        item['samplingStartedAt'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        started = time.monotonic()
        with (artifact / (prefix+'-sample-command.log')).open('w', encoding='utf-8') as output:
            process = subprocess.Popen(['/usr/bin/sample', str(pid), '1', '-mayDie', '-file',
                str(path)], stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                process.wait(timeout=90)
            except subprocess.TimeoutExpired:
                item['sampleTimedOut'] = True
                if process.poll() is None and os.getpgid(process.pid) == process.pid:
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
        item['requestedSampleSeconds'] = 1
        item['sampleWallSeconds'] = time.monotonic() - started
        item['sampleExitStatus'] = process.returncode
        item['usableStack'] = not item.get('sampleTimedOut', False) and process.returncode == 0 and valid_sample(path, pid)
        if item['usableStack']:
            content = path.read_text(encoding='utf-8', errors='replace')
            item['reportedThreadSampleCounts'] = [int(value) for value in re.findall(r'^\s+(\d+) Thread[_ ]', content, re.MULTILINE)]
            item['reportedThreadCount'] = len(item['reportedThreadSampleCounts'])
            item['requestedDurationIsNotMeasuredDuration'] = True
            item['usableStack'] = (item['reportedThreadCount'] > 0 and max(item['reportedThreadSampleCounts']) > 0)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        item['error'] = type(error).__name__ + ': ' + str(error)
    return item


def read_fetch_trigger(container, udid, pid, case_started_ms):
    container = selected_container(container, udid)
    logs = container / 'diagnostic-logs'
    if not logs.exists():
        if logs.is_symlink():
            raise ValueError('Unexpected missing diagnostic-log symlink')
        return None
    if logs.is_symlink() or not logs.is_dir() or logs.resolve() != logs.absolute():
        raise ValueError('Unexpected diagnostic-log directory')
    paths = list(logs.glob('app-*.jsonl'))
    if not paths:
        return None
    snapshots = []
    for path in paths:
        if (path.is_symlink() or not path.is_file() or path.resolve().parent != logs
                or path.stat().st_size > MAX_BYTES):
            raise ValueError('Unexpected same-PID session path/type')
        with path.open('rb') as stream:
            data = stream.read(MAX_BYTES + 1)
        snapshots.append(LogSnapshot(path.name, data))
    return first_fetch_trigger(snapshots, expected_pid=pid, case_started_ms=case_started_ms)


def monitor(udid, artifact, bundle, group):
    if (str(uuid.UUID(udid)).upper() != udid or bundle != 'jp.nekowidget.app'
            or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{1,254}', group or '')):
        raise ValueError('Expected the exact original Simulator and app context')
    stop = artifact / 'photo-hang-stop'
    if stop.exists():
        raise ValueError('Stale diagnostic monitor marker')
    started = time.monotonic()
    test_started = None
    case_started_ms = None
    selected_app = None
    container = None
    latched = False
    observations, events, pending = [], [], ''
    monitor_error = None
    try:
        with (artifact / 'xcodebuild.log').open(encoding='utf-8', errors='replace') as log:
            while (not stop.exists() and (
                    time.monotonic() - started < 20 * 60 if test_started is None
                    else time.monotonic() - test_started < 8 * 60)):
                pending += log.read()
                lines = pending.split('\n')
                pending = lines.pop()
                for line in lines:
                    for case, outcome in EVENT.findall(line):
                        events.append([case, outcome])
                        if case == CASE and outcome == 'started' and test_started is None:
                            test_started = time.monotonic()
                            case_started_ms = int(time.time() * 1000)
                terminal = any(case == CASE and state in ('passed', 'failed', 'skipped') for case, state in events)
                if terminal:
                    break
                if test_started is not None and not latched:
                    ps = subprocess.check_output(['/bin/ps', '-ww', '-axo', 'pid=,comm='],
                        text=True, encoding='utf-8', timeout=10)
                    candidates = process_candidates(ps, udid, 'app')
                    if len(candidates) > 1:
                        raise ValueError('Ambiguous app PID before first fetch')
                    if not candidates:
                        if selected_app is not None:
                            raise ValueError('Selected app exited before the first fetch trigger')
                        time.sleep(0.25)
                        continue
                    if selected_app is None:
                        selected_app = candidates[0]
                    elif selected_app != candidates[0]:
                        raise ValueError('App PID/executable changed while waiting for fetch')
                    if container is None:
                        installed_group = subprocess.check_output(['xcrun','simctl','get_app_container',
                            udid,bundle,group], text=True, encoding='utf-8', timeout=10).strip()
                        container = selected_container(Path(installed_group), udid)
                    trigger = read_fetch_trigger(container, udid, selected_app[0], case_started_ms)
                    if trigger is None:
                        time.sleep(0.25)
                        continue
                    # One-shot is committed BEFORE either sampler can start.
                    # No other time-based or retry sampling is scheduled.
                    latched = True
                    item = {'target': 'first-six-asset-fetch', 'trigger': asdict(trigger),
                            'observedSeconds': time.monotonic() - test_started,
                            'observedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
                    observations.append(item)
                    with ThreadPoolExecutor(max_workers=2) as pool:
                        futures = [pool.submit(sample_process, role, ps, udid, artifact,
                            trigger, container, case_started_ms) for role in ('app', 'test')]
                        item['processes'] = [future.result() for future in futures]
                    if not live_fetch_stacks_accepted({'observations': observations}):
                        raise ValueError('First-fetch sampler evidence was not usable; no retry')
                    break
                time.sleep(0.25)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        monitor_error = type(error).__name__ + ': ' + str(error)
    finally:
        report = {'diagnosticOnly': True, 'releaseEvidence': False, 'udid': udid,
            'sampleDurationSeconds': 1, 'sampleCommandTimeoutSeconds': 90,
            'sampleTrigger': 'first fresh exact-PID complete fetch with metadata.assets=6',
            'maximumConcurrentSamplers': 2, 'maximumTotalSamplers': 2,
            'sampleRoles': ['app','test'], 'processSamplesParallel': True,
            'maximumWaitForXCTestStartSeconds': 20 * 60,
            'maximumObservationAfterXCTestStartSeconds': 8 * 60,
            'eventsObserved': events, 'observations': observations, 'oneShotLatched': latched,
            'error': monitor_error, 'stopRequested': stop.exists(),
            'durationSeconds': time.monotonic() - started}
        (artifact / 'photo-hang-monitor.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    return 0 if monitor_error is None and live_fetch_stacks_accepted(report) else 2


def case_result(log):
    events = EVENT.findall(log)
    counts = collections.Counter(events)
    return ({name for name, state in events} == {CASE} and len(events) == 2
            and counts[(CASE, 'started')] == 1 and counts[(CASE, 'passed')] == 1)


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


def live_fetch_stacks_accepted(report):
    observations = report.get('observations', [])
    if len(observations) != 1 or observations[0].get('target') != 'first-six-asset-fetch':
        return False
    processes = observations[0].get('processes', [])
    trigger = observations[0].get('trigger', {})
    return (len(processes) == 2 and {item.get('role') for item in processes} == {'app', 'test'}
            and all(item.get('usableStack') is True and item.get('sampleExitStatus') == 0
                    and item.get('requestedSampleSeconds') == 1 for item in processes)
            and next(item for item in processes if item['role'] == 'app').get('pid') == trigger.get('pid'))


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


def absent_before_first_install(args, output):
    marker = (args.artifact / 'photo-erased-udid.txt').read_text(encoding='utf-8').strip()
    if marker != args.udid:
        raise ValueError('No successful original erase marker for the selected Simulator')
    devices = json.loads(subprocess.check_output(['xcrun','simctl','list','devices','-j'],
        text=True, encoding='utf-8', timeout=10))['devices']
    matches = [(runtime, device) for runtime, values in devices.items() for device in values
               if device['udid'] == args.udid]
    if (len(matches) != 1 or matches[0][0] != 'com.apple.CoreSimulator.SimRuntime.iOS-18-6'
            or matches[0][1]['state'] != 'Booted'):
        raise ValueError('Expected the original erased and now booted Simulator')
    installed = subprocess.check_output(['xcrun','simctl','listapps',args.udid],
        text=True, encoding='utf-8', timeout=10)
    if not installed.strip() or args.bundle in installed:
        raise ValueError('Expected no installed target app after erase and the build-only phase')
    lookup = subprocess.run(['xcrun','simctl','get_app_container',args.udid,args.bundle,'data'],
        capture_output=True, text=True, encoding='utf-8', timeout=10)
    if lookup.returncode == 0 or lookup.stdout.strip():
        raise ValueError('Target app already has a data container')
    (output / 'first-install-app-group-absence.json').write_text(json.dumps({
        'udid': args.udid, 'successfulOriginalEraseMarker': True, 'booted': True,
        'appAbsentFromSuccessfulListapps': True, 'listappsSHA256': hashlib.sha256(installed.encode()).hexdigest(),
        'dataContainerLookupExitStatus': lookup.returncode, 'baselineSnapshotExists': False,
        'basis': 'successful original erase; boot; unchanged build-only phase; app absent before first original test'}, indent=2) + '\n')


def trials(args):
    validate_source()
    if (str(uuid.UUID(args.udid)).upper() != args.udid or args.bootstrap != 'test'
            or args.bundle != 'jp.nekowidget.app' or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{1,254}', args.group or '')
            or args.selectors != ['-only-testing:NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess']
            or os.environ.get('GITHUB_REF') != BRANCH or os.environ.get('GITHUB_RUN_ATTEMPT') != '1'):
        raise ValueError('Exact original grant/fresh diagnostic identity required')
    no_app(args.udid)
    container = None
    baseline = None
    root = args.artifact / 'bounded-photo-trials'
    root.mkdir()
    absent_before_first_install(args, root)
    (root / 'baseline.json').write_text(json.dumps(snapshot_identity(baseline), indent=2) + '\n')
    env = dict(os.environ, TEST_RUNNER_NEKO_EXPECT_DISABLED_RELEASE='1')
    number = 1
    no_app(args.udid)
    output = root / f'trial-{number}'
    output.mkdir()
    log_path = output / 'xcodebuild.log'
    log_path.touch()
    previous_names = set()
    action = 'test'
    command = ['xcodebuild', '-project', 'NekoWidget.xcodeproj', '-scheme', 'NekoWidget',
        '-configuration', 'Debug', '-xcconfig', str(CI.parent / 'Config.Disabled.xcconfig'),
        '-sdk', 'iphonesimulator', '-destination', f'platform=iOS Simulator,id={args.udid}',
        '-derivedDataPath', str(args.derived), '-resultBundlePath', str(output / 'Grant.xcresult'),
        *args.selectors, '-parallel-testing-enabled', 'NO', 'COMPILER_INDEX_STORE_ENABLE=NO',
        'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'AD_HOC_CODE_SIGNING_ALLOWED=YES', action]
    observer = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), 'monitor',
        '--udid', args.udid, '--artifact', str(output), '--bundle', args.bundle, '--group', args.group])
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
            observer_status = observer.wait(timeout=120)
        except subprocess.TimeoutExpired:
            observer_error = 'Diagnostic observer did not finish within 120 seconds after native completion'
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
        report['liveFetchStacksAccepted'] = (observer_status == 0 and observer_error is None
            and live_fetch_stacks_accepted(monitor_report))
    except (OSError, ValueError) as error:
        report['liveFetchStacksAccepted'] = False
        report['observerReportError'] = type(error).__name__ + ': ' + str(error)
    try:
        no_app(args.udid)
        if container is None:
            installed_group = subprocess.check_output(['xcrun','simctl','get_app_container',
                args.udid,args.bundle,args.group], text=True, encoding='utf-8', timeout=10).strip()
            container = selected_container(Path(installed_group), args.udid)
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
    if native or not report['freshConditionsAccepted'] or not report['liveFetchStacksAccepted']:
        print(f'Diagnostic stopped at trial {number}; native status {native}, fresh evidence and sampler status retained.', flush=True)
        return native or 2
    print('Diagnostic only: one isolated fresh original grant and first-fetch stack probe completed; formal CI remains unresolved.', flush=True)
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
        'oldIsolatedProbeReference': {'run': 38669865915, 'source': '80ea193244edaeaeb4ebc3d4076a877fc6520da7',
            'differentProductBase': 'fb5a1dce3696703e3942c77c34287c9319886eb1', 'durationSeconds': 703},
        'referenceIsNotGuarantee': True, 'expectedMinutes': [12, 20], 'workflowBudgetMinutes': 25,
        'sameProductIsolatedReference': {'run': 38846430608, 'durationSeconds': 698, 'samplerEvidenceAccepted': False},
        'maximumOriginalGrants': 1, 'maximumTotalSamplers': 2, 'snapshotResetCount': 0,
        'unrelatedPreparationExecuted': False, 'retainedPreparationFailure': 38841929598,
        'harnessSHA256': HARNESS_SHA256, 'temporaryScriptSHA256': hashlib.sha256(script.encode()).hexdigest(),
        'changedBehavior': 'diagnostic-only omission of unrelated preparation; original erase/build retained; one original grant owns runner build/install; first complete fresh same-PID six-asset fetch latches exactly one pair of requested one-second app/test samples; no snapshot reset or later trial',
        'requiredCase': CASE, 'remainingUncertainty': ['Photos/Vision/AX execution on the hosted Simulator',
            'app survival at first-fetch trigger and usable sampler output remain unobserved until execution',
            'sampling adds overhead and may affect timing; this probe does not establish the original cause',
            'isolated conditions do not reproduce the full-preparation context or qualify original native CI']}, indent=2) + '\n')
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
        'nativeExitStatus': native, 'isolatedOriginalGrantInventoryAccepted': passed,
        'unrelatedPreparationExecuted': False}, indent=2) + '\n')
    return native if native else (0 if passed else 2)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=('run', 'prepare', 'monitor', 'trials'))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--udid')
    parser.add_argument('--artifact', type=Path)
    parser.add_argument('--group')
    parser.add_argument('--derived', type=Path)
    parser.add_argument('--bundle')
    parser.add_argument('--bootstrap')
    parser.add_argument('--selector', dest='selectors', action='append', default=[])
    args = parser.parse_args()
    if args.mode == 'prepare':
        if args.output is None: parser.error('--output required')
        args.output.write_text(instrument(HARNESS.read_text(encoding='utf-8')), encoding='utf-8', newline='\n')
    elif args.mode == 'monitor':
        if any(value is None for value in (args.udid, args.artifact, args.bundle, args.group)):
            parser.error('--udid/--artifact/--bundle/--group required')
        sys.exit(monitor(args.udid, args.artifact, args.bundle, args.group))
    elif args.mode == 'trials':
        if any(value is None for value in (args.udid, args.artifact, args.group, args.derived, args.bundle, args.bootstrap)):
            parser.error('All original grant context arguments required')
        sys.exit(trials(args))
    else:
        sys.exit(run())
