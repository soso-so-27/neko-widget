#!/usr/bin/env python3
"""Read retained Photos failure diagnostics; no build, Simulator or release."""
from pathlib import Path, PurePosixPath
import datetime as dt
import hashlib
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

if sys.flags.optimize:
    raise RuntimeError('Source guards must stay enabled')
BASE = '9c7149f712e53c77f946095b6c8d6bdd8834fc57'
BRANCH = 'refs/heads/diagnostic/automatic-membership-existing-xcresult-20261016'
HELPER = 'NekoWidget/ci/inspect-photo-xcresult.py'
WORKFLOW = '.github/workflows/ios-ui-diagnostic.yml'
REPO = 'soso-so-27/neko-widget'
RUN, ATTEMPT, JOB = 38825512712, 2, 116757527061
ARTIFACT_ID = 12019760421
ARTIFACT_NAME = 'ios-simulator-smoke-38825512712-2'
BUNDLE = 'NekoWidgetPhotoPermission.xcresult/'
MAX_TRANSFER = 192 * 1024 * 1024
MAX_DECODED = 256 * 1024 * 1024

def command(argv, timeout=30):
    result = subprocess.run(argv,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=timeout)
    return {'arguments':argv,'exitStatus':result.returncode,'stdout':result.stdout[:1024*1024],
            'stderr':result.stderr[:1024*1024],
            'outputTruncated':len(result.stdout)>1024*1024 or len(result.stderr)>1024*1024}

def validate_source():
    def git(*args):
        return subprocess.check_output(['git',*args],text=True,encoding='utf-8').rstrip('\n')
    head = git('rev-parse','HEAD')
    if (os.environ.get('GITHUB_EVENT_NAME')!='workflow_dispatch' or os.environ.get('GITHUB_REF')!=BRANCH
        or os.environ.get('GITHUB_RUN_ATTEMPT')!='1' or head!=os.environ.get('GITHUB_SHA')
        or head!=os.environ.get('NEKO_DIAGNOSTIC_SOURCE_SHA') or git('show','-s','--format=%P',head)!=BASE):
        raise ValueError('Exact one-off source/ref/parent required')
    rows = git('diff','--raw','--no-renames','--no-abbrev','-z',BASE,head).split('\0')
    if rows[-1:]==['']: rows.pop()
    expected = {WORKFLOW:('M',':100644','100644'),HELPER:('A',':000000','100644')}
    if len(rows)!=4: raise ValueError('Only workflow and reader may differ')
    seen=set()
    for index in range(0,len(rows),2):
        fields,path=rows[index].split(),rows[index+1]
        if (path in seen or path not in expected or len(fields)!=5
            or (fields[4],fields[0],fields[1])!=expected[path]):
            raise ValueError('Unexpected source input')
        seen.add(path)
    if git('status','--porcelain=v1','--untracked-files=no'):
        raise ValueError('Dirty tracked checkout')
    return head

def api(path, token):
    request=urllib.request.Request('https://api.github.com/repos/'+REPO+'/'+path,
        headers={'Authorization':'Bearer '+token,'Accept':'application/vnd.github+json'})
    with urllib.request.urlopen(request,timeout=30) as response:
        return json.load(response)

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs): return None

def artifact_url(token):
    request=urllib.request.Request(f'https://api.github.com/repos/{REPO}/actions/artifacts/{ARTIFACT_ID}/zip',
        headers={'Authorization':'Bearer '+token,'Accept':'application/vnd.github+json'})
    try:
        urllib.request.build_opener(NoRedirect).open(request,timeout=30)
        raise ValueError('Expected artifact redirect')
    except urllib.error.HTTPError as error:
        if error.code!=302: raise
        location=error.headers['Location']
    parsed=urllib.parse.urlsplit(location)
    if parsed.scheme!='https' or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError('Unexpected signed URL protocol')
    return location

