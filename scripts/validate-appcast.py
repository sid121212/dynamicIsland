#!/usr/bin/env python3
import base64, pathlib, re, sys, xml.etree.ElementTree as ET
from urllib.parse import urlparse
SPARKLE='http://www.andymatuschak.org/xml-namespaces/sparkle'
def validate(path,version,build,url):
    text=pathlib.Path(path).read_text()
    if re.search(r'github\.com|githubusercontent\.com|github\.io|ghcr\.io|gist\.github|git\.io',text,re.I):raise ValueError('Forbidden host in appcast')
    for found in re.findall(r'https?://[^\s<>"\']+',text):
        if found==SPARKLE:continue
        if urlparse(found).netloc!=urlparse(url).netloc:raise ValueError('Appcast URLs must stay on the site origin')
    root=ET.parse(path).getroot()
    items=root.findall('./channel/item')
    if len(items)!=1: raise ValueError('Expected one new full update')
    item=items[0];enclosure=item.find('enclosure')
    if enclosure is None: raise ValueError('Missing update enclosure')
    def value(name): return item.findtext(f'{{{SPARKLE}}}{name}') or enclosure.get(f'{{{SPARKLE}}}{name}')
    if value('version')!=build or value('shortVersionString')!=version:raise ValueError('Wrong release version/build')
    if enclosure.get('url')!=url:raise ValueError('Unexpected update URL')
    if len(base64.b64decode(enclosure.get(f'{{{SPARKLE}}}edSignature',''),validate=True))!=64:raise ValueError('Missing EdDSA signature or wrong signing key')
    if int(enclosure.get('length','0'))<=0:raise ValueError('Empty update')
    if not item.findtext('description'):raise ValueError('Missing embedded release notes')
if __name__=='__main__':
    try: validate(*sys.argv[1:])
    except Exception as error: sys.exit(f'Appcast validation failed: {error}')
