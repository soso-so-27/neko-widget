"""The v2 internal release requires fresh, independently signed server evidence."""
from pathlib import Path
import json
import subprocess


def verify_v2_rollout(policy: dict) -> None:
    if policy['clientKeyId'] == 'moderation-v1':
        if policy['v2ClientReleaseAllowed']:
            raise SystemExit('Moderation rollout policy cannot allow v2 while selecting v1.')
        return
    if not policy['v2ClientReleaseAllowed']:
        raise SystemExit('Moderation rollout policy cannot select v2 without readiness permission.')
    directory = Path(__file__).resolve().parent
    def strict(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate readiness key')
            result[key] = value
        return result
    try:
        evidence = json.loads((directory / 'moderation-v2-readiness.json').read_text('utf-8'), object_pairs_hook=strict)
        response = subprocess.run(
            ['node', str(directory / 'verify-moderation-readiness.mjs')],
            input=json.dumps({'policy': policy, 'evidence': evidence}, ensure_ascii=True, sort_keys=True, separators=(',', ':')),
            text=True, capture_output=True, timeout=20, check=False,
        )
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        raise SystemExit('Moderation v2 readiness is unavailable or invalid.') from error
    if response.returncode != 0:
        raise SystemExit('Moderation v2 readiness verification failed: ' + response.stderr.strip()[:160])
