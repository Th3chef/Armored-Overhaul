"""Armored Overhaul - FRV stability (1.3; retuned in 2.1.0). Writes a patch archive holding the physics resources of the
three FRVs (M-102 Fast Recon Vehicle, M-103 Supply FRV, M-104 incendiary FRV) retuned so they stay on their wheels.
Written from the game's own files; every value is checked against the game's number before it is changed.
2.1.0 (released in 3.0.0): tyre grip, wheel radius, front damping, suspension travel and mass added, with our own
numbers; Planted also keeps the chassis roll settings of 1.3. What changes, read from each file itself:
  - wheels (Havok raycast wheels, "VRW " block, four 0x70-byte records, front = negative y):
      +0x24 tyre grip (game front 1.0 / rear 0.9), +0x28 wheel radius (game 0.55: ground clearance),
      +0x58 compression damping (game front 0.75 / rear 1.25: the soft front lets the nose bounce and pitch the car
      over; the front gets the rear's), +0x5C rebound damping / suspension travel (game front 4.0 / rear 6.5).
  - rigid body (mass, then the centre of mass 0x38 later): mass raised (the same share on every FRV) and the centre
    of mass lowered from z -0.375.
  - chassis roll (Havok vehicle data, "VRD " block; Planted only): the roll torque factor (game 0.9) lowered and the
    roll unit inertia (game 0.8) raised.
Engine and steering stay the game's own.
(3.1.0 Test 24) Grip, wheel radius and the chassis roll went back to the game's. (Test 30) Retuned: grip and wheel radius
raised again and the chassis roll left alone (the roll change was what made Planted worse); Mild is the lightest, Stable
the middle, Planted a step past it, and the chassis roll stays the game's.
Usage: make_frv.py VANILLA_DIR OUT_DIR   (VANILLA_DIR: the three .physics.main files as Filediver extracts them from
the game's own archives: frv, frv_supply, frv_flamer)"""
import struct, sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
import patch_writer
PHYSICS = 0x5f7203c8f280dab8
FILES = [('frv.physics.main', 0xcc21c7ffd3ebefb9, 3000.0),          # content/fac_helldivers/vehicles/frv/frv
         ('frv_supply.physics.main', 0x9b2140378640432e, 2500.0),   # .../frv_supply/frv_supply
         ('frv_flamer.physics.main', 0x2d85bfe3d8717fe5, 7500.0)]   # .../frv_heavy/frv_flamer
GAME = {'grip': (1.0, 0.9), 'radius': 0.55, 'comp': (0.75, 1.25), 'rebound': (4.0, 6.5), 'com_z': -0.375,
        'roll_torque': 0.9, 'roll_inertia': 0.8}          # (front, rear) where they differ
PRESETS = {                                               # folder: what each preset sets (mass as a share of the game's)
    # (3.1.0 Test 30) Retune: more mass, a lower centre of mass, firmer front compression damping, a larger wheel radius,
    # more grip and rebound, and no change to the chassis roll; Mild about half of Stable and Planted a step past it.
    # The chassis roll stays the game's in all three (lowering it was what made Planted worse).
    # (3.1.0 Test 40) On Test 39 (run on Mild): "tweak the stable option a bit and add more grip for the frv". Grip
    # up a step on all three (front / rear): Mild 1.1 / 1.0 -> 1.2 / 1.1 (the old Stable's), Stable 1.2 / 1.1 -> 1.35 /
    # 1.25, Planted 1.25 / 1.15 -> 1.4 / 1.3. Everything else as Test 30.
    # (3.1.0 Test 41) Stable tuned again, each value nudged and still between Mild and Planted: grip 1.36 /
    # 1.26, radius 0.615, compression 1.2 / 1.3 (front still close to the rear), rebound 5.4 / 7.6, centre of mass -0.62,
    # mass x1.3.
    # Test 24: grip and radius the game's, centre of mass -0.5 / -0.65 / -0.85, mass x1.15 / 1.3 / 1.45.
    'FRV Mild': {'grip': (1.2, 1.1), 'radius': 0.585, 'comp': (1.0, 1.25), 'rebound': (4.75, 7.0), 'com_z': -0.49,
                 'mass': 1.165},
    'FRV Stable': {'grip': (1.36, 1.26), 'radius': 0.615, 'comp': (1.2, 1.3), 'rebound': (5.4, 7.6), 'com_z': -0.62,
                   'mass': 1.3},
    'FRV Planted': {'grip': (1.4, 1.3), 'radius': 0.62, 'comp': (1.4, 1.4), 'rebound': (6.2, 8.2), 'com_z': -0.75,
                    'mass': 1.45},
}

