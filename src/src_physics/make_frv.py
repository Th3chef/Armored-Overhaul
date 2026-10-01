"""Armored Overhaul - FRV stability (1.3). Writes a patch archive holding the physics resources of the three FRVs
(M-102 Fast Recon Vehicle, M-103 Supply FRV, M-104 incendiary FRV) retuned so they stay on their wheels. Written from
the game's own files; every value is checked against the game's number before it is changed.
Three presets, picked as sub-options of the FRV stability option (Mild, Stable, Planted). What changes, read from each
file itself:
  - front suspension damping (Havok raycast wheels, "VRW " block, 0x70-byte wheel records): the game's front wheels
    have 0.75 compression / 4 rebound damping against the rear's 1.25 / 6.5, so the nose bounces and pitches the car
    into a roll. The front gets the rear's damping.
  - centre of mass (rigid body record: mass, then the centre of mass 0x38 later): lowered from z -0.375.
  - chassis roll (Havok vehicle data, "VRD " block): the roll torque factor (game 0.9: how much of the wheels'
    sideways force rolls the chassis) lowered and the roll unit inertia (game 0.8; the tanks use 2) raised.
Mass, grip, engine and steering stay the game's own.
Usage: make_frv.py VANILLA_DIR OUT_DIR   (VANILLA_DIR: the three .physics.main files as Filediver extracts them from
the game's own archives: frv, frv_supply, frv_flamer)"""
import struct, sys, os
PHYSICS = 0x5f7203c8f280dab8
FILES = [('frv.physics.main', 0xcc21c7ffd3ebefb9, 3000.0),          # content/fac_helldivers/vehicles/frv/frv
         ('frv_supply.physics.main', 0x9b2140378640432e, 2500.0),   # .../frv_supply/frv_supply
         ('frv_flamer.physics.main', 0x2d85bfe3d8717fe5, 7500.0)]   # .../frv_heavy/frv_flamer
FRONT_DAMPING = ((0.75, 4.0), (1.25, 6.5))       # game front (compression, rebound) -> the rear's
GAME = {'com_z': -0.375, 'roll_torque': 0.9, 'roll_inertia': 0.8}  # (roll torque at VRD +0x1C, roll inertia at VRD +0x34)
PRESETS = {                                       # folder: centre of mass z, roll torque factor, roll unit inertia
    'FRV Mild': {'com_z': -0.45, 'roll_torque': 0.7, 'roll_inertia': 1.1},
    'FRV Stable': {'com_z': -0.55, 'roll_torque': 0.5, 'roll_inertia': 1.6},
    'FRV Planted': {'com_z': -0.7, 'roll_torque': 0.3, 'roll_inertia': 2.2},
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
    # wheels: front ones (negative y) get the rear's damping
    v = d.find(b'VRW ')
    assert v > 0 and d.find(b'VRW ', v + 4) < 0
    n = struct.unpack_from('<I', d, v + 4)[0]
    assert n == 4, n
    fronts = 0
    for i in range(n):
        w = v + struct.unpack_from('<I', d, v + 8 + 4 * i)[0]
        if f32(d, w + 0x10) < 0:
            put(d, w + 0x58, FRONT_DAMPING[0][0], FRONT_DAMPING[1][0])
            put(d, w + 0x5C, FRONT_DAMPING[0][1], FRONT_DAMPING[1][1])
            fronts += 1
        else:
            assert abs(f32(d, w + 0x58) - 1.25) < 1e-4 and abs(f32(d, w + 0x5C) - 6.5) < 1e-4
    assert fronts == 2
    # rigid body: the vehicle's mass in the first body record, the centre of mass 0x38 after it
    at = [o for o in (0x120, 0x130) if abs(f32(d, o) - mass) < 1e-3]
    assert len(at) == 1, 'mass not found'
    put(d, at[0] + 0x40, GAME['com_z'], p['com_z'])
    # vehicle data
    r = d.find(b'VRD ')
    assert r > 0 and d.find(b'VRD ', r + 4) < 0
    put(d, r + 0x1C, GAME['roll_torque'], p['roll_torque'])
    put(d, r + 0x34, GAME['roll_inertia'], p['roll_inertia'])
    return bytes(d)

def write_patch(path, entries):
    # (the same layout as the tank suspension patches: 72-byte header, one type row, 80-byte entries)
    types = sorted({t for _, t, _ in entries})
    head = struct.pack('<III', 0xF0000011, len(types), len(entries)) + bytes.fromhex(HEADER)
    for t in types: head += struct.pack('<QQQII', 0, t, sum(e[1] == t for e in entries), 16, 64)
    cursor = len(head) + 80 * len(entries); rows = body = b''
    for i, (fid, tid, data) in enumerate(entries, 1):
        pad = -cursor % 16; body += b'\0' * pad; cursor += pad
        rows += struct.pack('<7Q6I', fid, tid, cursor, 0, 0, 0, 0, len(data), 0, 0, 16, 64, i)
        body += data; cursor += len(data)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, 'wb').write(head + rows + body)
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
