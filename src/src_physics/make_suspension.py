"""Armored Overhaul - Tank Suspension presets (reworked in 3.0.1). Writes patch archives holding the two tank hull
physics resources with each road wheel's suspension and the chassis' roll handling changed, so the tanks ride over
rough ground on their tracks instead of throwing themselves sideways when one side's wheels lose the ground.
Written from the game's own files; every value is checked against the game's number before it is changed.

What changes, read from each file itself:
  - road wheels (Havok raycast wheels, "VRW " block, ten 0x70-byte records, five a side): +0x54 spring strength,
    +0x58 compression damping, +0x5C rebound damping (game 12 / 0.5 / 3.7), and the suspension travel +0x34 (game
    0.325 m; found with in-game probes in the 3.0.1 tests: a metre more and the Maelstrom sat clearly higher).
    What the probes showed: the game's tanks sit on their bump stops - the springs (12) are too soft for
    the hull's weight, so every road wheel rests fully compressed and the tank rides as if it had no suspension (the
    "rigid" wheels). A spring holds the wheel off its stop by about SAG / strength metres of its travel (SAG = 9.84,
    fitted to the probes: the game's 12 would need 0.82 m, more than the 0.325 there is). So the presets set travel and
    spring together so each road wheel rests part-way down its travel and can move both ways, like a tank's torsion
    bars, and move each wheel's mount point (+0x0C..+0x14) up its suspension axis (+0x18..+0x20) by the length the
    wheel now rests extended, so the tank sits at its own height.
  - chassis (Havok vehicle data, "VRD " block, in Havok's hkpVehicleData order): +0x1C torque roll factor (game 1.0:
    the wheels' friction rolls the hull at full strength), +0x34 chassis unit inertia roll (game 2, half its yaw and
    pitch 4), +0x3C friction equalizer (game 0: when one track unloads, its share of the grip lands on the other track
    in one step).
Usage: make_suspension.py VANILLA_DIR OUT_DIR
  (VANILLA_DIR: the two hull physics resources as <resource id>.physics; OUT_DIR gets one folder per preset)"""
import struct, sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
import patch_writer
PHYSICS = 0x5f7203c8f280dab8
BASTION, MAELSTROM = 0x16474112801385b6, 0xb0c9faf4af8903f9      # TD-220 Bastion hull, TD-110 Maelstrom hull
GAME = {'spring': 12.0, 'comp': 0.5, 'rebound': 3.7, 'roll_torque': 1.0, 'roll_inertia': 2.0, 'equalizer': 0.0,
        'travel': 0.325}
SAG = 9.84            # metres of compression x spring strength under the hull's weight (fitted to the probes)
LIFT = 0.1            # metres the tanks sit above the game's own ride height (about 10% higher)
MOUNT_SIGN = 1.0      # the mount point moves up its suspension axis (probed: the other way sat the tank high)
PRESETS = {
    # each wheel rests half-way down 0.5 m of travel; damped to calm it within about a bounce; the chassis: half the
    # friction difference between the tracks evened out, about a third of the game's roll from the wheels' friction
    # (0.7 in the tests made the tanks easy to flip), half again the roll inertia
    'Suspension Balanced': {'spring': 40.0, 'comp': 2.5, 'rebound': 5.0, 'roll_torque': 0.35, 'roll_inertia': 3.0,
                            'equalizer': 0.5, 'travel': 0.5},
    # stiffer: a third of 0.45 m used at rest, more damping; the chassis: most of the difference evened out, a quarter
    # of the roll, roll inertia as high as its yaw and pitch
    'Suspension Planted': {'spring': 62.0, 'comp': 4.0, 'rebound': 7.5, 'roll_torque': 0.25, 'roll_inertia': 4.0,
                           'equalizer': 0.8, 'travel': 0.45},
}
# the patch header's engine metadata, as in the game's own packages (the same bytes as the 3.0.0 suspension patches)
HEADER = ('000000001cfa464200000000f52f5043a38b24bc0014ed000000000000f030010000000000000000000000000000000000000000'
          '0000000000000000')


def f32(d, o): return struct.unpack_from('<f', d, o)[0]


