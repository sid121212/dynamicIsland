import os,pathlib,subprocess,tempfile,json
root=pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory() as d:
 p=pathlib.Path(d);logs=p/'calls';bin=p/'bin';bin.mkdir()
 gh=bin/'gh';gh.write_text('''#!/usr/bin/env python3
import os,sys,json
args=sys.argv[1:]
with open(os.environ['MOCK_LOG'],'a') as f:f.write(json.dumps(args)+'\\n')
if args[0]=='api': print('v0.5.1')
elif args[:2]==['issue','list'] and os.environ.get('MOCK_EXISTING')=='1':print('7')
''');gh.chmod(0o755)
 curl=bin/'curl';curl.write_text('#!/bin/sh\nprintf "%s" "${MOCK_CODE:-200}"\n');curl.chmod(0o755)
 env={**os.environ,'PATH':str(bin)+':'+os.environ['PATH'],'MOCK_LOG':str(logs),'GITHUB_REPOSITORY':'example/notch'}
 for code,existing,expect,operation in [('200','0',0,None),('404','0',1,'create'),('500','1',1,'comment')]:
  logs.write_text('');result=subprocess.run([str(root/'scripts/healthcheck.sh')],env={**env,'MOCK_CODE':code,'MOCK_EXISTING':existing},capture_output=True,text=True)
  assert result.returncode==expect,(code,result.stderr)
  calls=[json.loads(s) for s in logs.read_text().splitlines()]
  assert (any(a[:2]==['issue',operation] for a in calls) if operation else not any(a[0]=='issue' for a in calls)),calls
 print('Healthcheck mocks passed: HTTP 200, create issue on failure, comment on existing issue. No GitHub calls made.')
