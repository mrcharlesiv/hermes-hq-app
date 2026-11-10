#!/usr/bin/env python3
"""desktoplook: per-pixel comparison of two screenshots (the look-off guard, spec §3.6). The status bar band (top 130 px
of a 3x shot) is masked. Prints the number of differing pixels and exits 1 when there are any. No dependencies.
Usage: python3 scripts/fixtures/desktoplook-diff.py a.png b.png [--mask-top 130]"""
import struct, sys, zlib


def rows(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', path
    pos, idat, head = 8, [], None
    while pos < len(data):
        length, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b'IHDR':
            head = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            idat.append(body)
        pos += 12 + length
    width, height, depth, colour, _, _, interlace = head
    assert interlace == 0 and colour in (2, 6), head
    bpp = (3 if colour == 2 else 4) * depth // 8
    raw = zlib.decompress(b''.join(idat))
    stride = width * bpp
    out, prev = [], bytearray(stride)
    for y in range(height):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if f == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                line[i] = (line[i] + ((line[i - bpp] if i >= bpp else 0) + prev[i]) // 2) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out.append(bytes(line))
        prev = line
    return width, height, bpp, out


def main():
    a, b = rows(sys.argv[1]), rows(sys.argv[2])
    top = int(sys.argv[sys.argv.index('--mask-top') + 1]) if '--mask-top' in sys.argv else 130
    if a[:3] != b[:3]:
        print('sizes differ', a[:3], b[:3]); sys.exit(1)
    width, height, bpp = a[:3]
    count, first, last = 0, None, None
    for y in range(top, height):
        ra, rb = a[3][y], b[3][y]
        if ra == rb:
            continue
        n = sum(1 for x in range(width) if ra[x * bpp:(x + 1) * bpp] != rb[x * bpp:(x + 1) * bpp])
        count += n
        first = y if first is None else first
        last = y
    print('%d differing pixels%s' % (count, '' if not count else ' (rows %d-%d)' % (first, last)))
    sys.exit(1 if count else 0)


main()
