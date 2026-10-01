"""Keep only the unit entries (the resources we actually change) from one or more patches written by HD2SDK and
write them as one patch.  Usage: strip_patch.py SRC [SRC ...] DST"""
import struct, sys
UNIT = 0xe0a48d0be9a7453f
srcs, dst = sys.argv[1:-1], sys.argv[-1]
ents = []; hdr = None
for src in srcs:
    d = open(src, 'rb').read(); g = open(src + '.gpu_resources', 'rb').read(); s = open(src + '.stream', 'rb').read()
    magic, nt, n = struct.unpack_from('<III', d, 0)
    if hdr is None: hdr = d[12:72]
    for i in range(n):
        fid, tid, off, soff, goff, u1, u2, size, ssize, gsize, a, b, idx = struct.unpack_from('<7Q6I', d, 72 + 32 * nt + 80 * i)
        if tid == UNIT:
            assert fid not in [e[0] for e in ents], hex(fid)
            ents.append((fid, tid, d[off:off + size], g[goff:goff + gsize], s[soff:soff + ssize]))
types = sorted({e[1] for e in ents})
head = struct.pack('<III', magic, len(types), len(ents)) + hdr
for t in types: head += struct.pack('<QQQII', 0, t, sum(e[1] == t for e in ents), 16, 64)
cursor = len(head) + 80 * len(ents); rows = body = b''; gpu = bytearray(); stream = bytearray()
for i, (fid, tid, data, gd, sd) in enumerate(ents, 1):
    pad = -cursor % 16; body += b'\0' * pad; cursor += pad
    goff = 0
    if gd: gpu += b'\0' * (-len(gpu) % 64); goff = len(gpu); gpu += gd
    soff = 0
    if sd: stream += b'\0' * (-len(stream) % 64); soff = len(stream); stream += sd
    rows += struct.pack('<7Q6I', fid, tid, cursor, soff, goff, 0, 0, len(data), len(sd), len(gd), 16, 64, i)
    body += data; cursor += len(data)
toc = head + rows + body
toc += b'\0' * max(0, 256 * len(ents) - len(toc))
open(dst, 'wb').write(toc); open(dst + '.gpu_resources', 'wb').write(bytes(gpu)); open(dst + '.stream', 'wb').write(bytes(stream))
print('kept', [hex(e[0]) for e in ents], 'toc', len(toc), 'gpu', len(gpu))
