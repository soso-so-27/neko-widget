"""One actual-app Grant on a frozen Vision-queue candidate; diagnostic only."""
from pathlib import Path
import argparse,collections,hashlib,json,os,platform,re,shutil,signal,subprocess,tempfile,time

BASE='c60921fce31225e4c601fd16be1f359fad0967a7'
BRANCH='refs/heads/diagnostic/automatic-membership-vision-native-20261016'
HELPER='NekoWidget/ci/diagnose-vision-native-candidate.py'
WORKFLOW='.github/workflows/ios-ui-diagnostic.yml'
HARNESS_SHA256='11a1dac0485a951c4a55ffabc50f8d0f7225601210c7fc32601ea00f309c92d9'
CASE='NekoWidgetUITests.PhotoPermissionUITests testGrantFullPhotoLibraryAccess'
EVENT=re.compile(r"Test Case '-\[([^\]]+)\]' (started|passed|failed|skipped)")
CI=Path(__file__).resolve().parent
PLAN={'diagnosticOnly':True,'releaseEvidence':False,'productSourceSHA':BASE,
    'firstCandidateAt':'2026-10-15T23:31:48.229Z','expectedMinutes':[12,20],
    'workflowBudgetMinutes':25,'referenceIsNotGuarantee':True,
    'changedBehavior':'One actual original Grant on the bounded Vision queue candidate; omit unrelated preparation and all later acceptance/fixtures. Real TCC prompt, original UI assertions/deadline and original checkpoint validator retained.',
    'maximumOriginalGrants':1,'fullPreparationExecuted':False,'snapshotResets':0,
    'samplers':0,'requiredCase':CASE,'newPaidContracts':0,
    'remainingUncertainty':['Target Apple type/actor compilation','Mac OperationQueue runtime',
        'Real PhotoKit/Vision and rendered onboarding/settings behavior','Original AX cause remains a hypothesis; a passing diagnostic is not full native qualification']}

def git(*args):
    return subprocess.check_output(['git',*args],cwd=CI,text=True,encoding='utf-8').rstrip('\n')

def identity():
    source=os.environ.get('NEKO_VISION_NATIVE_SOURCE_SHA','')
    if (re.fullmatch(r'[0-9a-f]{40}',source) is None or source!=os.environ.get('GITHUB_SHA')
        or os.environ.get('GITHUB_EVENT_NAME')!='workflow_dispatch'
        or os.environ.get('GITHUB_REF')!=BRANCH or os.environ.get('GITHUB_RUN_ATTEMPT')!='1'
        or os.environ.get('GITHUB_REPOSITORY')!='soso-so-27/neko-widget'
        or platform.system()!='Darwin' or platform.machine()!='arm64'
        or os.environ.get('DEVELOPER_DIR')!='/Applications/Xcode_26.3.app/Contents/Developer'
        or os.environ.get('SMOKE_IOS_RUNTIME')!='com.apple.CoreSimulator.SimRuntime.iOS-18-6'
        or os.environ.get('NEKO_IOS_RUNTIME_SCOPE')!='full-v1'):
        raise RuntimeError('Exact one-off native diagnostic identity required')
    if git('rev-parse','HEAD')!=source or git('show','-s','--format=%P',source)!=BASE or git('status','--porcelain'):
        raise RuntimeError('Expected clean direct-base native diagnostic')
    rows=git('diff','--raw','--no-renames','--no-abbrev',BASE,source).splitlines()
    expected={HELPER:('A',':000000','100644'),WORKFLOW:('M',':100644','100644')}
    if len(rows)!=2:raise RuntimeError('Unexpected diagnostic source closure')
    for row in rows:
        raw,path=row.split('\t');f=raw.split()
        if path not in expected or (f[4],f[0],f[1])!=expected.pop(path):
            raise RuntimeError('Nonordinary or changed native inputs')
    if expected:raise RuntimeError('Missing diagnostic source')
    return source