# the patch header's engine metadata, as in the game's own packages (the tank suspension patches carry the same bytes)
HEADER = ('000000001cfa464200000000f52f5043a38b24bc0014ed000000000000f030010000000000000000000000000000000000000000'
          '0000000000000000')
def f32(d, o): return struct.unpack_from('<f', d, o)[0]
def put(d, o, old, new):
    assert abs(f32(d, o) - old) < 1e-4, (hex(o), f32(d, o), old)     # only ever the game's own number
    struct.pack_into('<f', d, o, new)

def retune(data, mass, p):
    d = bytearray(data)
    v = d.find(b'VRW ')
    assert v > 0 and d.find(b'VRW ', v + 4) < 0
    n = struct.unpack_from('<I', d, v + 4)[0]
    assert n == 4, n
    fronts = 0
    for i in range(n):
        w = v + struct.unpack_from('<I', d, v + 8 + 4 * i)[0]
        k = 0 if f32(d, w + 0x10) < 0 else 1                 # 0 front, 1 rear
        fronts += k == 0
        put(d, w + 0x24, GAME['grip'][k], p['grip'][k])
        put(d, w + 0x28, GAME['radius'], p['radius'])
        put(d, w + 0x58, GAME['comp'][k], p['comp'][k])
        put(d, w + 0x5C, GAME['rebound'][k], p['rebound'][k])
    assert fronts == 2
    at = [o for o in (0x120, 0x130) if abs(f32(d, o) - mass) < 1e-3]
    assert len(at) == 1, 'mass not found'
    put(d, at[0], mass, round(mass * p['mass']))
    put(d, at[0] + 0x40, GAME['com_z'], p['com_z'])
    r = d.find(b'VRD ')
    assert r > 0 and d.find(b'VRD ', r + 4) < 0
    if 'roll_torque' in p:
        put(d, r + 0x1C, GAME['roll_torque'], p['roll_torque'])
        put(d, r + 0x34, GAME['roll_inertia'], p['roll_inertia'])
    return bytes(d)

def write_patch(path, entries):
    # (the same layout as the tank suspension patches: 72-byte header, one type row, 80-byte entries)
    types = [(t, 64) for t in sorted({t for _, t, _ in entries})]
    toc, _, _ = patch_writer.write([(fid, tid, data, b'', b'', 64) for fid, tid, data in entries], types,
                                   header=bytes.fromhex(HEADER), first_index=1)
    patch_writer.check(toc)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, 'wb').write(toc)
    open(path + '.gpu_resources', 'wb').write(b''); open(path + '.stream', 'wb').write(b'')

if __name__ == '__main__':
    src, out = sys.argv[1], sys.argv[2]
    originals = []
    for name, fid, mass in FILES:
        data = open(os.path.join(src, name), 'rb').read()
        assert struct.unpack_from('<Q', data, 8)[0] == fid, name     # (the file names its own resource id)
        originals.append((fid, mass, data))
    for folder, p in PRESETS.items():
        entries = [(fid, PHYSICS, retune(data, mass, p)) for fid, mass, data in originals]
        write_patch(os.path.join(out, folder, '9ba626afa44a3aa3.patch_0'), entries)
        print(folder, p)
