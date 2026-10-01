"""Unpacks the game-derived parts of an Armored Overhaul release zip into this folder, so build.py can rebuild it:
the Turret Models patch (models/) and the Tank suspension and FRV stability presets (physics/<preset>/).
  python tools/unpack_release.py Armored-Overhaul-<version>.zip"""
import os, sys, zipfile
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRESETS = ('Suspension Firm', 'Suspension Heavy', 'FRV Mild', 'FRV Stable', 'FRV Planted')
with zipfile.ZipFile(sys.argv[1]) as z:
    for name in z.namelist():
        folder, _, base = name.partition('/')
        if not base.startswith('9ba626afa44a3aa3.patch_0'):
            continue
        if folder == 'Turret Models':
            dest = os.path.join(HERE, 'models', base)
        elif folder in PRESETS:
            dest = os.path.join(HERE, 'physics', folder, base)
        else:
            continue
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, 'wb') as f:
            f.write(z.read(name))
        print('unpacked', name)