def instrument(source):
    if hashlib.sha256(source.encode()).hexdigest()!=HARNESS_SHA256:
        raise RuntimeError('Original harness changed')
    prep='if (( ${#SMOKE_PREPARATION_ARGUMENTS[@]} > 0 )); then\n'
    phase='    BOOTSTRAP_TEST_ACTION=test-without-building\nfi\n\n'
    if source.count(prep)!=1 or source.count(phase)!=1:raise RuntimeError('Preparation boundary changed')
    start=source.index(prep);end=source.index(phase,start)+len(phase)
    source=source[:start]+source[end:]
    checkpoint='''python3 "$PHOTO_PERMISSION_VALIDATOR" \\
    --tcc-report "$ARTIFACT_DIRECTORY/tcc-permission-checkpoint.json" \\
    --log-directory "$PERMISSION_EVIDENCE_DIRECTORY/diagnostic-logs" \\
    --bundle-identifier "$APP_BUNDLE_ID"
'''
    if source.count(checkpoint)!=1:raise RuntimeError('Original checkpoint changed')
    source=source[:source.index(checkpoint)+len(checkpoint)]+'\nexit 0\n'
    if source.count('"${SMOKE_BOOTSTRAP_ARGUMENTS[@]}"')!=1:
        raise RuntimeError('Original single Grant command changed')
    return source

def run():
    source=identity();started=time.monotonic()
    root=Path(os.environ['RUNNER_TEMP'])/'neko-vision-native-diagnostic';root.mkdir(exist_ok=False)
    result=dict(PLAN,sourceSHA=source)
    temporary=None
    try:
        if shutil.which('swiftc') is None:raise RuntimeError('Mac queue check must execute, never skip')
        units=subprocess.run(['python3',str(CI/'test-photo-permission-bootstrap.py')],cwd=CI.parent,
            text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=110)
        result['unitChecks']={'exit':units.returncode,'stdout':units.stdout}
        if units.returncode!=0 or 'skipped=' in units.stdout or 'Ran 10 tests' not in units.stdout:
            raise RuntimeError('Actual Mac queue/bootstrap checks did not all run successfully')
        script=instrument((CI/'run-simulator-smoke.sh').read_text(encoding='utf-8'))
        result['temporaryScriptSHA256']=hashlib.sha256(script.encode()).hexdigest()
        (root/'diagnostic-script.sh').write_text(script,encoding='utf-8')
        with tempfile.NamedTemporaryFile(mode='w',encoding='utf-8',newline='\n',prefix='.vision-native-',suffix='.sh',dir=CI,delete=False) as stream:
            stream.write(script);temporary=Path(stream.name)
        syntax=subprocess.run(['bash','-n',str(temporary)],text=True,capture_output=True,timeout=10)
        if syntax.returncode:raise RuntimeError('Private diagnostic shell syntax failed: '+syntax.stderr)
        native=subprocess.Popen(['bash',str(temporary)],cwd=CI.parent,start_new_session=True)
        try:
            code=native.wait(timeout=22*60)
        except subprocess.TimeoutExpired:
            if native.poll() is None and os.getpgid(native.pid)==native.pid:
                os.killpg(native.pid,signal.SIGTERM)
            try:native.wait(timeout=30)
            except subprocess.TimeoutExpired:
                if native.poll() is None and os.getpgid(native.pid)==native.pid:os.killpg(native.pid,signal.SIGKILL)
                native.wait(timeout=5)
            raise RuntimeError('Bounded native observation timed out; no retry')
        result['nativeExitStatus']=code
        artifact=Path(os.environ['RUNNER_TEMP'])/'neko-smoke-artifacts'
        log=(artifact/'smoke-test.log').read_text(encoding='utf-8',errors='replace')
        events=EVENT.findall(log);counts=collections.Counter(events)
        result['nativeEvents']=[list(x) for x in events]
        result['exactCaseAccepted']=(len(events)==2 and counts[(CASE,'started')]==counts[(CASE,'passed')]==1)
        result['accepted']=code==0 and result['exactCaseAccepted']
        result['originalUITestSHA256']=hashlib.sha256((CI.parent/'NekoWidgetUITests/PhotoPermissionUITests.swift').read_bytes()).hexdigest()
    except Exception as error:
        result['error']=type(error).__name__+': '+str(error)
    finally:
        if temporary is not None:temporary.unlink()
        result['seconds']=time.monotonic()-started
        (root/'result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    return 0 if result.get('accepted') is True else 2

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode',nargs='?',choices=('describe','run'),default='describe')
    args=parser.parse_args()
    if args.mode=='run':raise SystemExit(run())
    print(json.dumps(PLAN,indent=2))
