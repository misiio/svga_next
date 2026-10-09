"""Writes a looping GIF of solid frames cycling red, green, blue, 100 ms each.

Usage: make_animated_gif.py PATH [WIDTH HEIGHT FRAMES]; without the size it writes 8x8, 3 frames.
"""
import struct, sys

path = sys.argv[1]
W, H, FRAMES = (int(a) for a in sys.argv[2:5]) if len(sys.argv) > 2 else (8, 8, 3)
palette = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (0, 0, 0)]

def lzw(indices, min_code_size=2):
    clear, eoi = 1 << min_code_size, (1 << min_code_size) + 1
    out, acc, nbits = bytearray(), 0, 0
    width = min_code_size + 1

    def emit(code):
        nonlocal acc, nbits
        acc |= code << nbits
        nbits += width
        while nbits >= 8:
            out.append(acc & 0xFF); acc >>= 8; nbits -= 8

    def reset():
        return {(i,): i for i in range(clear)}, eoi + 1, min_code_size + 1

    emit(clear)
    table, next_code, width = reset()
    prefix = (indices[0],)
    for px in indices[1:]:
        if prefix + (px,) in table:
            prefix += (px,)
            continue
        emit(table[prefix])
        if next_code < 4096:
            table[prefix + (px,)] = next_code
            next_code += 1
            if next_code - 1 == 1 << width and width < 12:
                width += 1  # the decoder widens once its table reaches this code
        else:
            emit(clear)
            table, next_code, width = reset()
        prefix = (px,)
    emit(table[prefix])
    emit(eoi)
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
for frame in range(FRAMES):
    gif += b"\x21\xF9\x04" + struct.pack("<BHB", 0b00000100, 10, 0) + b"\x00"  # 10 cs, keep
    gif += b"\x2C" + struct.pack("<HHHHB", 0, 0, W, H, 0)
    gif += b"\x02" + sub_blocks(lzw([frame % 3] * (W * H)))
gif += b"\x3B"
open(path, "wb").write(gif)
