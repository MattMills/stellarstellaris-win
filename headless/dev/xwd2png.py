"""xwd2png.py in.xwd out.png: an X window dump (24/32 bpp ZPixmap, as xwd -root writes it) to PNG."""
import struct
import sys

from PIL import Image

data = open(sys.argv[1], "rb").read()
h = struct.unpack(">25I", data[:100])
header_size, width, height, bpp, bytes_per_line, ncolors = h[0], h[4], h[5], h[11], h[12], h[19]
off = header_size + ncolors * 12
pix = data[off : off + bytes_per_line * height]
mode = "BGRX" if bpp == 32 else "BGR"
img = Image.frombuffer("RGB", (width, height), pix, "raw", mode, bytes_per_line, 1)
img.save(sys.argv[2])
print(f"{width}x{height} {bpp}bpp -> {sys.argv[2]}")