class Ranges(io.RawIOBase):
    def __init__(self,location,size): self.location=location; self.size=size; self.position=0; self.cache={}; self.transferred=0
    def seekable(self): return True
    def readable(self): return True
    def tell(self): return self.position
    def seek(self,n,whence=0):
        if whence not in (0,1,2): raise ValueError('Invalid seek')
        self.position=n if whence==0 else self.position+n if whence==1 else self.size+n
        if not 0<=self.position<=self.size: raise ValueError('Invalid artifact offset')
        return self.position
    def read(self,n=-1):
        n=min(n if n>=0 else self.size-self.position,self.size-self.position); chunks=[]
        while n>0:
            block=self.position//(1024*1024); start=block*1024*1024
            if block not in self.cache:
                end=min(start+1024*1024,self.size)-1
                if self.transferred+(end-start+1)>MAX_TRANSFER: raise ValueError('Transfer budget exceeded')
                request=urllib.request.Request(self.location,headers={'Range':f'bytes={start}-{end}'})
                with urllib.request.urlopen(request,timeout=30) as response:
                    if response.status!=206 or response.headers['Content-Range']!=f'bytes {start}-{end}/{self.size}':
                        raise ValueError('Unexpected range response')
                    value=response.read(end-start+2)
                    if len(value)!=end-start+1: raise ValueError('Unexpected range length')
                self.transferred+=len(value); self.cache[block]=value
            value=self.cache[block]; offset=self.position-start; take=min(n,len(value)-offset)
            chunks.append(value[offset:offset+take]); self.position+=take; n-=take
        return b''.join(chunks)

def safe_target(root,name):
    pure=PurePosixPath(name)
    if pure.is_absolute() or '..' in pure.parts or '\\' in name or not name.startswith(BUNDLE):
        raise ValueError('Unexpected xcresult path')
    path=(root/name).resolve()
    if not path.is_relative_to(root.resolve()): raise ValueError('Path escaped input root')
    return path

