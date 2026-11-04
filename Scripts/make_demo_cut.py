#!/usr/bin/env python3
"""Assemble the demo cut from raw screen recordings (not committed: too large, may show other windows).
Usage: make_demo_cut.py MAC.mov PHONE.mov OUT_DIR
MAC.mov: `screencapture -v` full-screen recording of Kiln on a 3024x1964 display; PHONE.mov: `xcrun simctl io <udid> recordVideo`.
The phone clip starts about 1 s after the Mac clip. Crops keep only Kiln's main pane (no sidebar chat titles).
Needs ffmpeg and Pillow. Captions are PNG overlays because this ffmpeg has no drawtext."""
import subprocess, sys, tempfile, json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
mac, phone, out = sys.argv[1], sys.argv[2], Path(sys.argv[3]); out.mkdir(parents=True, exist_ok=True)
W, H = 1920, 1080; BG = (24, 22, 19); FG = (240, 235, 225); AC = (216, 179, 138); DIM = (150, 140, 128); OK = (120, 200, 140)
F = lambda s: ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', s)
tmp = Path(tempfile.mkdtemp())
MAC_CROP = '1140:1310:790:310'; PHONE_CROP = '1206:1180:0:0'
# (kind, mac_start, seconds, headline, sub, tag_mac, tag_phone)
SEGS = [
 ('card', 0, 5, 'Fix a failing test. Approve it from a phone.', 'Kiln 0.1.1 preview. Unedited screen recordings; cuts are marked. The phone is the iOS Simulator, not a real iPhone or watch.', None, None),
 ('sbs', 10, 12, 'Ask mode: the agent is told to run the tests, fix the bug, re-run, commit.', 'Real Kiln on the Mac. Model: gemma4:31b via Ollama Cloud. Typed live.', 'MAC: real Kiln 0.1.1', None),
 ('sbs', 24, 22, 'Before the command runs, Kiln stops and says what it will do.', 'Tool, access level, the exact command, and a plain-language consequence line.', 'MAC: real Kiln 0.1.1', 'iPHONE: iOS Simulator (real Mac, real approval)'),
 ('cut', 0, 2, 'cut: about 4 s of waiting', '', None, None),
 ('sbs', 66, 12, 'The agent fixed the file and re-runs the test. Same approval, answered on the phone again.', 'The file write was not gated here: a standing grant on this Mac covers write_file.', 'MAC: real Kiln 0.1.1', 'iPHONE: iOS Simulator'),
 ('cut', 0, 2, 'cut: about 4 s of waiting', '', None, None),
 ('sbs', 79, 14, 'The commit is gated too, with its message. This one was answered with the mouse on the Mac.', 'Allow once / Deny are on the phone as well; Always Allow is not.', 'MAC: real Kiln 0.1.1', 'iPHONE: iOS Simulator'),
 ('sbs', 100, 6, 'Tests pass; the fix is committed.', 'The agent reports what it ran. The tool list is its own record of the run.', 'MAC: real Kiln 0.1.1', 'iPHONE: iOS Simulator'),
 ('log', 0, 10, 'Every decision is logged, with how it was answered.', 'Verbatim from Kiln\'s approvals.jsonl for this run (a file excerpt, not the app UI).', None, None),
 ('card', 0, 7, 'What this does not show', 'No Apple Watch: watch alerts, the Apple push key and the relay were not filmed. Setting up remote approvals needs a relay you host and an Apple push key. Preview software; github.com/noktirnal42/Kiln. Not affiliated with Apple.', None, None),
]
def base(head, sub):
    c = Image.new('RGB', (W, H), BG); d = ImageDraw.Draw(c)
    d.text((60, 36), head, font=F(40), fill=FG)
    if sub: d.text((60, 92), sub, font=F(26), fill=AC)
    d.text((60, H-44), 'Kiln 0.1.1 preview · MIT · demo project, hosted model gemma4:31b', font=F(20), fill=DIM)
    return c, d
def wrap(d, text, font, x, y, width, fill, gap=10):
    line = ''
    for w in text.split():
        t = (line + ' ' + w).strip()
        if d.textlength(t, font=font) > width: d.text((x, y), line, font=font, fill=fill); y += font.size + gap; line = w
        else: line = t
    d.text((x, y), line, font=font, fill=fill)
