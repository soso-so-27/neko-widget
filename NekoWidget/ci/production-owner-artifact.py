"""Authenticate an unchanged production IPA exported for the pinned owner only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import zipfile
import production_candidate as candidate


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def payload(root, ipa):
    candidate.require(os.environ.get('PRODUCTION_CANDIDATE_OWNER_ONLY') == 'true', 'Owner-only candidate flag required')
    candidate.require(os.environ.get('DISTRIBUTION_PROFILE') == candidate.PROFILE, 'Production profile required')
    source = os.environ.get('RELEASE_SOURCE_SHA', '')
    build = os.environ.get('RELEASE_BUILD_NUMBER', '')
    run, attempt = os.environ.get('GITHUB_RUN_ID', ''), os.environ.get('GITHUB_RUN_ATTEMPT', '')
    candidate.require(re.fullmatch(r'[0-9a-f]{40}', source) and all(re.fullmatch(r'[1-9][0-9]*', v) for v in (build, run, attempt)), 'Pinned candidate identity required')
    contract = root / 'production-candidate.json'
    candidate.settings(json.loads(contract.read_text()))
    options = root / 'ExportOptions.plist'
    candidate.verify_export(plistlib.loads(options.read_bytes()), owner_only=True)
    with zipfile.ZipFile(ipa) as archive:
        for relative, _, _ in candidate.TARGETS.values():
            name = 'Payload/NekoWidget.app/' + (relative + '/' if relative else '') + 'Info.plist'
            candidate.require(archive.namelist().count(name) == 1, 'Unique product plist required')
            info = plistlib.loads(archive.read(name))
            candidate.require(str(info.get('CFBundleVersion')) == build, 'Product build number differs')
    return {'schema': 'jp.nekowidget.production-owner-artifact.v1', 'source': source, 'build': build,
            'run': run, 'attempt': attempt, 'profile': candidate.PROFILE, 'internalOnly': True,
            'ipaSHA256': digest(ipa), 'contractSHA256': digest(contract), 'exportSHA256': digest(options)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('create', 'verify'))
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--ipa', type=Path, required=True)
    args = parser.parse_args()
    cipher = args.root / 'production-candidate.tar.gz.enc'
    metadata = args.root / 'production-owner-metadata.json'
    signature = args.root / 'production-owner-authentication.json'
    auth = candidate.module('signed-artifact-authentication')
    if args.command == 'create':
        with metadata.open('x', encoding='utf-8') as stream:
            json.dump(payload(args.root, args.ipa), stream, sort_keys=True)
        auth.create_manifest(cipher, metadata, signature)
    else:
        # Authentication precedes using metadata to authorize the recipient check.
        auth.verify_manifest(cipher, metadata, signature)
        candidate.require(json.loads(metadata.read_text()) == payload(args.root, args.ipa), 'Authenticated production candidate changed')
    print('PASS authenticated production IPA: production configuration, Internal Only export, fixed source/build/run')


if __name__ == '__main__':
    main()
