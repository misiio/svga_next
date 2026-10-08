"""Writes an 8x8, 3-frame looping GIF: red, green, blue, 100 ms per frame."""
import struct, sys

W = H = 8
palette = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (0, 0, 0)]

def lzw_uncompressed(indices, min_code_size=2):
    clear, eoi, width = 1 << min_code_size, (1 << min_code_size) + 1, min_code_size + 1
    codes = []
    for i, px in enumerate(indices):
        if i % 2 == 0:
            codes.append(clear)  # reset before the table forces a wider code
        codes.append(px)
    codes.append(eoi)
    out, acc, nbits = bytearray(), 0, 0
    for c in codes:
        acc |= c << nbits
        nbits += width
        while nbits >= 8:
            out.append(acc & 0xFF); acc >>= 8; nbits -= 8
    if nbits:
        out.append(acc & 0xFF)
    return bytes(out)

def sub_blocks(data):
    out = bytearray()
    for i in range(0, len(data), 255):
        chunk = data[i:i + 255]
        out += bytes([len(chunk)]) + chunk
    return bytes(out + b"\x00")

gif = bytearray(b"GIF89a")
gif += struct.pack("<HHBBB", W, H, 0b10000001, 0, 0)  # global table, 4 entries
for r, g, b in palette:
    gif += bytes([r, g, b])
gif += b"\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00"  # loop forever
for colour in range(3):
    gif += b"\x21\xF9\x04" + struct.pack("<BHB", 0b00000100, 10, 0) + b"\x00"  # 10 cs, keep
    gif += b"\x2C" + struct.pack("<HHHHB", 0, 0, W, H, 0)
    gif += b"\x02" + sub_blocks(lzw_uncompressed([colour] * (W * H)))
gif += b"\x3B"
open(sys.argv[1], "wb").write(gif)
