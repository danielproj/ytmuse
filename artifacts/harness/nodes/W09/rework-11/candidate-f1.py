"""Bounded task-specific launch/identity/hash receipt. No UI synthesis or resizing."""
from pathlib import Path
import datetime,hashlib,json,os,re,subprocess,sys,uuid
R=Path(__file__).resolve().parents[5]; RUN=R/'artifacts/harness/nodes/W09/rework-11/runs/W09-scroll-final-20261027T211848Z-ae4d5437'
h=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
def verify():
 b=json.loads((RUN/'candidate-native-binding.json').read_text()); s=json.loads(Path(b['source_manifest']).read_text()); assert all(h(R/f)==v for f,v in s.items())
 assert not subprocess.check_output(['git','status','--porcelain','--','App','Packages','Resources','Tests','scripts'],cwd=R,text=True)
 roots={'debug':'Debug/YTMuse.app','release':'Release/YTMuse.app','ui-runner':'Debug/NativeMusicUITests-Runner.app'}; products=json.loads(Path(b['full_products_manifest']).read_text())
 for k,root in roots.items():
  p=R/'.build/xcode/Build/Products'/root; assert {str(f.relative_to(p)):h(f) for f in p.rglob('*') if f.is_file()}==products[k],k
 assert h(b['compiled_readonly_tool'])==b['compiled_readonly_tool_sha256']; assert h(R/b['tool_source'])==b['tool_source_sha256']; assert h(b['source_manifest'])==b['source_manifest_sha256'];assert h(b['full_products_manifest'])==b['full_products_manifest_sha256']
 return b
mode=sys.argv[1];b=verify()
if mode=='launch':
 ps=subprocess.check_output(['ps','-axo','pid=,comm='],text=True);exe=b['app_path']+'/Contents/MacOS/YTMuse'; existing=[line.strip() for line in ps.splitlines() if line.strip().split(' ',1)[-1].strip()==exe];assert not existing,existing
 tag=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:8];d=R/'artifacts/harness/nodes/W09/rework-11/cua'/('CUA-F1-'+tag);d.mkdir(parents=True); private=R/'.build'/('w09-candidate-f1-'+tag);private.mkdir();env=os.environ.copy();removed=[k for k in env if k.startswith(('YTMUSE_','TEST_RUNNER_')) or k in ['E01_OBSERVATION_ROOT','T09_HEADLESS','T06_HEADLESS','W09_HUMAN_RESIZE_CONFIRMED']]
 for k in removed:env.pop(k,None)
 wanted={'YTMUSE_UI_DEVELOPMENT_DATA':'1','YTMUSE_NATIVE_DESIGN_TEST':'1','YTMUSE_OWNED_AUDIO_TEST_GAIN':'0.001'};args=['-ApplePersistenceIgnoreState','YES','-AppleKeyboardUIMode','3'];argv=['open','-n','-a',b['app_path'],'--stdout',str(private/'stdout.log'),'--stderr',str(private/'stderr.log')]
 for k,v in wanted.items():argv+=['--env',k+'='+v]
 argv+=['--args']+args;start=datetime.datetime.now(datetime.timezone.utc);p=subprocess.run(argv,env=env);receipt={'source':b['source'],'first_owned_open_start':start.isoformat(),'deadline_utc':(start+datetime.timedelta(seconds=180)).isoformat(),'argv':argv,'expected_env':wanted,'process_args':args,'foreign_env_keys_removed':removed,'exit':p.returncode,'source_files_verified':b['source_files'],'product_files_verified':b['product_files'],'private_logs':str(private),'binding':b};(d/'launch.json').write_text(json.dumps(receipt,indent=2)+'\n');print(d);print(json.dumps(receipt));assert p.returncode==0
elif mode=='frame':
 d=Path(sys.argv[2]);pid=sys.argv[3];exe=subprocess.check_output(['ps','-p',pid,'-o','comm='],text=True).strip();assert exe==b['app_path']+'/Contents/MacOS/YTMuse'
 rawenv=subprocess.check_output(['ps','eww','-p',pid,'-o','command='],text=True);whitelist=dict(re.findall(r'(?:^|\s)(YTMUSE_[A-Z_]+|E01_OBSERVATION_ROOT|T09_HEADLESS|T06_HEADLESS|W09_HUMAN_RESIZE_CONFIRMED|TEST_RUNNER_W09_HUMAN_RESIZE_CONFIRMED)=([^\s]*)',rawenv));assert whitelist=={'YTMUSE_UI_DEVELOPMENT_DATA':'1','YTMUSE_NATIVE_DESIGN_TEST':'1','YTMUSE_OWNED_AUDIO_TEST_GAIN':'0.001'},whitelist
 record={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'pid':int(pid),'executable':exe,'start_time':subprocess.check_output(['ps','-p',pid,'-o','lstart='],text=True).strip(),'args':subprocess.check_output(['ps','-p',pid,'-o','args='],text=True).strip(),'actual_whitelisted_test_env':whitelist,'binding':b};(d/'before-binding.json').write_text(json.dumps(record,indent=2)+'\n');argv=[b['compiled_readonly_tool'],b['app_path'],pid,'before',str(d/'before.json')];p=subprocess.run(argv,capture_output=True,text=True);(d/'before-tool.json').write_text(json.dumps({'argv':argv,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr},indent=2)+'\n');assert p.returncode==0; print(record);print((d/'before.json').read_text())
else:raise SystemExit('Unknown mode')
