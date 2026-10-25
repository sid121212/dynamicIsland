#!/usr/bin/env python3
"""Release validation/failure tests; no Keychain access, GitHub mutation or private keys."""
import base64, importlib.util, json, os, pathlib, plistlib, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('appcast',ROOT/'scripts/validate-appcast.py')
appcast=importlib.util.module_from_spec(spec);spec.loader.exec_module(appcast)
class ReleaseChecks(unittest.TestCase):
 def prepare(self, **env):
  with tempfile.TemporaryDirectory() as temp:
   path=pathlib.Path(temp)/'Info.plist'
   proc=subprocess.run(['python3',str(ROOT/'scripts/prepare-info.py'),str(path)],env={**os.environ,'SITE_URL':'https://downloads.test.invalid','CONTACT_EMAIL':'support@test.invalid',**env},capture_output=True,text=True)
   return proc,plistlib.loads(path.read_bytes()) if path.exists() else None
 def test_valid_stable_and_beta_metadata(self):
  for version in ('1.2.3','1.2.3-beta','1.2.3-beta.2'):
   proc,info=self.prepare(RELEASE_VERSION=version,RELEASE_BUILD='42',NOTARIZED='0')
   self.assertEqual(proc.returncode,0,proc.stderr);self.assertEqual(info['CFBundleVersion'],'42');self.assertEqual(info['CFBundleShortVersionString'],version)
   self.assertEqual(info['SUScheduledCheckInterval'],86400);self.assertTrue(info['SUEnableAutomaticChecks'])
   self.assertEqual(info['SUPublicEDKey'],json.loads((ROOT/'release.config.json').read_text())['sparklePublicEDKey'])
 def test_invalid_public_key_version_build_and_flag(self):
  for env in ({'SPARKLE_PUBLIC_ED_KEY':'not-a-key'},{'RELEASE_VERSION':'v1.0'},{'RELEASE_VERSION':'01.2.3'},{'RELEASE_BUILD':'0'},{'RELEASE_BUILD':'1.2'},{'NOTARIZED':'yes'}):
   proc,info=self.prepare(**env);self.assertNotEqual(proc.returncode,0);self.assertIsNone(info)
 def test_appcast_rejects_unsigned_or_wrong_release(self):
  signature=base64.b64encode(bytes(64)).decode()
  xml=f'''<rss xmlns:sparkle="{appcast.SPARKLE}"><channel><item><sparkle:version>42</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString><description>Notes</description><enclosure url="https://example.com/app.zip" length="100" sparkle:edSignature="{signature}"/></item></channel></rss>'''
  with tempfile.TemporaryDirectory() as temp:
   path=pathlib.Path(temp)/'appcast.xml';path.write_text(xml)
   appcast.validate(path,'1.2.3','42','https://example.com/app.zip')
   for modified in (xml.replace(signature,''),xml.replace('>42<','>41<'),xml.replace('https://example.com/app.zip','http://wrong.invalid/file'),xml.replace('length="100"','length="0"'),xml.replace('<description>Notes</description>','')):
    path.write_text(modified)
    with self.assertRaises(Exception):appcast.validate(path,'1.2.3','42','https://example.com/app.zip')
 def test_missing_identity_fails_without_touching_app(self):
  info=ROOT/'build/Dynamic Island.app/Contents/Info.plist';before=info.read_bytes() if info.exists() else None
  proc=subprocess.run([str(ROOT/'build.sh')],env={**os.environ,'SIGNING_IDENTITY':'-NotARealCodeSigningCertificate-'},capture_output=True,text=True)
  self.assertNotEqual(proc.returncode,0)
  if before is not None:self.assertEqual(info.read_bytes(),before)
 def test_signer_rejects_adhoc(self):
  proc=subprocess.run([str(ROOT/'scripts/sign-app.sh'),'/nonexistent.app'],env={**os.environ,'SIGNING_IDENTITY':'-'},capture_output=True,text=True)
  self.assertNotEqual(proc.returncode,0);self.assertIn('Ad-hoc',proc.stderr)
 def test_local_release_modes_and_preflight(self):
  import shutil
  with tempfile.TemporaryDirectory() as temp:
   fixture=pathlib.Path(temp)
   for name in ('scripts','release','Resources','build','.build/artifacts/sparkle/Sparkle/bin','mock'):(fixture/name).mkdir(parents=True,exist_ok=True)
   shutil.copy(ROOT/'scripts/release.sh',fixture/'scripts/release.sh')
   shutil.copy(ROOT/'release/config.sh',fixture/'release/config.sh')
   shutil.copy(ROOT/'Resources/Info.plist',fixture/'Resources/Info.plist')
   def executable(path,text):path.write_text(text);path.chmod(0o755)
   executable(fixture/'build.sh','#!/bin/bash\necho build >> "$MOCK_LOG"\n')
   executable(fixture/'scripts/verify-release.sh','#!/bin/bash\necho verify >> "$MOCK_LOG"\n')
   executable(fixture/'scripts/package-artifacts.sh','''#!/bin/bash
mkdir -p dist
for n in "Notch-$1.dmg" "Notch-$1.zip" "Notch-$1.dmg.sha256" appcast.xml release-notes.md; do echo fixture > "dist/$n"; done
scripts/verify-release.sh dist
''')
   executable(fixture/'mock/git','''#!/bin/bash
case "$1" in
 branch) echo main;;
 status) echo -n "${MOCK_DIRTY:-}";;
 remote) echo https://github.com/example/notch.git;;
 rev-parse) echo fixture-head;;
 show-ref) exit 1;;
esac
''')
   executable(fixture/'mock/gh','''#!/usr/bin/env python3
import json,os,pathlib,sys
args=sys.argv[1:]
with open(os.environ['MOCK_LOG'],'a') as f:f.write(json.dumps(args)+'\\n')
if args[0]=='api':
 if args[-1]=='.private':print('true')
 elif '/commits/main' in args[1]:print('fixture-head')
 else:print('v0.9.0')
if args[:2]==['release','download']:
 p=pathlib.Path(args[args.index('--dir')+1]);p.mkdir(exist_ok=True)
 (p/'appcast.xml').write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>12</sparkle:version></item></channel></rss>')
''')
   executable(fixture/'mock/security','#!/bin/sh\necho NotchDev\n')
   for name in ('ditto','hdiutil','shasum'):executable(fixture/'mock'/name,'#!/bin/sh\nexit 0\n')
   for name in ('generate_keys','generate_appcast'):executable(fixture/'.build/artifacts/sparkle/Sparkle/bin'/name,'#!/bin/sh\necho fixture-public-key\n')
   env={**os.environ,'PATH':str(fixture/'mock')+':'+os.environ['PATH'],'MOCK_LOG':str(fixture/'calls'),'SITE_URL':'https://downloads.test.invalid','SITE_REPO':'example/site'}
   for mode in ('--no-publish','--publish-only',''):
    (fixture/'calls').write_text('')
    args=[str(fixture/'scripts/release.sh'),'1.0.0','13']+([mode] if mode else [])
    result=subprocess.run(args,env=env,capture_output=True,text=True)
    self.assertEqual(result.returncode,0,result.stderr)
    calls=(fixture/'calls').read_text()
    self.assertIn('verify',calls)
    self.assertEqual('build\n' in calls,mode!='--publish-only')
    self.assertEqual('["release", "create"' in calls,mode!='--no-publish')
    if mode!='--no-publish':self.assertIn('--draft=false',calls);self.assertIn('--prerelease=false',calls);self.assertIn('Notch 1.0.0',calls)
   for version,build,extra,reason in [('1.0.0','12',{},'must exceed'),('1.0.0-beta','13',{},'semver'),('1.0.0','13',{'MOCK_DIRTY':' M source.swift'},'clean on main')]:
    result=subprocess.run([str(fixture/'scripts/release.sh'),version,build,'--no-publish'],env={**env,**extra},capture_output=True,text=True)
    self.assertNotEqual(result.returncode,0);self.assertIn(reason,result.stderr)
 def test_size_limit_boundary(self):
  with tempfile.TemporaryDirectory() as temp:
   path=pathlib.Path(temp)/'fixture.zip'
   with path.open('wb') as f:f.truncate(25*1024*1024-1)
   good=subprocess.run(['python3',str(ROOT/'scripts/check-artifact-sizes.py'),str(path)],capture_output=True,text=True)
   self.assertEqual(good.returncode,0,good.stderr)
   with path.open('wb') as f:f.truncate(25*1024*1024)
   bad=subprocess.run(['python3',str(ROOT/'scripts/check-artifact-sizes.py'),str(path)],capture_output=True,text=True)
   self.assertNotEqual(bad.returncode,0);self.assertIn('25 MiB',bad.stderr)
 def test_site_origin_is_required_and_no_forbidden_host(self):
  for origin in ('','https://example.com','https://www.example.com','https://placeholder.invalid','https://github.com','http://site.invalid','https://site.invalid/path'):
   proc,info=self.prepare(SITE_URL=origin)
   self.assertNotEqual(proc.returncode,0);self.assertIsNone(info)
  proc,info=self.prepare()
  self.assertEqual(info['SUFeedURL'],'https://downloads.test.invalid/downloads/notch/appcast.xml')
 def test_built_app_guard_rejects_resource_host(self):
  import shutil
  with tempfile.TemporaryDirectory() as temp:
   app=pathlib.Path(temp)/'Guard.app';(app/'Contents/MacOS').mkdir(parents=True);(app/'Contents/Resources').mkdir()
   (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'fixture'}))
   shutil.copy('/usr/bin/true',app/'Contents/MacOS/fixture')
   (app/'Contents/Resources/forbidden.txt').write_text('https://github.com/forbidden')
   result=subprocess.run([str(ROOT/'scripts/check-no-github.sh'),str(app)],capture_output=True,text=True)
   self.assertNotEqual(result.returncode,0);self.assertIn('Forbidden host',result.stderr)
 def test_required_license_files(self):
  with tempfile.TemporaryDirectory() as temp:
   folder=pathlib.Path(temp)
   for files in ([],['LICENSE.txt'],['LICENSE.txt','THIRD-PARTY-NOTICES.txt']):
    for name in files:(folder/name).write_text('QA license fixture')
    result=subprocess.run(['python3',str(ROOT/'scripts/check-license-files.py'),str(folder)],capture_output=True,text=True)
    self.assertEqual(result.returncode==0,len(files)==2)
if __name__=='__main__':unittest.main(verbosity=2)
