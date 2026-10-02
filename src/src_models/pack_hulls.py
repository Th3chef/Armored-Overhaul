"""Armored Overhaul 3.1 - packs the two rebuilt tank hulls (build_mbt_hull.py's output) into the Turret Models patch.

  pack_hulls.py BASTION_BASE MAELSTROM_BASE OUT_DIR      (*_BASE: <path>.main / <path>.gpu)

Writes OUT_DIR/9ba626afa44a3aa3.patch_0 (+ .gpu_resources, .stream) with the two unit resources, the game package's
own header bytes and the TOC padded the way the game's model packages are."""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
import patch_writer
UNIT = 0xE0A48D0BE9A7453F
BASTION, MAELSTROM = 0x16474112801385B6, 0xB0C9FAF4AF8903F9
HEADER = bytes.fromhex('000000001cfa464200000000f52f5043a38b24bc0014ed000000000000f030010000000000000000000000000000000000000000'
                       '0000000000000000')
if __name__ == '__main__':
    bast, mael, out = sys.argv[1:4]
    entries = [(rid, UNIT, open(b + '.main', 'rb').read(), open(b + '.gpu', 'rb').read(), b'', 16)
               for rid, b in ((BASTION, bast), (MAELSTROM, mael))]
    toc, gpu, stream = patch_writer.write(entries, [(UNIT, 16)], header=HEADER, first_index=1, pad_toc=True)
    patch_writer.check(toc, gpu, stream)
    os.makedirs(out, exist_ok=True)
    p = os.path.join(out, '9ba626afa44a3aa3.patch_0')
    open(p, 'wb').write(toc); open(p + '.gpu_resources', 'wb').write(gpu); open(p + '.stream', 'wb').write(stream)
    print('wrote', p, len(toc), len(gpu))