def main():
    source=validate_source()
    started=time.monotonic()
    output=Path(os.environ['RUNNER_TEMP'])/'neko-existing-xcresult-evidence'
    output.mkdir()
    def save(name,value):
        (output/name).write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8')
    save('plan.json',{'sourceSHA':source,'diagnosticOnly':True,'releaseEvidence':False,
        'firstCandidateAt':'2026-10-15T23:31:48.229Z','at':dt.datetime.now(dt.timezone.utc).isoformat(),
        'changedBehavior':'Export existing formal failure xcresult diagnostics only; no build, Simulator or test rerun',
        'retainedFailureRun':RUN,'attempt':ATTEMPT,'job':JOB,'artifact':ARTIFACT_ID,
        'expectedMinutes':[2,5],'workflowTimeoutMinutes':8,'remainingUncertainty':
        ['Diagnostic data and matching app hang stacks may be absent','Tool schema/output observed on Xcode26.3 here for the first time']})
    token=os.environ.pop('GH_ARTIFACT_READ_TOKEN')
    run=api(f'actions/runs/{RUN}',token)
    job=api(f'actions/jobs/{JOB}',token)
    artifact=api(f'actions/artifacts/{ARTIFACT_ID}',token)
    if not (run['head_sha']==BASE and run['head_branch']=='codex/automatic-admission-20261016'
            and run['run_attempt']==ATTEMPT and run['status']=='completed'
            and run['conclusion']=='failure' and run['repository']['full_name']==REPO
            and job['run_id']==RUN and job['run_attempt']==ATTEMPT and job['head_sha']==BASE
            and job['status']=='completed' and job['conclusion']=='failure'
            and artifact['id']==ARTIFACT_ID and artifact['name']==ARTIFACT_NAME and not artifact['expired']
            and artifact['workflow_run']['id']==RUN and artifact['workflow_run']['head_sha']==BASE):
        raise ValueError('Retained run/job/artifact identity differs')
    size=artifact['size_in_bytes']
    if not 0<size<512*1024*1024: raise ValueError('Unexpected archive size')
    location=artifact_url(token)
    del token
    reader=Ranges(location,size)
    inputs=Path(os.environ['RUNNER_TEMP'])/'neko-existing-xcresult-input'
    inputs.mkdir()
    with zipfile.ZipFile(reader) as archive:
        entries=[entry for entry in archive.infolist() if entry.filename.startswith(BUNDLE)]
        names=[entry.filename for entry in entries]
        decoded=sum(entry.file_size for entry in entries)
        compressed=sum(entry.compress_size for entry in entries)
        if (not entries or len(entries)>20000 or len(set(names))!=len(names)
                or decoded>MAX_DECODED or compressed>MAX_TRANSFER):
            raise ValueError('Unexpected exact bundle inventory')
        for entry in entries:
            target=safe_target(inputs,entry.filename)
            mode=entry.external_attr>>16
            if stat.S_ISLNK(mode) or entry.file_size>64*1024*1024:
                raise ValueError('Symlink or oversized xcresult entry')
            if entry.is_dir(): target.mkdir(parents=True,exist_ok=True); continue
            target.parent.mkdir(parents=True,exist_ok=True)
            with target.open('xb') as stream: stream.write(archive.read(entry))
    save('input-identity.json',{'run':RUN,'attempt':ATTEMPT,'job':JOB,'artifact':ARTIFACT_ID,
        'artifactName':ARTIFACT_NAME,'artifactBytes':size,'bundlePrefix':BUNDLE,'entries':len(entries),
        'decodedBytes':decoded,'compressedBytes':compressed,'transferredBytes':reader.transferred,
        'perEntryCRCChecked':True,'fullArchiveDigestVerified':False})
    bundle=inputs/BUNDLE.rstrip('/')
    version=command(['xcodebuild','-version'])
    save('xcode-version.json',version)
    if version['exitStatus']!=0 or not version['stdout'].startswith('Xcode 26.3\n'):
        raise ValueError('Expected the selected Xcode26.3 toolchain')
    for name,args in [('availability-help',['help','get','content-availability']),
                      ('diagnostics-help',['help','export','diagnostics'])]:
        help_result=command(['xcrun','xcresulttool',*args])
        save(name+'.json',help_result)
        required=('--path','--output-path') if name=='diagnostics-help' else ('--path',)
        help_text=help_result['stdout']+'\n'+help_result['stderr']
        if help_result['exitStatus']!=0 or help_result['outputTruncated'] or any(flag not in help_text for flag in required):
            raise ValueError('Required xcresulttool flags were not confirmed in this toolchain help')
    availability=command(['xcrun','xcresulttool','get','content-availability','--path',str(bundle)],60)
    save('content-availability.json',availability)
    exported=Path(os.environ['RUNNER_TEMP'])/'neko-existing-xcresult-export'
    if exported.exists(): raise ValueError('Refuse an existing diagnostics export destination')
    result=command(['xcrun','xcresulttool','export','diagnostics','--path',str(bundle),'--output-path',str(exported)],120)
    save('diagnostics-export.json',result)
    selected=[]; inventory=[]; total=0
    for path in sorted(exported.rglob('*')):
        if path.is_symlink(): raise ValueError('Unexpected exported diagnostic symlink')
        if not path.is_file(): continue
        relative=path.relative_to(exported)
        length=path.stat().st_size
        inventory.append({'path':relative.as_posix(),'bytes':length})
        if len(inventory)>20000: raise ValueError('Unexpected export inventory count')
        if path.suffix.lower() not in ('.ips','.crash','.txt','.log','.json','.sample') or length>8*1024*1024:
            continue
        total+=length
        if total>32*1024*1024: raise ValueError('Selected diagnostic text budget exceeded')
        data=path.read_bytes()
        target=output/'selected'/relative
        target.parent.mkdir(parents=True,exist_ok=True)
        with target.open('xb') as stream: stream.write(data)
        selected.append({'path':relative.as_posix(),'bytes':length,'sha256':hashlib.sha256(data).hexdigest()})
    save('export-inventory.json',inventory)
    save('result.json',{'diagnosticOnly':True,'releaseEvidence':False,'sourceSHA':source,
        'availabilityExitStatus':availability['exitStatus'],'exportExitStatus':result['exitStatus'],
        'exportedFileCount':len(inventory),'selectedFiles':selected,'elapsedSeconds':time.monotonic()-started,
        'matchingFailureAppStackNotYetAnalyzed':True,'noBuildOrSimulatorOrTests':True})
    print(json.dumps({'diagnosticOnly':True,'availabilityExitStatus':availability['exitStatus'],
        'exportExitStatus':result['exitStatus'],'exportedFileCount':len(inventory),'selectedFiles':len(selected)}))
    return 0 if availability['exitStatus']==0 and result['exitStatus']==0 else 2

if __name__=='__main__': raise SystemExit(main())
