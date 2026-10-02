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
        'travel': 0.325, 'com_z': -0.9}
# (3.1.0 Test 11) the rigid body's centre of mass (chassis space, z up: the wheel mounts sit at z 0.55): mass 30000 at
# 0x100, centre of mass (0, 0.5, -0.9) at 0x138. Riding LIFT higher lifts the centre of mass with the hull, so it is
# lowered by LIFT: it stays as high above the ground as the game has it (Test 10: a tank turning on the spot
# started to flip).
RIGID_MASS_AT, RIGID_COM_AT = 0x100, 0x138
COM_DROP = False      # (Test 17) back to 3.0.1: the centre of mass stays where the game has it
# (3.1.0 Test 39) In testing: "still need to look at tweaking center of gravity a bit", "flipping shouldnt be easy in a tank";
# a user on 3.0.1: tanks pushed around by dead bugs, bouncing, launched and flipped. Each preset now lowers the centre of
# mass by its own 'com_drop' (chosen per preset): Balanced 0.1 m (as high above the ground as the game has it, the 0.1 m
# lift taken back), Planted 0.25 m (harder to tip). Mass stays the game's 30000.
# (3.1.0 Test 12) Test 11 still rolled over turning on the spot (roll log: at 2-5 km/h and 30-57 deg/s the lean grows
# about a degree every tenth of a second until it goes past 35). The wheels' friction rolls the chassis (torque roll
# factor) Balanced 0.35 -> 0.1, Planted 0.25 -> 0.08, and the roll inertia Balanced 3 -> 5, Planted 4 -> 6 (the game:
# 1.0 and 2; yaw and pitch 4).
# (3.1.0 Test 16) SAG measured in game with the Test 15 ride probe (the hull's origin above a helldiver standing beside
# it): Tank Suspension off -0.230 m, Balanced (spring 66, travel 0.5) -0.162 m, both tanks alike. 66 x (0.5 - 0.068) =
# 28.5. The old 9.84 (fitted to the 3.0.1 probes) left 3.0.1's wheels on their stops with the mounts moved 0.15-0.19 m
# up: 3.0.1 rode lower than the game, as a user reported; Test 15's Balanced rode only 0.07 m above it.
SAG = 28.5            # metres of compression x spring strength under the hull's weight (measured, Test 15)
LIFT = 0.1            # metres the tanks sit above the game's own ride height (3.1.0 Tests 2-16 tried 0.35; Test 17: back to
                      # 3.0.1's 0.1 with the measured SAG)
MOUNT_SIGN = 1.0      # the mount point moves up its suspension axis (probed: the other way sat the tank high)
PRESETS = {
    # (3.1.0 Test 19) Test 18: "suspension is pretty bouncy and unstable currently, and it flips easily while rotating
    # 360". Tests 16-18's firm springs (114 / 190) held the wheels off their stops: real travel both ways, which bounced and
    # leaned. So the springs and damping are 3.0.1's again (40 / 2.5 / 5.0 and 62 / 4.0 / 7.5): with the measured SAG
    # (28.5) they can't hold the hull's weight (40 x 0.5 = 20, 62 x 0.45 = 27.9), so every wheel rests on its stop like the
    # game's and only drops into dips (no bounce, as 3.0.1 drove). What 3.0.1 got wrong was the mount points: it moved them
    # 0.15-0.19 m UP for a rest extension the springs never gave, so 3.0.1 rode that much below the game. Now each mount
    # moves LIFT down its axis (rest extension 0), so the tanks ride 0.1 m above the game.
    # Chassis: Test 12's roll fix (kept by choice in Test 18): roll from the wheels' friction 0.1 / 0.08 (3.0.1: 0.35
    # / 0.25), roll inertia 5 / 6 (3.0.1: 3 / 4); equalizer as 3.0.1. Centre of mass: the game's.
    # (Test 21) Test 19/20: "the tanks are super tippy, they can tip even when just turning a bit" and "with suspension
    # off, the tanks ride normally" (same grip, steering and power). With the wheels on their stops like the game's, what
    # is left different is mostly the chassis: roll from the wheels' friction cut to 0.1 (3.0.1 0.35, Test 17 tipped too),
    # more roll inertia, the friction equalizer. The game's centre of mass sits below the ground, so that friction leans
    # the tank into a turn; cutting it took that away. The chassis is the game's again (roll 1.0, inertia 2, equalizer 0);
    # only the wheels (travel, springs, damping, mounts 0.1 m lower) stay changed.
    # (Test 23) Test 21: "doesnt tip nearly as much, but the tank still operates pretty strangely when going over a
    # rock, its still kinda bouncy". The game's springs (12 x 0.325 m = 3.9) carry about a seventh of the hull's weight
    # (SAG 28.5): the tank rests on its stops and the wheels only follow the ground. 3.0.1's (40 x 0.5 = 20, 62 x 0.45 =
    # 27.9) carried 70-98% of it: over a rock the wheels on it hit their stops while the others' springs pushed the hull
    # back up, and it rocked. So the springs are near the game's again (Balanced the game's 12, Planted 16), the damping
    # is raised (rebound 3.7 -> 6 / 8 against the game's spring: about 1.6 / 1.9 times the game's share of critical), and
    # the longer travel (the wheels drop into dips) and the 0.1 m lift stay.
    'Suspension Balanced': {'spring': 12.0, 'comp': 1.0, 'rebound': 6.0, 'roll_torque': 1.0, 'roll_inertia': 2.0,
                            'equalizer': 0.0, 'travel': 0.5, 'com_drop': 0.1},
    'Suspension Planted': {'spring': 16.0, 'comp': 1.5, 'rebound': 8.0, 'roll_torque': 1.0, 'roll_inertia': 2.0,
                           'equalizer': 0.0, 'travel': 0.45, 'com_drop': 0.25},
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
    """How far each wheel's mount point moves up its axis: by its rest extension (the game's ride height), less LIFT.
    3.1.0: negative when LIFT is more than the rest extension: the mount moves down its axis (probe 4, Test 8: a mount
    0.5 m down sat the Maelstrom high), so the tank rides LIFT above the game with the same springs and travel."""
    return rest_extension(p) - LIFT


def retune(data, p):
    d = bytearray(data)
    for w in wheels(d):
        if p.get('travel', GAME['travel']) != GAME['travel']: lengthen(d, w, p['travel'], MOUNT_SIGN * mount_shift(p))
        put(d, w + 0x54, GAME['spring'], p['spring'])
        put(d, w + 0x58, GAME['comp'], p['comp'])
        put(d, w + 0x5C, GAME['rebound'], p['rebound'])
    assert abs(f32(d, RIGID_MASS_AT) - 30000) < 1e-3 and abs(f32(d, RIGID_COM_AT) - 0) < 1e-6 and abs(f32(d, RIGID_COM_AT + 4) - 0.5) < 1e-6
    if COM_DROP: put(d, RIGID_COM_AT + 8, GAME['com_z'], GAME['com_z'] - LIFT)
    elif p.get('com_drop'): put(d, RIGID_COM_AT + 8, GAME['com_z'], GAME['com_z'] - p['com_drop'])
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
        print(folder, p, 'rests %.3f m off its stops, rides %.2f m above the game, centre of mass z %.2f' % (rest_extension(p), rest_extension(p) - mount_shift(p), GAME['com_z'] - p.get('com_drop', 0)) if 'travel' in p else '')
