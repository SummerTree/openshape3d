"""Contact sheet of a finished Short: a frame every `step` seconds, labelled.

    shorts_contact.py VIDEO OUT.png [step]
"""
import subprocess, sys, tempfile, os
from PIL import Image, ImageDraw
from common import font

video, out = sys.argv[1], sys.argv[2]
step = float(sys.argv[3]) if len(sys.argv) > 3 else 1.5
dur = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", video],
                           capture_output=True, text=True).stdout.strip())
tmp = tempfile.mkdtemp()
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", video, "-vf", f"fps=1/{step},scale=270:480",
                os.path.join(tmp, "f%04d.png")], check=True)
files = sorted(os.listdir(tmp))
cols, w, h = 10, 270, 480
sheet = Image.new("RGB", (cols * w, ((len(files) + cols - 1) // cols) * (h + 22)), (0, 0, 0))
d = ImageDraw.Draw(sheet)
for i, f in enumerate(files):
    x, y = (i % cols) * w, (i // cols) * (h + 22)
    sheet.paste(Image.open(os.path.join(tmp, f)).convert("RGB"), (x, y + 22))
    d.text((x + 6, y + 2), f"{i * step:.1f}s", font=font(16, True), fill=(255, 255, 0))
sheet.save(out)
print(out, f"{dur:.1f}s", len(files), "frames")
