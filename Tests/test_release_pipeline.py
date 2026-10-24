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
 def test_publish_is_draft_first_and_betas_are_not_latest(self):
  import shutil
  for version in ('1.2.3','1.2.3-beta.1'):
   with self.subTest(version=version),tempfile.TemporaryDirectory() as temp:
    fixture=pathlib.Path(temp);(fixture/'scripts').mkdir();(fixture/'build').mkdir();(fixture/'Resources').mkdir();(fixture/'docs/release-notes').mkdir(parents=True);mock=fixture/'mock';mock.mkdir()
    for name in ('release.sh','prepare-info.py'):shutil.copy(ROOT/'scripts'/name,fixture/'scripts'/name)
    shutil.copy(ROOT/'release.config.json',fixture/'release.config.json');shutil.copy(ROOT/'Resources/Info.plist',fixture/'Resources/Info.plist')
    (fixture/f'docs/release-notes/{version}.html').write_text('<h2>Release notes</h2>')
    def executable(path,text):path.write_text(text);path.chmod(0o755)
    executable(fixture/'build.sh','#!/bin/bash\nexit 0\n')
    executable(fixture/'scripts/package-artifacts.sh','''#!/bin/bash
set -e
mkdir -p "dist/$1"
for file in "DynamicIsland-$1.dmg" "DynamicIsland-$1.zip" "DynamicIsland-$1.dmg.sha256" "DynamicIsland-$1.html" appcast.xml; do printf 'fixture' > "dist/$1/$file"; done
''')
    executable(mock/'gh','''#!/usr/bin/env python3
import os,json,sys
args=sys.argv[1:]
with open(os.environ['MOCK_LOG'],'a') as f:f.write(json.dumps(args)+'\\n')
if args[:2]==['release','view']:sys.exit(1)
if args[0]=='api':print('<!-- zerodollarlabs-build:11 -->')
''')
    executable(mock/'git','''#!/bin/bash
if [[ "$1" == rev-parse ]]; then printf 'fixture-head\\n'; fi
''')
    for name in ('codesign','hdiutil','ditto','cmake'):executable(mock/name,'#!/bin/sh\nexit 0\n')
    executable(fixture/'create-dmg','#!/bin/sh\nexit 0\n')
    env={**os.environ,'PATH':str(mock)+':'+os.environ['PATH'],'MOCK_LOG':str(fixture/'calls'),'CREATE_DMG':str(fixture/'create-dmg'),'RELEASE_REPOSITORY':'example/notch','SIGNING_IDENTITY':'mock-only','SITE_URL':'https://downloads.test.invalid','CONTACT_EMAIL':'support@test.invalid'}
    result=subprocess.run([str(fixture/'scripts/release.sh'),version,'12'],env=env,capture_output=True,text=True)
    self.assertEqual(result.returncode,0,result.stderr)
    calls=[json.loads(line) for line in (fixture/'calls').read_text().splitlines()]
    create=next(c for c in calls if c[:2]==['release','create']);edit=next(c for c in calls if c[:2]==['release','edit'])
    self.assertIn('--draft',create);self.assertIn('--draft=false',edit)
    self.assertLess(calls.index(create),calls.index(edit))
    self.assertIn('--latest=false' if '-beta' in version else '--latest',edit)
    self.assertTrue(any(c.endswith('appcast.xml') for c in create))
    # Reusing a published integer build must stop before packaging or creating a release.
    (fixture/'calls').write_text('')
    blocked=subprocess.run([str(fixture/'scripts/release.sh'),version,'11'],env=env,capture_output=True,text=True)
    self.assertNotEqual(blocked.returncode,0)
    self.assertIn('greater than every published build',blocked.stderr)
    rejected=[json.loads(line) for line in (fixture/'calls').read_text().splitlines()]
    self.assertFalse(any(c[:2]==['release','create'] for c in rejected))
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
if __name__=='__main__':unittest.main(verbosity=2)
