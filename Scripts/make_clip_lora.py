#!/usr/bin/env python3
"""Clip 2 (LoRA from chat), portrait 1080x1920, muted, captioned. Usage: make_clip_lora.py MAC.mov OUT.mp4
MAC.mov: full-screen recording at 3024x1964 with Kiln tiled to the left half (Window > Move & Resize > Left) so no other window overlaps."""
import subprocess, sys, tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
mac, out = sys.argv[1], sys.argv[2]
W, H = 1080, 1920; BG = (24, 22, 19); FG = (240, 235, 225); AC = (216, 179, 138); DIM = (150, 140, 128)
F = lambda s: ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', s)
CROP = '1487:1760:400:70'   # Kiln main pane only: no sidebar with chat titles
SEGS = [ (7, 6, 'LoRA fine-tuning from chat', 'Real Kiln 0.1.1, Ask mode. A 60-line text dataset I wrote; base model Qwen3-0.6B 4-bit (already cached). Prompt typed live.'),
         (20, 10, 'Training uses compute, so Kiln asks first', 'The gate shows the tool, a consequence line and the exact parameters: 60 iterations, rank 8.'),
         (38, 4, 'The agent reports back', 'It imported the dataset, started the run and checked its status.'),
         (66, 10, 'The same run in Model Lab', 'Completed in 16.9 s; training loss 1.471, validation 1.552. A smoke run on a tiny dataset: quality not evaluated.') ]
tmp = Path(tempfile.mkdtemp()); parts = []
def wrap(d, text, font, x, y, width, fill):
    line = ''
    for w in text.split():
        t = (line + ' ' + w).strip()
        if d.textlength(t, font=font) > width: d.text((x, y), line, font=font, fill=fill); y += font.size + 8; line = w
        else: line = t
    d.text((x, y), line, font=font, fill=fill); return y + font.size + 8
for i, (ss, dur, head, sub) in enumerate(SEGS):
    c = Image.new('RGB', (W, H), BG); d = ImageDraw.Draw(c)
    y = wrap(d, head, F(52), 40, 40, 1000, FG); wrap(d, sub, F(32), 40, y + 6, 1000, AC)
    d.text((40, H - 60), 'Kiln 0.1.1 preview · MIT · real screen recording, not affiliated with Apple', font=F(26), fill=DIM)
    cap = tmp / f'c{i}.png'; c.save(cap); part = tmp / f'p{i}.mp4'
    fc = '[0:v]fps=30,crop=%s,scale=1040:-2[m];[1:v][m]overlay=20:300' % CROP
    subprocess.run(['ffmpeg','-v','error','-y','-ss',str(ss),'-t',str(dur),'-i',mac,'-loop','1','-t',str(dur),'-i',str(cap),'-filter_complex',fc,'-t',str(dur),'-r','30','-pix_fmt','yuv420p','-c:v','libx264','-crf','24','-an',str(part)], check=True)
    parts.append(part)
lst = tmp / 'l.txt'; lst.write_text(''.join(f"file '{p}'\n" for p in parts))
subprocess.run(['ffmpeg','-v','error','-y','-f','concat','-safe','0','-i',str(lst),'-c','copy','-movflags','+faststart',out], check=True)
print(out)
