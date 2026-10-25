#!/usr/bin/env python3
import html,pathlib,re,sys
version,out,htmlout=sys.argv[1:]
p=pathlib.Path('CHANGELOG.md');text=p.read_text() if p.exists() else ''
match=re.search(r'^##\s+\[?'+re.escape(version)+r'\]?(?:\s+[^\n]*)?\n(.*?)(?=^##\s|\Z)',text,re.M|re.S)
if match: notes=match[1].strip()
elif sys.stdin.isatty():
    print('Enter release notes. Finish with a line containing only END:',file=sys.stderr)
    lines=[]
    for line in sys.stdin:
        if line.strip()=='END':break
        lines.append(line)
    notes=''.join(lines).strip()
else: sys.exit('Add a reviewed ## '+version+' section to CHANGELOG.md before packaging (or run interactively).')
if not notes:sys.exit('Release notes cannot be empty')
pathlib.Path(out).write_text(notes+'\n')
pathlib.Path(htmlout).write_text('<!doctype html><html><body>'+''.join('<p>'+html.escape(p).replace('\n','<br>')+'</p>' for p in re.split(r'\n\s*\n',notes))+'</body></html>')
