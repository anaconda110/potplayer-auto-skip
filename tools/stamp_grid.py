"""Stamp per-cell timestamps onto tile contact sheets.
Usage: python stamp_grid.py <in.png> <out.png> <cols> <cell_h> <step_sec>
Grid assumed top-left origin, no padding between cells (ffmpeg tile).
"""
import sys
from PIL import Image, ImageDraw, ImageFont

src, dst, cols, cell_h, step, base = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5]), float(sys.argv[6]) if len(sys.argv) > 6 else 0.0
im = Image.open(src).convert('RGB')
W, H = im.size
cell_w = W / cols
rows = round(H / cell_h)
try:
    font = ImageFont.truetype(r'C:\Windows\Fonts\arial.ttf', 20)
except Exception:
    font = ImageFont.load_default()
d = ImageDraw.Draw(im)
for r in range(rows):
    for c in range(cols):
        i = r * cols + c
        t = i * step + base
        if t * 1000 >= H * 1000:  # noop guard
            pass
        label = '%d:%04.1f' % (t // 60, t % 60)
        x, y = int(c * cell_w) + 4, int(r * cell_h) + 4
        d.rectangle([x - 2, y - 2, x + 78, y + 24], fill=(0, 0, 0))
        d.text((x, y), label, fill=(255, 255, 0), font=font)
im.save(dst)
print('ok', dst, 'rows=', rows)
