#!/usr/bin/env python3
"""Draft muted loop from real stills in site/assets/shots. Captions are honest about provenance.
Usage: python3 Scripts/make_marketing_loop.py  (needs ffmpeg and Pillow). Output: site/assets/kiln-approval-loop.mp4"""
import subprocess, tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
ROOT=Path(__file__).resolve().parents[1]; SH=ROOT/'site/assets/shots'
W,H=1280,720; BG=(24,22,19)
font=lambda s: ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',s)
SCENES=[ # (image, max height, headline, provenance, seconds)
 ('approval-crop.jpg',440,'1. The agent asks first. The gate states the consequence.','Real Kiln on the Mac: approval queue with a plain-language consequence line.',6),
 ('watch-approval.png',440,'2. The alert reaches your wrist: Allow once or Deny.','Companion simulator with demo data. Not a recording of a real watch.',6),
 ('audit-chain.png',230,'3. Every decision lands in the audit chain.','Real Kiln on the Mac: Audit view. Preview software.',6),
]
tmp=Path(tempfile.mkdtemp()); lst=[]
for i,(img,mh,head,prov,sec) in enumerate(SCENES):
    c=Image.new('RGB',(W,H),BG); d=ImageDraw.Draw(c)
    d.text((60,50),head,font=font(38),fill=(240,235,225)); d.text((60,110),prov,font=font(24),fill=(200,170,140))
    s=Image.open(SH/img).convert('RGB'); r=min(mh/s.height,(W-120)/s.width); s=s.resize((int(s.width*r),int(s.height*r)),Image.LANCZOS)
    c.paste(s,((W-s.width)//2,160+(H-160-s.height)//2)); d.text((60,H-50),'Kiln 0.1.1 preview · MIT · not affiliated with Apple',font=font(20),fill=(140,130,120))
    p=tmp/f's{i}.png'; c.save(p); lst+=['-loop','1','-t',str(sec),'-i',str(p)]
n=len(SCENES); fc=''.join(f'[{i}:v]format=yuv420p,setsar=1[v{i}];' for i in range(n))+''.join(f'[v{i}]' for i in range(n))+f'concat=n={n}:v=1:a=0[o]'
subprocess.run(['ffmpeg','-y','-loglevel','error',*lst,'-filter_complex',fc,'-map','[o]','-r','30','-c:v','libx264','-crf','23','-movflags','+faststart','-an',str(ROOT/'site/assets/kiln-approval-loop.mp4')],check=True)
