"""Armored Overhaul - builds the Arsenal / HD2 Mod Manager zip from this folder.

  python tools/unpack_release.py Armored-Overhaul-<version>.zip     (once: the game-derived parts, see below)
  python build.py [--check Armored-Overhaul-<version>.zip]

- lua/<folder>.lua: each option folder's Lua addon, as shipped (DERIVED folders are made from another folder's file). Its first line names the addon
  ("-- HD2-Addon: mods/chef/armored_overhaul_..."); the patch archive's resource id is that name's hash.
- manifest.json, art/thumbnail.png and options/ (the option and sub-option icons) go into the zip as they are.
- The game-derived parts are not stored here: the Turret Models patch (the two tank hulls, built from the game's own
  hull models with src_models/build_mbt_hull.py; (3.7.0) the zip carries it, and the Turret Hit Areas, as one patch a
  tank, so a choice can leave one tank to another mod's model), the Tank Suspension and FRV Stability presets (the vehicles' own physics files, made by
  src_physics/: make_suspension.py also writes 'Turret Hit Areas', the two hulls' physics with the turret's hit areas on
  the turret, which Tank MBT Turrets includes) and the Turret Skull (a copy of the game's own Helldivers skull icon).
  tools/unpack_release.py takes them out of a release zip into models/, physics/<folder>/ and skull/.
- --check: compares the zip it made with a release zip, file by file and byte for byte (the order of the files in
  the zip may differ).
Writes build/Armored-Overhaul-<version>.zip (the version from the manifest's Name)."""
import json, os, struct, sys, zipfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, 'tools'))
import patch_writer

LUA_TYPE = 0xA14E8DFA2CD117E2          # the game's lua resource type
PATCH = '9ba626afa44a3aa3.patch_0'
# zip order: the addon folders, then the game-derived ones (folder -> where unpack_release.py puts it)
LUA_FOLDERS = ['Tank Core', 'Gunner Drive', 'Driver Panel', 'Autoloader', 'FRV Gunner Drive', 'Turret Core', 'MBT Turrets',
               'MBT Turrets 180', 'Model Mods 360', 'Model Mods 360 Maelstrom', 'Model Mods 360 Bastion',
               'Traverse Quick', 'Traverse Fast', 'Traverse Very Fast', 'Elevation Quick', 'Elevation Fast',
               'Elevation Very Fast', 'Depression Low', 'Depression Lower', 'Depression Lowest', 'Raise High', 'Raise Higher',
               'Raise Highest', 'Top Speed Fast', 'Top Speed Faster',
               'Top Speed Fastest', 'Grip Moderate',
               'Grip Strong', 'Grip Maximum', 'Steering Responsive', 'Steering Quick', 'Steering Sharp', 'Power Strong',
               'Power Stronger', 'Power Strongest', 'Throttle Quick', 'Throttle Quicker', 'Throttle Instant', 'Shift Quick',
               'Shift Quicker', 'Shift Instant', 'Stability Stable',
               'Stability Steady', 'Stability Planted', 'Collision Damage', 'Camera Close', 'Camera Far', 'Camera Farther', 'Camera Farthest',
               'Turret Indicator', 'Run Flat', 'Maelstrom Weapons',
               'Fire Rate', 'Fire Rate Display', 'Single Belt', 'Vehicle Loadout']
# (3.1.0 Test 26) folders made from another folder's Lua: the MBT Turrets 180 choice is the MBT Turrets addon with one line
# more (its flag asks the turret core for 90 degrees each side), so the two can't drift apart
DERIVED = {'MBT Turrets 180': ('MBT Turrets', b'o.mbt = true\n',
                               b'o.mbt = true\no.mbt_arc = 90                    -- (3.1.0 Test 26) the 180 choice: 90 degrees each side\n')}
# (3.7.0) Tank MBT Turrets for Remodels, its own option: the MBT Turrets addon under its own name (so the log can say when
# both options are on), marked as this option's copy; the remodel choices turn both tanks (no turret model for the tank
# another mod remodels), the untouched choices leave that tank to the game or the other mod (o.mbt_off).
ARC_LINE = b'o.mbt_arc = 90                    -- (3.1.0 Test 26) the 180 choice: 90 degrees each side\n'
MM_EDITS = [(b'-- HD2-Addon: mods/chef/armored_overhaul_turret_360\n', b'-- HD2-Addon: mods/chef/armored_overhaul_turret_model_mods\n'),
            (b'o.mbt_from.turrets = true ', b'o.mbt_from.model_mods = true')]
