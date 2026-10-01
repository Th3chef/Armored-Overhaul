"""Armored Overhaul - Tank Suspension presets. Writes patch archives holding the two tank hull physics resources with
the Havok suspension of every road wheel changed (the "VRW " vehicle raycast-wheel block: +0x54 spring strength,
+0x58 compression damping, +0x5C rebound damping; game values 12 / 0.5 / 3.7).
Usage: make_suspension.py OUT_DIR   (reads the game packages from the blender data folder)"""
import struct, sys, os
PHYSICS = 0x5f7203c8f280dab8
SOURCES = [('blendwork/data/68ebdce3f7498179', 0x16474112801385b6),   # TD-220 Bastion hull
           ('blendwork/data/65ee777b72347cb4', 0xb0c9faf4af8903f9)]   # TD-110 Maelstrom hull
GAME = (12.0, 0.5, 3.7)
PRESETS = {'Suspension Firm': (16.0, 1.5, 4.5), 'Suspension Heavy': (20.0, 3.0, 6.0)}

def read_entry(pkg, fid, tid):
    d = open(pkg, 'rb').read()
    magic, nt, n = struct.unpack_from('<III', d, 0)
    for i in range(n):
        f, t, off, soff, goff, u1, u2, size, ssize, gsize, a, b, idx = struct.unpack_from('<7Q6I', d, 72 + 32 * nt + 80 * i)
        if f == fid and t == tid:
            assert ssize == 0 and gsize == 0
            return d[off:off + size], d[12:72], magic
    raise KeyError(hex(fid))

def retune(data, values):
    data = bytearray(data)
    v = data.find(b'VRW ')
    assert v > 0 and data.find(b'VRW ', v + 4) < 0, 'expected one wheel block'
    count = struct.unpack_from('<I', data, v + 4)[0]
    assert count == 10, count
    for i in range(count):
        w = v + struct.unpack_from('<I', data, v + 8 + 4 * i)[0]
        old = struct.unpack_from('<3f', data, w + 0x54)
        assert tuple(round(x, 4) for x in old) == GAME, (i, old)      # only ever patch the game's own numbers
        struct.pack_into('<3f', data, w + 0x54, *values)
    return bytes(data)

def write_patch(path, entries, hdr, magic):
    types = sorted({t for _, t, _ in entries})
    head = struct.pack('<III', magic, len(types), len(entries)) + hdr
    for t in types: head += struct.pack('<QQQII', 0, t, sum(e[1] == t for e in entries), 16, 64)
    cursor = len(head) + 80 * len(entries); rows = body = b''
    for i, (fid, tid, data) in enumerate(entries, 1):
        pad = -cursor % 16; body += b'\0' * pad; cursor += pad
        rows += struct.pack('<7Q6I', fid, tid, cursor, 0, 0, 0, 0, len(data), 0, 0, 16, 64, i)
        body += data; cursor += len(data)
    toc = head + rows + body
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, 'wb').write(toc); open(path + '.gpu_resources', 'wb').write(b''); open(path + '.stream', 'wb').write(b'')

out_dir = sys.argv[1]
originals = [(fid,) + read_entry(pkg, fid, PHYSICS) for pkg, fid in SOURCES]
for folder, values in PRESETS.items():
    entries = [(fid, PHYSICS, retune(data, values)) for fid, data, hdr, magic in originals]
    write_patch(os.path.join(out_dir, folder, '9ba626afa44a3aa3.patch_0'), entries, originals[0][2], originals[0][3])
    print(folder, values, [len(e[2]) for e in entries])