def frame(i, kind, head, sub, tm, tp):
    c, d = base(head, sub if kind not in ('card',) else '')
    if kind == 'card':
        wrap(d, sub, F(32), 60, 190, 1600, AC, 18)
    if kind == 'cut': c = Image.new('RGB', (W, H), BG); d = ImageDraw.Draw(c); d.text((W//2-260, H//2-20), head, font=F(44), fill=DIM)
    if kind == 'log':
        rows = [json.loads(l) for l in open(Path.home()/'Library/Application Support/Kiln/logs/approvals.jsonl')][-4:]
        y = 190
        for r in rows:
            via = r.get('via'); col = OK if via == 'remote' else FG
            line = f'tool={r["toolName"]}  decision={r["decision"]}  via={via if via else "(standing grant)"}  waitedMs={r.get("waitedMs", "-")}'
            d.text((70, y), line, font=ImageFont.truetype('/System/Library/Fonts/Menlo.ttc', 30), fill=col); y += 52
            d.text((70, y), 'preview: ' + r['preview'].splitlines()[0][:110], font=ImageFont.truetype('/System/Library/Fonts/Menlo.ttc', 24), fill=DIM); y += 80
        d.text((70, y), 'via=remote rows were answered from the iOS Simulator companion; via=mouse was clicked on the Mac.', font=F(28), fill=AC)
    p = tmp / f'cap{i}.png'; c.save(p); return p
# Recordings are variable frame rate (a phone idle on one screen emits almost no frames), so normalise to 30 fps first.
subprocess.run(['ffmpeg','-v','error','-y','-i',mac,'-vf',f'fps=30,crop={MAC_CROP}','-c:v','libx264','-crf','20','-an',str(tmp/'mac.mp4')],check=True)
subprocess.run(['ffmpeg','-v','error','-y','-i',phone,'-vf',f'fps=30,crop={PHONE_CROP}','-c:v','libx264','-crf','20','-an',str(tmp/'phone.mp4')],check=True)
mac, phone = str(tmp/'mac.mp4'), str(tmp/'phone.mp4')
cmds = []; parts = []
for i, (kind, ss, dur, head, sub, tm, tp) in enumerate(SEGS):
    cap = frame(i, kind, head, sub, tm, tp); part = tmp / f'p{i}.mp4'
    if kind == 'sbs':
        mh = 840; mw = int(1140 / 1310 * mh); ph = 840; pw = int(1206 / 1180 * ph)
        gap = 70; total = mw + gap + pw; x0 = (W - total) // 2; y0 = 190
        fc = (f'[0:v]scale={mw}:{mh}[m];[1:v]scale={pw}:{ph}[p];'
              f'[2:v][m]overlay={x0}:{y0}[a];[a][p]overlay={x0+mw+gap}:{y0}[b]')
        args = ['-ss', str(ss), '-t', str(dur), '-i', mac, '-ss', str(max(ss-1, 0)), '-t', str(dur), '-i', phone, '-loop', '1', '-t', str(dur), '-i', str(cap), '-filter_complex', fc, '-map', '[b]']
        # tags
        tg = Image.open(cap).convert('RGB'); dd = ImageDraw.Draw(tg)
        if tm: dd.text((x0, y0-36), tm, font=F(22), fill=OK)
        if tp: dd.text((x0+mw+gap, y0-36), tp, font=F(22), fill=AC)
        tg.save(cap)
    else:
        args = ['-loop', '1', '-t', str(dur), '-i', str(cap), '-map', '0:v']
    subprocess.run(['ffmpeg', '-v', 'error', '-y', *args, '-t', str(dur), '-r', '30', '-pix_fmt', 'yuv420p', '-c:v', 'libx264', '-crf', '24', '-an', str(part)], check=True)
    parts.append(part)
lst = tmp / 'list.txt'; lst.write_text(''.join(f"file '{p}'\n" for p in parts))
final = out / 'kiln-demo-draft.mp4'
subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', str(lst), '-c', 'copy', '-movflags', '+faststart', str(final)], check=True)
# review stills (one per scene) and a contact sheet, for reviewing without playing the video
pos = 0; stills = []
for i, (kind, ss, dur, *_r) in enumerate(SEGS):
    if kind != 'cut':
        sp = out / f'still{i}.png'
        subprocess.run(['ffmpeg','-v','error','-y','-ss',str(pos + dur*0.6),'-i',str(final),'-frames:v','1',str(sp)], check=True); stills.append(sp)
    pos += dur
sheet = Image.new('RGB', (1920, 540*((len(stills)+1)//2)))
for k, sp in enumerate(stills): sheet.paste(Image.open(sp).resize((960, 540)), ((k % 2)*960, (k//2)*540))
sheet.save(out / 'storyboard.png')
print(final)
