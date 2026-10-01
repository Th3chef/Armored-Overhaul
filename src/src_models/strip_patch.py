"""Keep only the unit entries (the resources we actually change) from one or more patches written by HD2SDK and
write them as one patch.  Usage: strip_patch.py SRC [SRC ...] DST"""
import struct, sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
import patch_writer
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
types = [(t, 64) for t in sorted({e[1] for e in ents})]
toc, gpu, stream = patch_writer.write([(fid, tid, data, gd, sd, 64) for fid, tid, data, gd, sd in ents], types,
                                      header=hdr, first_index=1, pad_toc=True)
patch_writer.check(toc, gpu, stream)
open(dst, 'wb').write(toc); open(dst + '.gpu_resources', 'wb').write(gpu); open(dst + '.stream', 'wb').write(stream)
print('kept', [hex(e[0]) for e in ents], 'toc', len(toc), 'gpu', len(gpu))
