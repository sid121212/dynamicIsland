#!/usr/bin/env python3
from html.parser import HTMLParser
import pathlib,sys,re
class Notes(HTMLParser):
 def __init__(self):super().__init__();self.parts=[]
 def handle_data(self,data):
  if data.strip():self.parts.append(data.strip())
p=Notes();p.feed(pathlib.Path(sys.argv[1]).read_text())
text='\n\n'.join(p.parts)+'\n'
if re.search(r'github\.com|githubusercontent\.com|github\.io|ghcr\.io|gist\.github|git\.io',text,re.I):sys.exit('Forbidden host in release notes')
pathlib.Path(sys.argv[2]).write_text(text)
