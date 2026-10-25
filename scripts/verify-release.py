#!/usr/bin/env python3
"""Verify exactly the five-file Notch release contract, without extracting ZIP contents."""
import base64,hashlib,os,pathlib,plistlib,re,subprocess,sys,zipfile,xml.etree.ElementTree as ET
ROOT=pathlib.Path(__file__).resolve().parent.parent
S='http://www.andymatuschak.org/xml-namespaces/sparkle'; LIMIT=26214400
try:
    folder=pathlib.Path(sys.argv[1]); site=os.environ.get('SITE_URL',''); key=os.environ.get('SPARKLE_PUBLIC_ED_KEY','')
    if not site.startswith('https://') or site.endswith('/'): raise ValueError('Set SITE_URL to the public HTTPS origin without a trailing slash')
    files={p.name:p for p in folder.iterdir()}
    dmgs=[n for n in files if re.fullmatch(r'Notch-\d+\.\d+\.\d+\.dmg',n)]
    if len(dmgs)!=1: raise ValueError('Expected exactly one Notch-X.Y.Z.dmg')
    dmg=files[dmgs[0]]; version=dmg.name[6:-4]; stem='Notch-'+version
    expected={stem+'.dmg',stem+'.zip',stem+'.dmg.sha256','appcast.xml','release-notes.md'}
    if set(files)!=expected: raise ValueError('dist must contain exactly: '+', '.join(sorted(expected)))
    for p in files.values():
        if not p.is_file() or not 0<p.stat().st_size<LIMIT: raise ValueError(p.name+': must be a nonempty file under 25 MiB')
    checksum=files[stem+'.dmg.sha256'].read_text()
    match=re.fullmatch(r'([a-fA-F0-9]{64})  '+re.escape(dmg.name)+r'\n?',checksum)
    if not match or match[1].lower()!=hashlib.sha256(dmg.read_bytes()).hexdigest(): raise ValueError('DMG checksum format/hash mismatch')
    text=files['appcast.xml'].read_text()
    markup=re.sub(r'<!\[CDATA\[[\s\S]*?\]\]>|<!--[\s\S]*?-->', '', text)
    if '<!DOCTYPE' in markup.upper() or '<!ENTITY' in markup.upper(): raise ValueError('XML entities are forbidden')
    if re.search(r'github\.com|githubusercontent\.com|github\.io|ghcr\.io|git\.io',text,re.I): raise ValueError('GitHub URL in appcast')
    items=ET.fromstring(text).findall('./channel/item')
    if len(items)!=1: raise ValueError('Appcast must have exactly ONE item')
    item=items[0]; enc=item.findall('enclosure')
    if len(enc)!=1: raise ValueError('Expected exactly ONE enclosure')
    enc=enc[0]
    def value(k): return item.findtext('{'+S+'}'+k) or enc.get('{'+S+'}'+k)
    build=value('version'); archive=files[stem+'.zip']
    if not re.fullmatch(r'[1-9]\d*',build or ''): raise ValueError('Build must be a positive integer')
    if value('shortVersionString')!=version or value('minimumSystemVersion')!='15.0': raise ValueError('Wrong appcast version/minimumSystemVersion')
    if enc.get('url')!=site+'/downloads/notch/'+archive.name: raise ValueError('Wrong appcast enclosure URL')
    if int(enc.get('length','0'))!=archive.stat().st_size: raise ValueError('Wrong appcast ZIP length')
    signature=enc.get('{'+S+'}edSignature','')
    if len(base64.b64decode(signature,validate=True))!=64: raise ValueError('Invalid EdDSA signature')
    if not item.findtext('description','').strip(): raise ValueError('Missing embedded release notes')
    with zipfile.ZipFile(archive) as z:
        infofiles=[i for i in z.infolist() if re.fullmatch(r'[^/]+\.app/Contents/Info\.plist',i.filename)]
        if len(infofiles)!=1 or infofiles[0].file_size>1048576: raise ValueError('Missing/oversized/ambiguous Info.plist in ZIP')
        info=plistlib.loads(z.read(infofiles[0]))
        for k,want in dict(SUFeedURL=site+'/downloads/notch/appcast.xml',SUPublicEDKey=key,CFBundleShortVersionString=version,CFBundleVersion=build,LSMinimumSystemVersion='15.0').items():
            if info.get(k)!=want: raise ValueError('ZIP Info.plist '+k+' mismatch')
        for notice in ['LICENSE.txt','THIRD-PARTY-NOTICES.txt']:
            name=infofiles[0].filename.removesuffix('Info.plist')+'Resources/'+notice
            if not z.getinfo(name).file_size: raise ValueError('Missing bundled '+notice)
    if os.environ.get('RELEASE_VERSION') and os.environ['RELEASE_VERSION']!=version: raise ValueError('Requested version differs from dist')
    if os.environ.get('RELEASE_BUILD') and os.environ['RELEASE_BUILD']!=build: raise ValueError('Requested build differs from dist')
    verifier=ROOT/'build/VerifyReleaseArchive';verifier.parent.mkdir(exist_ok=True)
    subprocess.run(['xcrun','swiftc','-module-cache-path',str(ROOT/'build/ModuleCache'),str(ROOT/'scripts/verify-update.swift'),'-o',str(verifier)],check=True)
    subprocess.run([str(verifier),str(archive),signature,key],check=True)
    subprocess.run(['python3',str(ROOT/'scripts/check-dmg-notices.py'),str(dmg)],check=True)
    print(f'OK Notch {version}, build {build}: five assets, sizes, SHA-256, single-item appcast, EdDSA, Info.plist and bundled licenses verified.')
except Exception as e: sys.exit('Release verification failed: '+str(e))
