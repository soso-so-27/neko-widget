#!/usr/bin/env python3
"""Check the terminal result in one invocation's preserved altool output."""
import argparse
import re
from pathlib import Path

ERROR = re.compile(r'ERROR:|Failed to (?:validate|upload)|ENTITY_ERROR|UPLOAD FAILED|VALIDATION FAILED', re.I)
DELIVERY = re.compile(r'Delivery UUID: ([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})', re.I)


def verify(stage: str, log: str) -> None:
    if stage not in ('validate', 'upload'):
        raise ValueError('Unknown altool stage')
    lines = [line.strip() for line in log.splitlines()]
    marker = 'VERIFY SUCCEEDED with no errors' if stage == 'validate' else 'UPLOAD SUCCEEDED with no errors'
    successes = [i for i, line in enumerate(lines) if line == marker]
    if not successes:
        raise ValueError(f'altool {stage} did not emit its final success marker')
    last = successes[-1]
    # Upload retries may log a transient ERROR before recovering. Errors after
    # the final success remain failures; validation retains its strict policy.
    checked = lines if stage == 'validate' else lines[last + 1:]
    if any(ERROR.search(line) for line in checked):
        raise ValueError(f'altool {stage} reported an unresolved error')
    if stage == 'upload':
        deliveries = [DELIVERY.fullmatch(line) for line in lines[last + 1:] if line.startswith('Delivery UUID:')]
        if len(deliveries) != 1 or deliveries[0] is None or int(deliveries[0][1].replace('-', ''), 16) == 0:
            raise ValueError('altool upload has no unique valid Delivery UUID after success')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('stage', choices=('validate', 'upload'))
    parser.add_argument('log', type=Path)
    args = parser.parse_args()
    try:
        verify(args.stage, args.log.read_text(encoding='utf-8'))
    except (ValueError, OSError) as error:
        parser.exit(1, f'{error}\n')