for arc in ('360',):              # (3.7.0 Test 9: "no need to add 180 versions ... leave the 180 for the MBT turrets")
    arc_edit = [(b'o.mbt = true\n', b'o.mbt = true\n' + ARC_LINE)] if arc == '180' else []
    DERIVED['Model Mods ' + arc] = ('MBT Turrets', MM_EDITS + arc_edit)
    for tank, other in (('Maelstrom', b'bastion'), ('Bastion', b'maelstrom')):
        off = b'o.mbt_off = {' + other + b' = true}'
        off += b' ' * (34 - len(off)) + b'-- (3.7.0) the ' + tank.encode() + b' only choice\n'
        DERIVED['Model Mods %s %s' % (arc, tank)] = ('MBT Turrets', MM_EDITS + [(b'o.mbt = true\n', b'o.mbt = true\n' + (ARC_LINE if arc == '180' else b'') + off)])
GAME_FOLDERS = [('Turret Skull', 'skull'), ('Turret Models', 'models'), ('Turret Hit Areas', 'physics/Turret Hit Areas'),
                ('Suspension Balanced', 'physics/Suspension Balanced'),
                ('Suspension Planted', 'physics/Suspension Planted'), ('FRV Mild', 'physics/FRV Mild'),
                ('FRV Stable', 'physics/FRV Stable'), ('FRV Planted', 'physics/FRV Planted')]
# (3.7.0) folders with one tank's part of a game-derived patch: the Maelstrom only / Bastion only choices, so the other
# tank's model and hit areas stay the game's (or another mod's). folder -> (the patch's folder, the hull unit's id)
BASTION_HULL, MAELSTROM_HULL = 0x16474112801385B6, 0xB0C9FAF4AF8903F9
COMBINED = ('Turret Models', 'Turret Hit Areas')         # stored here as two-tank patches, shipped split
SPLIT = {'Turret Models Maelstrom': ('models', MAELSTROM_HULL), 'Turret Models Bastion': ('models', BASTION_HULL),
         'Turret Hit Areas Maelstrom': ('physics/Turret Hit Areas', MAELSTROM_HULL),
         'Turret Hit Areas Bastion': ('physics/Turret Hit Areas', BASTION_HULL)}
# icons in the zip, in Arsenal order (each option's icon, then its choices')
IMAGES = ['tank_speed', 'sub/speed_fast', 'sub/speed_faster', 'sub/speed_fastest', 'tank_power', 'sub/power_strong', 'sub/power_stronger', 'sub/power_strongest', 'tank_grip', 'sub/grip_moderate',
          'sub/grip_strong', 'sub/grip_maximum', 'tank_steering', 'sub/steering_responsive', 'sub/steering_quick',
          'sub/steering_sharp', 'tank_throttle', 'sub/throttle_quick', 'sub/throttle_quicker', 'sub/throttle_instant',
          'tank_stability', 'sub/stability_stable', 'sub/stability_steady', 'sub/stability_planted', 'tank_collision_damage', 'maelstrom_fire_rate',
          'maelstrom_belt', 'mbt_turrets', 'sub/mbt_360',
          'sub/mbt_180', 'mbt_model_mods', 'sub/mm_off', 'sub/mm_360_bastion_remodel', 'sub/mm_360_bastion_untouched',
          'sub/mm_360_maelstrom_remodel', 'sub/mm_360_maelstrom_untouched', 'tank_suspension', 'sub/suspension_firm', 'sub/suspension_heavy',
          'turret_traverse', 'sub/traverse_quick', 'sub/traverse_fast', 'sub/traverse_very_fast', 'turret_elevation',
          'sub/elevation_quick', 'sub/elevation_fast', 'sub/elevation_very_fast', 'gun_depression', 'sub/depression_low',
          'sub/depression_lower', 'sub/depression_lowest', 'gun_raise', 'sub/raise_high', 'sub/raise_higher', 'sub/raise_highest',
          'autoloader', 'gunner_drive', 'sub/gunner_drive_tanks',
          'sub/gunner_drive_both', 'driver_panel', 'gunner_camera', 'sub/camera_close', 'sub/camera_far', 'sub/camera_farther',
          'sub/camera_farthest', 'frv_gunner_drive', 'frv_stability', 'sub/frv_mild', 'sub/frv_stable', 'sub/frv_planted', 'frv_run_flat',
          'turret_indicator', 'vehicle_loadout']
