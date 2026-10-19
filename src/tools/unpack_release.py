"""Unpacks the game-derived parts of an Armored Overhaul release zip into this folder, so build.py can rebuild it:
the Turret Models patch (models/), the Tank Suspension and FRV Stability presets and the Turret Hit Areas
(physics/<folder>/) and the Turret Skull (skull/). (3.7.0) The zip carries the turret models and hit areas as one patch
a tank (Turret Models Maelstrom / Bastion, Turret Hit Areas Maelstrom / Bastion); they are put back together here into
the two-tank patches build.py splits. Older release zips with the whole patches unpack as before.
  python tools/unpack_release.py Armored-Overhaul-<version>.zip"""
import os, sys, zipfile
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
# (3.1.1) the folder list is build.py's own (one list: a preset added there is unpacked here too)
from build import GAME_FOLDERS, PATCH, COMBINED, SPLIT, join_tanks

if len(sys.argv) != 2:
    sys.exit('usage: python tools/unpack_release.py Armored-Overhaul-<version>.zip')
WHERE = dict(GAME_FOLDERS)                                  # zip folder -> where build.py takes it from
EXTS = ('', '.gpu_resources', '.stream')
wanted = {(folder, PATCH + ext) for folder, _ in GAME_FOLDERS for ext in EXTS}
done = set()
with zipfile.ZipFile(sys.argv[1]) as z:
    # (3.7.0) the turret models and hit areas ship as one patch a tank (the Maelstrom only / Bastion only choices);
    # put back together into the two-tank patches build.py splits (releases before 3.7.0 have them whole: taken below)
    names = set(z.namelist())
    for folder in COMBINED:
        sub = WHERE[folder]
        parts = [f for f, (s, _) in SPLIT.items() if s == sub]
        if '%s/%s' % (folder, PATCH) in names or not all('%s/%s' % (f, PATCH) in names for f in parts):
            continue
        whole = join_tanks(sub, [tuple(z.read('%s/%s%s' % (f, PATCH, ext)) for ext in EXTS) for f in parts])
        os.makedirs(os.path.join(HERE, sub), exist_ok=True)
        for ext, data in zip(EXTS, whole):
            with open(os.path.join(HERE, sub, PATCH + ext), 'wb') as f:
                f.write(data)
            done.add((folder, PATCH + ext))
        print('unpacked %s (from %s)' % (folder, ', '.join(parts)))
    for name in z.namelist():
        folder, _, base = name.partition('/')
        if (folder, base) not in wanted:
            continue
        dest = os.path.join(HERE, WHERE[folder], base)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, 'wb') as f:
            f.write(z.read(name))
        done.add((folder, base))
        print('unpacked', name)
# (3.1.1) the wrong zip (the Package or source zip, or an older release) is said so, not taken silently
missing = sorted('%s/%s' % m for m in wanted - done)
if missing:
    sys.exit('%d of %d files not in %s (is it the release zip, Armored-Overhaul-<version>.zip?): %s'
             % (len(missing), len(wanted), os.path.basename(sys.argv[1]), ', '.join(missing[:3]) + (' ...' if len(missing) > 3 else '')))
print('all %d files unpacked: python build.py can run now' % len(wanted))
