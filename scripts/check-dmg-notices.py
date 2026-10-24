#!/usr/bin/env python3
import pathlib,plistlib,subprocess,sys
result=subprocess.run(['hdiutil','attach','-readonly','-nobrowse','-plist',sys.argv[1]],check=True,capture_output=True)
mounts=[entry['mount-point'] for entry in plistlib.loads(result.stdout).get('system-entities',[]) if entry.get('mount-point')]
if not mounts:sys.exit('No mounted DMG volume to check')
try:
 for mount in mounts:
  subprocess.run([sys.executable,str(pathlib.Path(__file__).with_name('check-license-files.py')),mount],check=True)
  apps=list(pathlib.Path(mount).glob('*.app'))
  if len(apps)!=1:sys.exit('Expected exactly one app in the release DMG')
  subprocess.run([sys.executable,str(pathlib.Path(__file__).with_name('check-license-files.py')),str(apps[0]/'Contents/Resources')],check=True)
finally:
 for mount in reversed(mounts):subprocess.run(['hdiutil','detach',mount],check=True)
