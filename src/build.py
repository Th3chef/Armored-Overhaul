"""Armored Overhaul 3.0 - builds the Arsenal / HD2 Mod Manager zip from this folder.

  python tools/unpack_release.py Armored-Overhaul-3.0.1.zip     (once: the game-derived parts, see below)
  python build.py [--check Armored-Overhaul-3.0.1.zip]

- lua/<folder>.lua: each option folder's Lua addon, as shipped. Its first line names the addon
  ("-- HD2-Addon: mods/chef/armored_overhaul_..."); the patch archive's resource id is that name's hash.
- manifest.json, art/thumbnail.png and options/ (the option and sub-option icons) go into the zip as they are.
- The game-derived parts are not stored here: the Turret Models patch (the tank hulls and turrets, built from the game's
  own models with src_models/), the Tank Suspension and FRV Stability presets (the vehicles' own physics files, made by
  src_physics/) and the Turret Skull (a copy of the game's own Helldivers skull icon). tools/unpack_release.py takes
  them out of a release zip into models/, physics/<preset>/ and skull/.
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
               'Traverse Quick', 'Traverse Fast', 'Traverse Very Fast', 'Elevation Quick', 'Elevation Fast',
               'Elevation Very Fast', 'Aim Range Wide', 'Aim Range Wider', 'Aim Range Widest', 'Grip Moderate',
               'Grip Strong', 'Grip Maximum', 'Steering Responsive', 'Steering Quick', 'Steering Sharp', 'Power Strong',
               'Power Stronger', 'Power Strongest', 'Camera Close', 'Camera Far', 'Camera Farther', 'Camera Farthest',
               'Turret Indicator']
GAME_FOLDERS = [('Turret Skull', 'skull'), ('Turret Models', 'models'), ('Suspension Balanced', 'physics/Suspension Balanced'),
                ('Suspension Planted', 'physics/Suspension Planted'), ('FRV Mild', 'physics/FRV Mild'),
                ('FRV Stable', 'physics/FRV Stable'), ('FRV Planted', 'physics/FRV Planted')]
# icons in the zip, in Arsenal order (each option's icon, then its choices')
IMAGES = ['tank_power', 'sub/power_strong', 'sub/power_stronger', 'sub/power_strongest', 'tank_grip', 'sub/grip_moderate',
          'sub/grip_strong', 'sub/grip_maximum', 'tank_steering', 'sub/steering_responsive', 'sub/steering_quick',
          'sub/steering_sharp', 'tank_suspension', 'sub/suspension_firm', 'sub/suspension_heavy', 'mbt_turrets',
          'turret_traverse', 'sub/traverse_quick', 'sub/traverse_fast', 'sub/traverse_very_fast', 'turret_elevation',
          'sub/elevation_quick', 'sub/elevation_fast', 'sub/elevation_very_fast', 'turret_aim_range', 'sub/aim_range_wide',
          'sub/aim_range_wider', 'sub/aim_range_widest', 'autoloader', 'gunner_drive', 'sub/gunner_drive_tanks',
          'sub/gunner_drive_both', 'gunner_camera', 'sub/camera_close', 'sub/camera_far', 'sub/camera_farther',
          'sub/camera_farthest', 'frv_gunner_drive', 'frv_stability', 'sub/frv_mild', 'sub/frv_stable', 'sub/frv_planted',
          'turret_indicator']
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


def lua_patch(path):
    text = open(path, 'rb').read()
    first = text.split(b'\n', 1)[0]
    assert first.startswith(b'-- HD2-Addon: '), path + ': the first line must name the addon'
    rid = resource_hash(first[len(b'-- HD2-Addon: '):].strip().decode())
    data = struct.pack('<II', len(text), 2) + text            # length, then 2 = Lua source
    toc, gpu, stream = patch_writer.write([(rid, LUA_TYPE, data, b'', b'', 16)], [(LUA_TYPE, 16)])
    patch_writer.check(toc, gpu, stream)
    return toc, gpu, stream


def zput(z, name, data):
    zi = zipfile.ZipInfo(name, FIXED_TIME)
    zi.compress_type, zi.external_attr, zi.create_system = zipfile.ZIP_DEFLATED, 0o644 << 16, 3
    z.writestr(zi, data)


def main():
    manifest = open(os.path.join(HERE, 'manifest.json'), 'rb').read()
    name = json.loads(manifest)['Name']
    version = name.rsplit(' ', 1)[-1]
    for _, sub in GAME_FOLDERS:
        if not os.path.exists(os.path.join(HERE, sub, PATCH)):
            sys.exit('missing %s/%s: run tools/unpack_release.py on a release zip first' % (sub, PATCH))
    out_dir = os.path.join(HERE, 'build'); os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, 'Armored-Overhaul-%s.zip' % version)
    with zipfile.ZipFile(out + '.tmp', 'w') as z:
        zput(z, 'manifest.json', manifest)
        zput(z, 'thumbnail.png', open(os.path.join(HERE, 'art', 'thumbnail.png'), 'rb').read())
        for im in IMAGES:
            zput(z, 'options/%s.png' % im, open(os.path.join(HERE, 'options', im + '.png'), 'rb').read())
        for folder in LUA_FOLDERS:
            for ext, data in zip(('', '.gpu_resources', '.stream'), lua_patch(os.path.join(HERE, 'lua', folder + '.lua'))):
                zput(z, '%s/%s%s' % (folder, PATCH, ext), data)
        for folder, sub in GAME_FOLDERS:
            for ext in ('', '.gpu_resources', '.stream'):
                zput(z, '%s/%s%s' % (folder, PATCH, ext), open(os.path.join(HERE, sub, PATCH + ext), 'rb').read())
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
