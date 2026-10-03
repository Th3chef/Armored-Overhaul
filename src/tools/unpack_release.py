"""Unpacks the game-derived parts of an Armored Overhaul release zip into this folder, so build.py can rebuild it:
the Turret Models patch (models/), the Tank Suspension and FRV Stability presets (physics/<preset>/) and the Turret
Skull (skull/).
  python tools/unpack_release.py Armored-Overhaul-<version>.zip"""
import os, sys, zipfile
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
# (3.1.1) the folder list is build.py's own (one list: a preset added there is unpacked here too)
from build import GAME_FOLDERS, PATCH

if len(sys.argv) != 2:
    sys.exit('usage: python tools/unpack_release.py Armored-Overhaul-<version>.zip')
WHERE = dict(GAME_FOLDERS)                                  # zip folder -> where build.py takes it from
wanted = {(folder, PATCH + ext) for folder, _ in GAME_FOLDERS for ext in ('', '.gpu_resources', '.stream')}
done = set()
with zipfile.ZipFile(sys.argv[1]) as z:
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