FIXED_TIME = (2026, 1, 1, 0, 0, 0)


def resource_hash(name):
    """The game's 64-bit resource name hash (MurmurHash64A, seed 0)."""
    data = name.encode(); mask, mix = (1 << 64) - 1, 0xC6A4A7935BD1E995
    v = len(data) * mix & mask; end = len(data) // 8 * 8
    for (w,) in struct.iter_unpack('<Q', data[:end]):
        w = w * mix & mask; w ^= w >> 47; v = (v ^ (w * mix & mask)) * mix & mask
    if data[end:]: v = (v ^ int.from_bytes(data[end:], 'little')) * mix & mask
    v ^= v >> 47; v = v * mix & mask; v ^= v >> 47
    return v


def read_text(path):
    """A text file as the release has it: LF line ends. (3.1.1) Git for Windows checks text files out with CRLF by
    default; the release's files are LF, so they are read back to LF and the build stays byte for byte."""
    return open(path, 'rb').read().replace(b'\r\n', b'\n')


def lua_text(folder):
    if folder in DERIVED:
        src, edits = DERIVED[folder][0], DERIVED[folder][1:]
        if len(edits) == 2: edits = [edits]                  # (one change: (src, old, new); several: (src, [(old, new), ...]))
        else: edits = edits[0]
        text = read_text(os.path.join(HERE, 'lua', src + '.lua'))
        for old, new in edits:
            assert text.count(old) == 1, folder + ': the line to change is not in ' + src
            text = text.replace(old, new)
        return text
    return read_text(os.path.join(HERE, 'lua', folder + '.lua'))


def lua_patch(text):
    first = text.split(b'\n', 1)[0]
    assert first.startswith(b'-- HD2-Addon: '), 'the first line must name the addon'
    rid = resource_hash(first[len(b'-- HD2-Addon: '):].strip().decode())
    data = struct.pack('<II', len(text), 2) + text            # length, then 2 = Lua source
    toc, gpu, stream = patch_writer.write([(rid, LUA_TYPE, data, b'', b'', 16)], [(LUA_TYPE, 16)])
    patch_writer.check(toc, gpu, stream)
    return toc, gpu, stream


def read_patch(toc, gpu, stream):
    """A patch's entries (id, type, data, gpu, stream, alignment), type rows and header bytes."""
    _, nt, n = struct.unpack_from('<III', toc, 0)
    types = [struct.unpack_from('<QQQII', toc, 72 + 32 * k) for k in range(nt)]
    entries = []
    for k in range(n):
        eid, tid, off, soff, goff, _, _, size, ssize, gsize, _, align, _ = struct.unpack_from('<7Q6I', toc, 72 + 32 * nt + 80 * k)
        entries.append((eid, tid, toc[off:off + size], gpu[goff:goff + gsize], stream[soff:soff + ssize], align))
    return entries, [(tid, align) for _, tid, _, _, align in types], toc[12:72]


def tank_patch(sub, entries, types, header):
    """(3.7.0) a model / hit-area patch written the way the two-tank one is (the game package's header bytes, entries
    counted from 1, the model patch's TOC padded as HD2SDK writes it)."""
    tids = {e[1] for e in entries}
    out = patch_writer.write(entries, [r for r in types if r[0] in tids], header=header, first_index=1, pad_toc=sub == 'models')
    patch_writer.check(*out)
    return out


