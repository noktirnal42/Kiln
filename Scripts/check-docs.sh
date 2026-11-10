#!/usr/bin/env bash
# Validate the public docs: README, the GitHub Pages site and the wiki sources in docs/wiki.
# No network access and no dependencies beyond bash and python3. Exit 1 on any problem.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== site (Scripts/check_site.py)"
python3 Scripts/check_site.py

echo "== README, wiki and privacy scan"
python3 - "$ROOT" <<'PY'
import re, sys
from pathlib import Path
from urllib.parse import urlsplit, unquote
from html.parser import HTMLParser

root = Path(sys.argv[1])
errors = []

def slug(heading: str) -> str:
    h = re.sub(r'<[^>]+>', '', heading).strip().lower()
    h = re.sub(r'[`*_\[\]()]', '', h)
    h = re.sub(r'[^\w\s-]', '', h)
    return re.sub(r'\s', '-', h)

def anchors_of(text: str) -> set:
    return {slug(m.group(2)) for m in re.finditer(r'^(#{1,6})\s+(.+?)\s*$', text, re.M)}

class Collect(HTMLParser):
    def __init__(self):
        super().__init__(); self.refs = []; self.ids = set()
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        for k in ('href', 'src'):
            if a.get(k): self.refs.append(a[k])
        if a.get('id'): self.ids.add(a['id'])

def check_local(ref, base: Path, where: str, own_anchors: set):
    u = urlsplit(ref)
    if u.scheme or u.netloc or ref.startswith('mailto:'):
        return
    if not u.path:
        if u.fragment and unquote(u.fragment) not in own_anchors:
            errors.append(f'{where}: missing anchor {ref}')
        return
    dest = (base.parent / unquote(u.path)).resolve()
    try:
        dest.relative_to(root)
    except ValueError:
        errors.append(f'{where}: link escapes the repository: {ref}'); return
    if not dest.exists():
        errors.append(f'{where}: missing target {ref}')
    elif u.fragment and dest.suffix == '.md':
        if unquote(u.fragment) not in anchors_of(dest.read_text()):
            errors.append(f'{where}: missing anchor {ref}')

# ---- README (markdown links, html href/src)
readme = root / 'README.md'
text = readme.read_text()
c = Collect(); c.feed(text)
refs = c.refs + re.findall(r'!?\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)', text)
for r in refs:
    check_local(r, readme, 'README.md', anchors_of(text))
if '## License' not in text or 'PolyForm Noncommercial' not in text or 'COMMERCIAL-LICENSE.md' not in text:
    errors.append('README.md: the License section must name PolyForm Noncommercial and link COMMERCIAL-LICENSE.md')

# ---- wiki sources
wiki = root / 'docs' / 'wiki'
pages = {p.stem: p for p in wiki.glob('*.md')}
required = ['Home', '_Sidebar', '_Footer', 'Getting-Started', 'Activities', 'Agent-and-Approvals',
            'MCP-Server-and-Tools', 'Providers-and-Keys', 'Model-Store', 'Reverse-Engineering-Workflow',
            'Develop-and-Debug', 'Browser', 'Devices', 'Media', 'Security-and-Privacy', 'Troubleshooting',
            'Building-and-Signing', 'Contributing', 'FAQ', 'Roadmap']
for r in required:
    if r not in pages: errors.append(f'wiki: missing page {r}.md')
for name, path in pages.items():
    t = path.read_text()
    where = f'docs/wiki/{path.name}'
    for m in re.finditer(r'\[\[([^\]|]+)(?:\|[^\]]*)?\]\]', t):
        target = m.group(1).strip().replace(' ', '-')
        if target not in pages: errors.append(f'{where}: [[{m.group(1)}]] has no page')
    for m in re.finditer(r'\]\((#[^)]+)\)', t):
        if unquote(m.group(1)[1:]) not in anchors_of(t): errors.append(f'{where}: missing anchor {m.group(1)}')
    for m in re.finditer(r'\]\((?!https?:|#|mailto:)([^)\s]+)\)', t):
        errors.append(f'{where}: relative link {m.group(1)} will break on the GitHub wiki; use a full URL or a [[Page]] link')
    if not name.startswith('_') and '**Verified status.**' not in t:
        errors.append(f'{where}: missing the "Verified status" note')

# ---- privacy scan of public docs
scan = [readme] + list(wiki.glob('*.md')) + list((root / 'site').glob('*.html')) + [root / 'docs' / 'DOCS-MAP.md']
bad = [(r'/Users/[A-Za-z0-9_.-]+', 'personal path'), (r'[\w.+-]+@(gmail|icloud|outlook|yahoo)\.[a-z]+', 'email address'),
       (r'\b(sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|xox[bp]-[A-Za-z0-9-]{10,}|nvapi-[A-Za-z0-9_-]{10,})', 'key-like token'),
       (r'LH8KLB9N4F', 'team identifier')]
for p in scan:
    if not p.exists(): continue
    t = p.read_text()
    for pat, why in bad:
        for m in re.finditer(pat, t):
            errors.append(f'{p.relative_to(root)}: {why}: {m.group(0)[:30]}')

if errors:
    print('\n'.join(errors)); sys.exit(1)
print(f'PASS: README links and images, {len(pages)} wiki pages (links, anchors, verified-status notes), privacy scan.')
PY
echo "docs OK"