def put(d, o, old, new):
    assert abs(f32(d, o) - old) < 1e-4, (hex(o), f32(d, o), old)      # only ever the game's own number
    struct.pack_into('<f', d, o, new)


def wheels(d):
    v = d.find(b'VRW ')
    assert v > 0 and d.find(b'VRW ', v + 4) < 0, 'expected one wheel block'
    n = struct.unpack_from('<I', d, v + 4)[0]
    assert n == 10, n
    return [v + struct.unpack_from('<I', d, v + 8 + 4 * i)[0] for i in range(n)]


def lengthen(d, w, travel, shift):
    """One road wheel: suspension travel +0x34 to `travel`, and its mount point moved `shift` metres up the wheel's
    suspension axis (negative: down)."""
    put(d, w + 0x34, GAME['travel'], travel)
    x, y, z = struct.unpack_from('<3f', d, w + 0x0C)
    assert abs(abs(x) - 1.9) < 1e-4 and abs(z - 0.55) < 1e-4 and min(abs(y - v) for v in (3.2, 1.5, 0, -1.5, -3.2)) < 1e-4, (x, y, z)
    ax, ay, az = struct.unpack_from('<3f', d, w + 0x18)
    assert abs(ax) < 1e-4 and abs(az - 1) < 1e-4 and abs(ay) <= 0.35 + 1e-4, (ax, ay, az)   # the game's axes
    k = shift / (ax * ax + ay * ay + az * az) ** 0.5
    struct.pack_into('<3f', d, w + 0x0C, x + k * ax, y + k * ay, z + k * az)


def rest_extension(p):
    """How far each wheel rests extended from its stop: its travel less the spring's sag (the game's tanks: 0)."""
    return max(0.0, p['travel'] - SAG / p['spring'])


def mount_shift(p):
    """How far each wheel's mount point moves up its axis: by its rest extension (the game's ride height), less LIFT."""
    return max(0.0, rest_extension(p) - LIFT)


def retune(data, p):
    d = bytearray(data)
    for w in wheels(d):
        if p.get('travel', GAME['travel']) != GAME['travel']: lengthen(d, w, p['travel'], MOUNT_SIGN * mount_shift(p))
        put(d, w + 0x54, GAME['spring'], p['spring'])
        put(d, w + 0x58, GAME['comp'], p['comp'])
        put(d, w + 0x5C, GAME['rebound'], p['rebound'])
    r = d.find(b'VRD ')
    assert r > 0 and d.find(b'VRD ', r + 4) < 0, 'expected one vehicle data block'
    assert [round(f32(d, r + o), 4) for o in (0x1C, 0x20, 0x24, 0x30, 0x34, 0x38)] == [1, 1, 1, 4, 2, 4]  # the game's
    put(d, r + 0x1C, GAME['roll_torque'], p['roll_torque'])
    put(d, r + 0x34, GAME['roll_inertia'], p['roll_inertia'])
    put(d, r + 0x3C, GAME['equalizer'], p['equalizer'])
    return bytes(d)


def write_patch(path, entries):
    types = [(t, 64) for t in sorted({t for _, t, _ in entries})]
    toc, _, _ = patch_writer.write([(fid, tid, data, b'', b'', 64) for fid, tid, data in entries], types,
                                   header=bytes.fromhex(HEADER), first_index=1)
    patch_writer.check(toc)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, 'wb').write(toc)
    open(path + '.gpu_resources', 'wb').write(b''); open(path + '.stream', 'wb').write(b'')


if __name__ == '__main__':
    src, out = sys.argv[1], sys.argv[2]
    originals = [(fid, open(os.path.join(src, '%016x.physics' % fid), 'rb').read()) for fid in (BASTION, MAELSTROM)]
    for fid, data in originals:
        assert struct.unpack_from('<Q', data, 8)[0] == fid, hex(fid)       # (the file names its own resource id)
    for folder, p in PRESETS.items():
        write_patch(os.path.join(out, folder, '9ba626afa44a3aa3.patch_0'), [(fid, PHYSICS, retune(d, p)) for fid, d in originals])
        print(folder, p, 'rests %.3f m off its stops, rides %.2f m above the game' % (rest_extension(p), rest_extension(p) - mount_shift(p)) if 'travel' in p else '')
