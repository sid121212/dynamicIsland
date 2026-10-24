#!/usr/bin/env python3
import pathlib,sys
for name in sys.argv[1:]:
 p=pathlib.Path(name); size=p.stat().st_size
 print(f'{p.name}: {size} bytes ({size/1048576:.2f} MiB)')
 if size>=25*1024*1024:sys.exit(f'{p.name} must be smaller than 25 MiB; refusing release')
