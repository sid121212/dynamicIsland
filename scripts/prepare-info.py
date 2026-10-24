#!/usr/bin/env python3
"""Validate public release settings and stamp a copied Info.plist. Never reads private keys."""
import base64, json, os, pathlib, plistlib, re, sys
from urllib.parse import urlparse
root = pathlib.Path(__file__).resolve().parent.parent
config = json.loads((root/'release.config.json').read_text())
info = plistlib.loads((root/'Resources/Info.plist').read_bytes())
site = os.environ.get('SITE_URL','').rstrip('/')
url = urlparse(site)
if url.scheme != 'https' or not url.hostname or url.path or url.query or url.fragment or url.username or url.port or re.search(r'(^|\.)(example\.(com|org|net)|localhost)$|placeholder',url.hostname,re.I) or re.search(r'github|git\.io',url.hostname,re.I): sys.exit('Set SITE_URL to your final public HTTPS origin (no placeholder)')
contact = os.environ.get('CONTACT_EMAIL','')
if not re.fullmatch(r'[^\s@?&]+@[^\s@?&]+\.[^\s@?&]+',contact): sys.exit('Set CONTACT_EMAIL for Report a Problem')
slug = config['slug']
key = os.environ.get('SPARKLE_PUBLIC_ED_KEY') or config['sparklePublicEDKey']
version = os.environ.get('RELEASE_VERSION', info['CFBundleShortVersionString'])
build = os.environ.get('RELEASE_BUILD', info['CFBundleVersion'])
if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?',version): sys.exit('Version must be semver, optionally with a pre-release suffix')
if '-' in version and any(part.isdigit() and len(part)>1 and part.startswith('0') for part in version.split('-',1)[1].split('.')): sys.exit('Numeric semver pre-release identifiers cannot have leading zeros')
if not re.fullmatch(r'[1-9][0-9]*',build): sys.exit('Build must be a positive integer')
try:
    if len(base64.b64decode(key,validate=True)) != 32: raise ValueError()
except Exception: sys.exit('Set SPARKLE_PUBLIC_ED_KEY or sparklePublicEDKey to your real 32-byte base64 public key')
notarized=os.environ.get('NOTARIZED','0')
if notarized not in ('0','1'): sys.exit('NOTARIZED must be 0 or 1')
info.update(SUFeedURL=f'{site}/downloads/{slug}/appcast.xml',ZDLContactEmail=contact,ZDLSiteURL=site,SUPublicEDKey=key,
            SUEnableAutomaticChecks=True,SUScheduledCheckInterval=86400,
            CFBundleVersion=build,CFBundleShortVersionString=version,NSHumanReadableCopyright='© '+str(__import__('datetime').date.today().year)+' Zero Dollar Labs')
if len(sys.argv)>1: pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps(info,fmt=plistlib.FMT_XML))
