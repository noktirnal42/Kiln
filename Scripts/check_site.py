#!/usr/bin/env python3
"""Validate local Pages links, semantic basics and fragment targets without dependencies."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit, unquote
import sys
ROOT = Path(__file__).resolve().parents[1] / 'site'
class Page(HTMLParser):
    def __init__(self):
        super().__init__(); self.links=[]; self.ids=set(); self.h1=0; self.main=0; self.errors=[]; self.lang=False
    def handle_starttag(self, tag, attrs):
        a=dict(attrs)
        if tag=='html': self.lang=bool(a.get('lang'))
        if tag=='h1': self.h1+=1
        if tag=='main': self.main+=1
        if 'id' in a:
            if a['id'] in self.ids: self.errors.append('duplicate id: '+a['id'])
            self.ids.add(a['id'])
        for key in ('href','src'):
            if a.get(key): self.links.append(a[key])
        if tag=='img' and 'alt' not in a: self.errors.append('image missing alt text')
pages={}
for path in sorted(ROOT.glob('*.html')):
    page=Page();page.feed(path.read_text());pages[path.resolve()]=page
errors=[]
for path,page in pages.items():
    for error in page.errors: errors.append(f'{path.name}: {error}')
    if page.h1!=1 or page.main!=1 or not page.lang: errors.append(f'{path.name}: expected language, one h1 and one main')
    for link in page.links:
        u=urlsplit(link)
        if u.scheme or u.netloc: continue
        dest=(path.parent/unquote(u.path)).resolve() if u.path else path
        if not dest.is_relative_to(ROOT.resolve()): errors.append(f'{path.name}: link escapes site: {link}');continue
        if not dest.exists(): errors.append(f'{path.name}: missing target: {link}')
        elif u.fragment and dest in pages and unquote(u.fragment) not in pages[dest].ids: errors.append(f'{path.name}: missing fragment: {link}')
if errors:
    print('\n'.join(errors));sys.exit(1)
print(f'PASS: {len(pages)} pages; local links, fragment targets, alt text, language and landmarks checked.')
