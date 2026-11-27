"""Check each WinUI screenshot, not just its filename. Pure PNG validation; no desktop access."""
from pathlib import Path
import struct
import sys
import zlib

def intact_png(path):
    data = path.read_bytes()
    if not data.startswith(b'\x89PNG\r\n\x1a\n'):
        return False
    pos, have_image = 8, False
    while pos + 12 <= len(data):
        size, tag = struct.unpack_from('>I4s', data, pos)
        end = pos + size + 12
        if end > len(data) or zlib.crc32(data[pos+4:end-4]) != int.from_bytes(data[end-4:end], 'big'):
            return False
        if pos == 8 and (tag != b'IHDR' or size != 13 or not all(struct.unpack_from('>II', data, pos+8))):
            return False
        if tag == b'IDAT' and size: have_image = True
        if tag == b'IEND': return size == 0 and end == len(data) and have_image
        pos = end
    return False


def app_image(path):
    # RenderTargetBitmap writes 8-bit RGB(A), noninterlaced. Reject tiny placeholders, incomplete zlib streams,
    # invalid filter rows and one-colour images (including filtered ones) without needing an imaging package in CI.
    if path.stat().st_size > 48 * 1024**2 or not intact_png(path):
        return False
    data = path.read_bytes()
    w, h, depth, colour, compression, filtering, interlace = struct.unpack_from('>IIBBBBB', data, 16)
    channels = {2: 3, 6: 4}.get(colour)
    if not channels or depth != 8 or (compression, filtering, interlace) != (0, 0, 0) or not (64 <= w <= 8192 and 48 <= h <= 8192):
        return False
    stride = 1 + w * channels
    if stride * h > 64 * 1024**2:
        return False
    stream, pos = bytearray(), 8
    while pos < len(data):
        size, tag = struct.unpack_from('>I4s', data, pos)
        if tag == b'IDAT': stream.extend(data[pos + 8:pos + 8 + size])
        pos += size + 12
    try:
        d = zlib.decompressobj()
        raw = d.decompress(stream, h * stride + 1)
    except zlib.error:
        return False
    if not d.eof or d.unused_data or len(raw) != stride * h or any(f > 4 for f in raw[::stride]):
        return False
    # Zero alpha everywhere is invisible even if a PNG hides different RGB values underneath. PNG filters are
    # channel-independent: a zero alpha plane yields exactly zero filtered alpha bytes for all five filters.
    if channels == 4 and all(not raw[y * stride + 4:(y+1) * stride:4].strip(b'\x00') for y in range(h)):
        return False
    # A flat image's first pixel has no neighbours; the five PNG filters have these exact rows for that colour.
    pixel = raw[1:1 + channels]
    half = bytes(v - v // 2 for v in pixel)
    zero = bytes(w * channels)
    sub = pixel + zero[channels:]
    first = (pixel * w, sub, pixel * w, pixel + half * (w - 1), sub)
    rest = (first[0], sub, zero, half + zero[channels:], zero)
    return any(raw[y * stride + 1:(y + 1) * stride] != (first if y == 0 else rest)[raw[y * stride]] for y in range(h))


def check(directory):
    images = sorted(directory.glob('*.png'))
    if not images: raise ValueError('no screenshots')
    for image in images:
        if not app_image(image): raise ValueError(f'invalid or blank app screenshot: {image.name}')
    return len(images)


if __name__ == '__main__':
    print(f'{check(Path(sys.argv[1]))} nonblank app screenshots verified')
