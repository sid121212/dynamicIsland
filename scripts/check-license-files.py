#!/usr/bin/env python3
import pathlib,sys
root=pathlib.Path(sys.argv[1])
for name in ('LICENSE.txt','THIRD-PARTY-NOTICES.txt'):
 file=root/name
 if not file.is_file() or not file.read_text().strip():sys.exit(f'Missing required release license file: {file}')
print(f'License files present: {root}')
