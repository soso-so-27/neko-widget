"""Resume the authenticated, already-signed owner-only build 319; never rebuild."""
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

SOURCE = 'b1c2c9a2c6f1ecfb4f3074edd85a307e9b5f2f9f'
RUN = '41113053231'
ATTEMPT = '2'


def run(*args):
    subprocess.run(args, check=True)


def extract_payload(bundle, target):
    with tarfile.open(bundle, 'r:gz') as archive:
        members = archive.getmembers()
        names = [m.name for m in members]
        if len(set(names)) != len(names):
            raise ValueError('Duplicate retained bundle paths')
        for name in names:
            p = PurePosixPath(name)
            if not name or p.is_absolute() or '..' in p.parts or '\\' in name or '\0' in name:
                raise ValueError('Unsafe retained bundle path')
        payloads = [m for m in members if m.name.endswith('.ipa') and len(PurePosixPath(m.name).parts) == 1]
        if len(payloads) != 1:
            raise ValueError('Expected one root IPA')
        ipa = payloads[0]
        trust = archive.getmember('moderation-key-trust-manifest.json')
        for member, maximum in [(ipa, 1024**3), (trust, 1_000_000)]:
            if not member.isfile() or not 0 < member.size <= maximum:
                raise ValueError('Invalid retained payload member')
            with archive.extractfile(member) as source, (target / member.name).open('xb') as output:
                shutil.copyfileobj(source, output)
        return target / ipa.name, target / trust.name


def main():
    ci = Path(__file__).resolve().parent
    retained = Path(sys.argv[1]).resolve()
    metadata = retained / 'moderation-release-metadata.json'
    ciphertext = retained / 'NekoWidget-signed-artifacts.tar.gz.enc'
    authentication = retained / 'signed-artifact-authentication.json'
    run(sys.executable, str(ci / 'signed-artifact-authentication.py'), 'verify',
        '--ciphertext', str(ciphertext), '--metadata', str(metadata), '--authentication', str(authentication))
    with tempfile.TemporaryDirectory(prefix='owner-319-', dir=os.environ['RUNNER_TEMP']) as temporary:
        target = Path(temporary)
        bundle = target / 'bundle.tar.gz'
        run('openssl', 'enc', '-d', '-aes-256-cbc', '-pbkdf2', '-iter', '200000',
            '-pass', 'env:SIGNED_ARTIFACT_ENCRYPTION_PASSWORD', '-in', str(ciphertext), '-out', str(bundle))
        ipa, trust = extract_payload(bundle, target)
        expected = json.loads(metadata.read_text())
        run(sys.executable, str(ci / 'verify-signed-artifact-contents.py'), '--bundle', str(bundle),
            '--external-metadata', str(metadata), '--external-ipa', str(ipa), '--release-mode', 'media-staging',
            '--external-trust-manifest', str(trust), '--expected-trust-manifest-sha256', expected['moderationTrustManifestSha256'])
        run(sys.executable, str(ci / 'verify-moderation-upload-payload.py'), '--metadata', str(metadata), '--ipa', str(ipa),
            '--expected-source-commit', SOURCE, '--expected-build-number', '319', '--expected-github-run-id', RUN,
            '--expected-github-run-attempt', ATTEMPT, '--expected-distribution-profile', 'owner-internal',
            '--expected-release-mode', 'media-staging', '--expected-internal-reports', 'false')
        run(sys.executable, str(ci / 'distribution_profile.py'), '--profile', 'owner-internal',
            '--mode', 'media-staging', '--internal-reports', 'false', '--ipa', str(ipa))
        run(sys.executable, str(ci / 'group-window-release.py'), '--requested', 'true', '--mode', 'media-staging',
            '--approval', os.environ['GROUP_WINDOWS_APPROVAL'], '--ipa', str(ipa))
        # Both are repeated immediately before upload, after decrypt/verification.
        run('node', str(ci / 'check-retained-319-runtime.mjs'))
        run('node', str(ci / 'check-owner-testflight-recipient.mjs'),
            '--authenticated-artifact', str(retained), '--ipa', str(ipa))
        for stage in ['validate', 'upload']:
            result = subprocess.run(['xcrun', 'altool', '--' + stage + '-app', '-f', str(ipa), '-t', 'ios',
                '--apiKey', os.environ['APP_STORE_CONNECT_KEY_ID'], '--apiIssuer', os.environ['APP_STORE_CONNECT_ISSUER_ID']],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            log = target / (stage + '.log')
            log.write_bytes(result.stdout)
            if result.returncode:
                raise RuntimeError('Apple ' + stage + ' failed; upload is not confirmed')
            run(sys.executable, str(ci / 'altool-result.py'), stage, str(log))
        print('PASS retained build 319 upload; checking Apple processing and owner group delivery', flush=True)
        for attempt in range(20):
            result = subprocess.run(['node', str(ci / 'check-owner-testflight-recipient.mjs'),
                '--authenticated-artifact', str(retained), '--ipa', str(ipa), '--confirm-build', '319'])
            if result.returncode == 0:
                return
            if result.returncode != 3:
                raise RuntimeError('319 upload succeeded, but read-only delivery confirmation failed; do not repeat upload')
            if attempt < 19:
                time.sleep(30)
        raise RuntimeError('319 upload succeeded; Apple delivery was not confirmed within 10 minutes; do not repeat upload')


if __name__ == '__main__':
    main()