def one_tank(sub, rid):
    """(3.7.0) the two-tank patch in sub/ with only the entry rid (its data, gpu and stream data as they are). Checked:
    the two-tank patch reads back byte for byte, so join_tanks() gives it back from the two one-tank patches."""
    whole = tuple(open(os.path.join(HERE, sub, PATCH + ext), 'rb').read() for ext in ('', '.gpu_resources', '.stream'))
    entries, types, header = read_patch(*whole)
    assert tank_patch(sub, entries, types, header) == whole, sub + ': the patch does not read back as it is'
    mine = [e for e in entries if e[0] == rid]
    assert len(mine) == 1, '%s: %016x is not in the patch' % (sub, rid)
    return tank_patch(sub, mine, types, header)


def join_tanks(sub, parts):
    """(3.7.0, for tools/unpack_release.py) the two-tank patch of sub/ from its one-tank patches (each (toc, gpu, stream)),
    the Bastion first as the game-derived patch has it."""
    got = [read_patch(*p) for p in parts]
    assert len({g[2] for g in got}) == 1, sub + ': the one-tank patches have different headers'
    entries = sorted((e for g in got for e in g[0]), key=lambda e: [BASTION_HULL, MAELSTROM_HULL].index(e[0]))
    types = got[0][1]
    for g in got[1:]: types += [r for r in g[1] if r not in types]
    return tank_patch(sub, entries, types, got[0][2])


def zput(z, name, data):
    zi = zipfile.ZipInfo(name, FIXED_TIME)
    zi.compress_type, zi.external_attr, zi.create_system = zipfile.ZIP_DEFLATED, 0o644 << 16, 3
    z.writestr(zi, data)


def main():
    manifest = read_text(os.path.join(HERE, 'manifest.json'))
    name = json.loads(manifest)['Name']
    version = name.rsplit(' ', 1)[-1]
    if '--check' in sys.argv and sys.argv.index('--check') + 1 >= len(sys.argv):
        sys.exit('usage: python build.py [--check Armored-Overhaul-<version>.zip]')
    for _, sub in GAME_FOLDERS:
        for ext in ('', '.gpu_resources', '.stream'):          # (3.1.1: all three files, not just the first)
            if not os.path.exists(os.path.join(HERE, sub, PATCH + ext)):
                sys.exit('missing %s/%s%s: run tools/unpack_release.py on the release zip (Armored-Overhaul-<version>.zip) first' % (sub, PATCH, ext))
    out_dir = os.path.join(HERE, 'build'); os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, 'Armored-Overhaul-%s.zip' % version)
    with zipfile.ZipFile(out + '.tmp', 'w') as z:
        zput(z, 'manifest.json', manifest)
        zput(z, 'thumbnail.png', open(os.path.join(HERE, 'art', 'thumbnail.png'), 'rb').read())
        for im in IMAGES:
            zput(z, 'options/%s.png' % im, open(os.path.join(HERE, 'options', im + '.png'), 'rb').read())
        for folder in LUA_FOLDERS:
            for ext, data in zip(('', '.gpu_resources', '.stream'), lua_patch(lua_text(folder))):
                zput(z, '%s/%s%s' % (folder, PATCH, ext), data)
        for folder, sub in GAME_FOLDERS:
            if folder in COMBINED: continue                 # (3.7.0) shipped as one patch a tank (SPLIT below)
            for ext in ('', '.gpu_resources', '.stream'):
                zput(z, '%s/%s%s' % (folder, PATCH, ext), open(os.path.join(HERE, sub, PATCH + ext), 'rb').read())
        for folder, (sub, rid) in SPLIT.items():
            for ext, data in zip(('', '.gpu_resources', '.stream'), one_tank(sub, rid)):
                zput(z, '%s/%s%s' % (folder, PATCH, ext), data)
    os.replace(out + '.tmp', out)
    print('wrote', os.path.relpath(out, HERE), name)
    if '--check' in sys.argv:
        ref = sys.argv[sys.argv.index('--check') + 1]
        a, b = zipfile.ZipFile(out), zipfile.ZipFile(ref)
        assert sorted(a.namelist()) == sorted(b.namelist()), 'the file list differs from ' + ref
        diff = [n for n in a.namelist() if a.read(n) != b.read(n)]
        print('check against %s: %d files, %s' % (os.path.basename(ref), len(a.namelist()),
              'every file the same byte for byte' if not diff else 'different: ' + ', '.join(diff)))
        if diff: sys.exit(1)


if __name__ == '__main__':
    main()
