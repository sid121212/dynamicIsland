#!/usr/bin/env python3
"""Collect license text, preserving copyright and license terms without remote repository links."""
import json,os,pathlib,re,sys
root=pathlib.Path(__file__).resolve().parent.parent
out=pathlib.Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
contact=os.environ.get('CONTACT_EMAIL','')
if not contact:sys.exit('CONTACT_EMAIL is required for bundled license contact')
(out/'LICENSE.txt').write_text((root/'LICENSE.txt').read_text().replace('{{CONTACT_EMAIL}}',contact))
parts=['Third-Party Notices — Notch\n\nThird-party components remain governed by their own licenses.\n']
components=json.loads((root/'Resources/third-party-components.json').read_text())
for component in components:
 parts.append(f"{component['name']} — {component['license']}\n{component['attribution']}\n")
files=sorted((root/'.build/checkouts').glob('*/LICENSE*'))+[root/'Vendor/mediaremote-adapter/LICENSE']
if not any(p.parent.name=='Sparkle' for p in files):sys.exit('Resolve Sparkle before generating notices')
for file in files:
 if not file.is_file():continue
 text=file.read_text()
 # This heading URL is optional provenance, not a copyright or license condition.
 text=text.replace('Portable C implementation of Ed25519, from https://github.com/orlp/ed25519','Portable C implementation of Ed25519 (orlp/ed25519)')
 if re.search(r'github\.com|githubusercontent\.com|github\.io|ghcr\.io|gist\.github|git\.io',text,re.I):sys.exit(f'Review repository URL in license notice without removing mandatory terms: {file}')
 parts.append(f'\n--- {file.parent.name} / {file.name} ---\n\n{text}\n')
(out/'THIRD-PARTY-NOTICES.txt').write_text('\n'.join(parts))
