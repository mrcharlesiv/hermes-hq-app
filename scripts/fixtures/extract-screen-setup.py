#!/usr/bin/env python3
"""Takes the Mac screen installer out of the web build's bundle module, byte for byte (docs/spec/3x-screen.md §5.13).

  python3 scripts/fixtures/extract-screen-setup.py <bundle .js> App/Resources/Screen/HermesHQScreenSetup.zip

The module holds  filename:`…`,dataUrl:`data:application/zip;base64,…`,sha256:`…`  . The zip is decoded in memory and
written only when its size is 550,200 bytes and its SHA-256 is the one public build 240 shipped. It is never unpacked.
"""
import base64, hashlib, pathlib, re, sys

SIZE = 550200
SHA256 = '71ff241d0a3e803b8a457a9df5f91c14df48c1f227893d785974837af0c8de09'


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    text = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8', errors='replace')
    found = re.search(r'data:application/zip;base64,([A-Za-z0-9+/=]+)', text)
    if not found:
        sys.exit('no zip data URL in that file')
    data = base64.b64decode(found.group(1))
    digest = hashlib.sha256(data).hexdigest()
    if len(data) != SIZE or digest != SHA256:
        sys.exit(f'refusing to write: {len(data)} bytes, sha256 {digest} (expected {SIZE} bytes, {SHA256})')
    out = pathlib.Path(sys.argv[2])
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(data)
    print(f'wrote {out} ({len(data)} bytes, sha256 {digest})')


if __name__ == '__main__':
    main()
