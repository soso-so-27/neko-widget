"""Partition every existing UI method; missing/skipped tests never count as pass."""
import re
import sys
from pathlib import Path

def inventory():
    result = []
    for source in sorted(Path('NekoWidgetUITests').glob('*.swift')):
        current = None
        for line in source.read_text(encoding='utf-8').splitlines():
            match = re.search(r'\bclass (\w+)\s*:\s*XCTestCase', line)
            if match:
                current = match[1]
            method = re.search(r'\bfunc (test\w+)\s*\(', line)
            if method:
                assert current, source
                result.append(f'NekoWidgetUITests/{current}/{method[1]}')
    assert result and len(result) == len(set(result))
    return sorted(result)

def route(test):
    # These seven captures need owner media and a private key. They run only
    # in owner-store-capture.yml, which encrypts every attachment, not in the
    # ordinary public-output lanes. Keep them in the inventory, never as passes.
    if test.rsplit('/', 1)[-1].startswith('testCaptureOwnerStore'): return 'owner-capture'
    if 'WidgetPlacementScreenshotUITests/' in test: return 'widget'
    # Display-speed measurements (no pass/fail threshold). Manual only:
    # route=speed is not in the push/nightly route list.
    if 'ScreenSpeedSweepUITests/' in test: return 'speed'
    # 11/14 main-thread stalls after launch on a large synthetic library.
    if 'LaunchWorkUITests/' in test: return 'speed'
    if test.endswith('/testSyntheticMovieShippingExportsSoundOnAndOff'): return 'movie'
    if test.endswith('/testReviewPublicIPadCompatibility'): return 'ipad'
    # testReviewPublicPresentation needs the DEBUG fixture and DEBUG previews
    # (--app-store-screenshot-fixture, --review-public-presentation), so it
    # runs in the Debug preparation. The public Release build is covered by
    # testReviewPublicIPadCompatibility in the ipad preparation.
    if test.endswith('/testGrantFullPhotoLibraryAccess'): return 'empty'
    # The movie case needs the real Photos permission granted just before by
    # testGrantFullPhotoLibraryAccess (as in run-simulator-smoke.sh). Alone in
    # the standard preparation Photos stays undetermined and the export stops
    # at once. XCTest runs the class's methods by name, so Grant comes first.
    if test.endswith('/testMainlineAcceptanceScreensWithAuthorizedLibrary'): return 'empty'
    return 'standard'

if sys.argv[1] == 'select':
    shard = int(sys.argv[2])
    assert 0 <= shard < 4
    lane = sys.argv[4] if len(sys.argv) > 4 else 'standard'
    needle = sys.argv[5] if len(sys.argv) > 5 else ''
    candidates = [t for t in inventory() if route(t) == lane and needle in t]
    selected = candidates[shard::4] if lane == 'standard' and not needle else candidates
    if needle and shard != 0: selected = []
    assert selected
    Path(sys.argv[3]).write_text('\n'.join(selected) + '\n', encoding='utf-8')
    print(f'UI shard {shard}: {len(selected)} of {len(inventory())} tests; no exclusions')
elif sys.argv[1] == 'report':
    expected = Path(sys.argv[2]).read_text().splitlines()
    log = Path(sys.argv[3]).read_text(encoding='utf-8', errors='replace')
    results = {}
    for cls, method, status in re.findall(r"Test Case '-\[(?:\w+\.)?(\w+) (test\w+)\]' (passed|failed|skipped)", log):
        results[f'NekoWidgetUITests/{cls}/{method}'] = status
    lines = ['# Native UI result', '', '| Test | Result |', '|---|---|']
    for test in expected:
        lines.append(f'| {test} | {results.get(test, "not completed")} |')
    Path(sys.argv[4]).write_text('\n'.join(lines) + '\n', encoding='utf-8')
    if any(results.get(t) != 'passed' for t in expected):
        raise SystemExit('Failed, skipped or missing UI cases: inspect xcresult and log; not a green run.')
else:
    raise SystemExit('Use select or report')
