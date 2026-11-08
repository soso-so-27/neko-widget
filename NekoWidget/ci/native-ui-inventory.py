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

if sys.argv[1] == 'select':
    shard = int(sys.argv[2])
    assert 0 <= shard < 4
    selected = inventory()[shard::4]
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
