"""Armored Overhaul (written from scratch) -> Arsenal zip.
  python build.py            test build (diagnostic counters on, test GUID)
  python build.py release    release zip (permanent GUID) plus its personal Tester zip (the release with Gunner
                             Drive's tester logging on, on the test GUID)
"""
import math, json, os, struct, sys, zipfile

VERSION, NAME_SUFFIX = '2.0.1', ' Test 2'   # NAME_SUFFIX is only used by test builds
HERE = os.path.dirname(os.path.abspath(__file__))
GUID_LIVE = '370555ae-cb28-4b9d-96d0-8381505c3f89'   # releases: Arsenal treats a new release as an update
GUID_TEST = '8d3e5a71-2c94-4f06-b1e8-6a7c0d9f4e25'   # test and Tester builds: sit next to the release
MAGIC, LUA = 0xF0000011, 0xa14e8dfa2cd117e2
TEXTURE = 0xcd4238c6a0c69e32
# (2.0) the Turret indicator's skull: a copy of the game's own round-eyed Helldivers skull (the main menu header icon,
# content/ui/shared/menu/main/header_icon, 64 px white with alpha; art/skull_header_icon.png). The game only loads that
# texture in the menu, so the indicator ships it as its own texture, loaded with the addon.
SKULL_TEX = 'mods/chef/armored_overhaul_skull'
CORE, TURRETS = 'mods/chef/armored_overhaul_gunner_drive', 'mods/chef/armored_overhaul_mbt_turrets'
HANDLING = 'mods/chef/armored_overhaul_handling'
STEERING = 'mods/chef/armored_overhaul_steering'
POWER = 'mods/chef/armored_overhaul_power'
DRIVE_FLAG = 'mods/chef/armored_overhaul_gunner_drive_on'
INDICATOR = 'mods/chef/armored_overhaul_indicator'
PANEL = 'mods/chef/armored_overhaul_driver_panel'      # the driver panel (part of Gunner Drive since 1.2.2)
CAMERA = 'mods/chef/armored_overhaul_gunner_camera'
# Tank grip and Tank steering strengths: one Arsenal sub-option each (folder, name, multiplier, description).
# Every strength ships the same addon name, so switching strength replaces it. The middle one (x1.5) was tested in 1.0.
GRIP_PRESETS = [
    ('Grip Moderate', 'Moderate', 1.25, 'A quarter more grip than the game\'s own.'),
    ('Grip Strong', 'Strong', 1.5, 'Half again the game\'s grip (the 1.0 default).'),
    ('Grip Maximum', 'Maximum', 2, 'Twice the game\'s grip: the tanks stick to the ground.'),
]
# Gunner camera: metres moved back (and up, at a shallow angle) from the game's own place
CAMERA_PRESETS = [
    # (1.2.2: every preset half a metre lower and further back, rising at 10 degrees; the names and folders are kept so
    # the mod manager keeps your pick)
    ('Camera Close', 'Close', -0.5, 'The game\'s distance, but lower: 1.4 m above the turret (the game\'s is 2 m).'),
    ('Camera Far', 'Far', 2, '1.9 m above the turret.'),
    ('Camera Farther', 'Farther', 4, '2.2 m above the turret.'),
    ('Camera Farthest', 'Farthest', 6, '2.5 m above the turret: the most of the tank and its surroundings in view.'),
]
# Tank power (1.3): the engine's torque scale (pulling power); top speed stays the game's own
POWER_PRESETS = [
    ('Power Strong', 'Strong', 1.25, 'A quarter more pulling power than the game\'s own.'),
    ('Power Stronger', 'Stronger', 1.5, 'Half again the game\'s pulling power: quicker off the line and up slopes.'),
    ('Power Strongest', 'Strongest', 2, 'Twice the game\'s pulling power.'),
]
# Turret options (2.0): each ships the turret core (folder 'Turret Core') plus a flag addon with what it wants
TURRET_FLAGS = {   # flag addon resource name per option
    'mbt': 'mods/chef/armored_overhaul_turret_360', 'traverse': 'mods/chef/armored_overhaul_turret_traverse',
    'elevation': 'mods/chef/armored_overhaul_turret_elevation', 'range': 'mods/chef/armored_overhaul_turret_range'}
TRAVERSE_PRESETS = [
    ('Traverse Quick', 'Quick', 1.25, 'Turns side to side a quarter faster than the game\'s (about 31 degrees a second).'),
    ('Traverse Fast', 'Fast', 1.5, 'Half again as fast as the game\'s (37.5 degrees a second).'),
    ('Traverse Very Fast', 'Very fast', 2, 'Twice as fast as the game\'s (50 degrees a second).'),
]
ELEVATION_PRESETS = [
    ('Elevation Quick', 'Quick', 1.25, 'Moves up and down a quarter faster than the game\'s (about 44 degrees a second).'),
    ('Elevation Fast', 'Fast', 1.5, 'Half again as fast as the game\'s (52.5 degrees a second).'),
    ('Elevation Very Fast', 'Very fast', 2, 'Twice as fast as the game\'s (70 degrees a second).'),
]
RANGE_PRESETS = [   # (folder, name, (lowest, highest) degrees, description)
    ('Aim Range Wider', 'Wider', (-10, 35), 'Aims from 10 degrees below level to 35 above (the game: 3 below to 25 above).'),
    ('Aim Range Widest', 'Widest', (-15, 45), 'Aims from 15 degrees below level to 45 above.'),
]
def turret_flag(key, value):
    lua_value = ('{%g, %g}' % value) if isinstance(value, tuple) else ('true' if value is True else repr(float(value)))
    return ('-- HD2-Addon: %s\n-- Armored Overhaul: turret option flag (read by the turret core, mods/chef/armored_overhaul_mbt_turrets)\n'
            'local o = rawget(_G, \'ArmoredOverhaulTurretOptions\')\nif type(o) ~= \'table\' then o = {}; rawset(_G, \'ArmoredOverhaulTurretOptions\', o) end\n'
            'o.%s = %s\n' % (TURRET_FLAGS[key], key, lua_value))
# (2.0) the options in the mod manager, grouped: the tanks' handling, the turret, the gunner seat, then the FRV
OPTION_ORDER = ['Tank power', 'Tank grip', 'Tank steering', 'Tank suspension',
                'MBT Turrets', 'Turret traverse', 'Turret elevation', 'Turret aim range', 'Turret indicator',
                'Gunner Drive', 'Gunner camera',
                'FRV stability']
STEERING_PRESETS = [
    ('Steering Responsive', 'Responsive', 1.25, 'A quarter quicker than the game\'s own.'),
    ('Steering Quick', 'Quick', 1.5, 'Half again as quick as the game\'s.'),
    ('Steering Sharp', 'Sharp', 2, 'Twice as quick as the game\'s: the tanks snap into turns.'),
]
FLAG_SRC = ('-- HD2-Addon: %s\n-- Armored Overhaul: the Gunner Drive option. Tells Tank Core to let you drive from the gunner seat.\n'
            "rawset(_G, 'ArmoredOverhaulGunnerDriveOn', true)\n" % DRIVE_FLAG)


def resource_hash(name):
    data = name.encode(); mask, mix = (1 << 64) - 1, 0xC6A4A7935BD1E995
    v = len(data) * mix & mask; end = len(data) // 8 * 8
    for (w,) in struct.iter_unpack('<Q', data[:end]):
        w = w * mix & mask; w ^= w >> 47; v = (v ^ (w * mix & mask)) * mix & mask
    if data[end:]: v = (v ^ int.from_bytes(data[end:], 'little')) * mix & mask
    v ^= v >> 47; v = v * mix & mask; v ^= v >> 47
    return v


def archive(entries):
    n = len(entries); cursor = 72 + 32 + 80 * n; rows = body = b''
    for i, (rid, data) in enumerate(entries):
        pad = -cursor % 16; body += b'\0' * pad; cursor += pad
        rows += struct.pack('<7Q6I', rid, LUA, cursor, 0, 0, 0, 0, len(data), 0, 0, 16, 16, i)
        body += data; cursor += len(data)
    head = struct.pack('<III', MAGIC, 1, n) + b'\0' * 20 + struct.pack('<I', cursor) + b'\0' * 36
    return head + struct.pack('<QQQII', 0, LUA, n, 16, 16) + rows + body


def texture_rgba(png):
    """A plain R8G8B8A8 texture (DXGI 28, one mip): the 340-byte Stingray + DDS header, and the pixels (gpu data)."""
    from PIL import Image
    src = Image.open(png)
    assert src.mode == 'RGBA' and src.size == (64, 64), 'skull art must be 64x64 with transparency: %s %s' % (src.mode, src.size)
    im = src; w, h = im.size
    st = struct.pack('<III', 0, 0, 0xFFFFFFFF) + b'\0' * (15 * 12)
    pf = struct.pack('<II4sIIIII', 32, 0x4, b'DX10', 0, 0, 0, 0, 0)
    hdr = struct.pack('<IIIIIII', 124, 0x100F, h, w, w * 4, 0, 1) + b'\0' * 44 + pf + struct.pack('<IIIII', 0x1000, 0, 0, 0, 0)
    header = st + b'DDS ' + hdr + struct.pack('<IIIII', 28, 3, 0, 1, 0)
    assert len(header) == 340
    return header, im.tobytes()


def mixed_archive(lua_entries, tex_entries):
    """A patch with Lua resources and textures: returns (toc, gpu_resources). Textures first, as the game's own."""
    ents = [(rid, TEXTURE, data, gpu) for rid, (data, gpu) in tex_entries] + [(rid, LUA, data, b'') for rid, data in lua_entries]
    types = [t for t in (TEXTURE, LUA) if any(e[1] == t for e in ents)]
    n = len(ents); cursor = 72 + 32 * len(types) + 80 * n; rows = body = b''; gpu = bytearray()
    for i, (rid, tid, data, g) in enumerate(ents):
        pad = -cursor % 16; body += b'\0' * pad; cursor += pad
        goff = 0
        if g:
            gpu += b'\0' * (-len(gpu) % 64); goff = len(gpu); gpu += g
        align = 64 if tid == TEXTURE else 16
        rows += struct.pack('<7Q6I', rid, tid, cursor, 0, goff, 0, 0, len(data), 0, len(g), 16, align, i)
        body += data; cursor += len(data)
    head = struct.pack('<III', MAGIC, len(types), n) + b'\0' * 20 + struct.pack('<I', cursor) + b'\0' * 36
    for t in types: head += struct.pack('<QQQII', 0, t, sum(e[1] == t for e in ents), 16, 64 if t == TEXTURE else 16)
    return head + rows + body, bytes(gpu)


def check_texture_patch(toc, gpu, rid, w, h):
    """Read a texture-only patch back: one texture entry with this id, a 340-byte header naming w x h DXGI 28, and
    w x h x 4 bytes of gpu data at offset 0."""
    magic, nt, n = struct.unpack_from('<III', toc, 0)
    assert magic == MAGIC and nt == 1 and n == 1, (hex(magic), nt, n)
    _, tid, cnt, _, _ = struct.unpack_from('<QQQII', toc, 72)
    assert tid == TEXTURE and cnt == 1
    fid, tid, off, soff, goff, _, _, size, ssize, gsize, _, _, _ = struct.unpack_from('<7Q6I', toc, 104)
    assert fid == rid and tid == TEXTURE and size == 340 and goff == 0 and gsize == w * h * 4 == len(gpu), (hex(fid), size, gsize)
    hdr = toc[off:off + size]
    assert hdr[192:196] == b'DDS ' and struct.unpack_from('<II', hdr, 204) == (h, w) and struct.unpack_from('<I', hdr, 320)[0] == 28


def resource(src):
    b = src.encode('utf-8')
    return struct.pack('<II', len(b), 2) + b


def core_source(version, tester):
    src = open(os.path.join(HERE, 'gunner_drive.lua.in'), encoding='utf-8').read()
    pats = json.load(open(os.path.join(HERE, 'pats2.json')))
    pats.update(json.load(open(os.path.join(HERE, 'pats12.json'))))   # 1.2: engine switch, instruments, selector
    pats.update(json.load(open(os.path.join(HERE, 'pats13.json'))))   # 1.3: the tank's health
    subs = {'@@VERSION@@': version, '@@TESTER@@': 'true' if tester else 'false'}
    for key, (pattern, (count, a, b)) in pats.items():
        assert count == 1, key
        k = key.upper()
        subs['@@%s@@' % k], subs['@@%s_AO@@' % k], subs['@@%s_AL@@' % k] = pattern, str(a), str(b - a)
    for k, v in subs.items():
        src = src.replace(k, v)
    assert '@@' not in src, 'unfilled placeholder'
    return src


def part_source(src, part):
    """Keeps the --@@IF <part> ... --@@END blocks of indicator.lua.in that belong to `part` ('outline' or 'panel')."""
    out, keep, inside = [], True, False
    for line in src.split('\n'):
        t = line.strip()
        if t.startswith('--@@IF '):
            assert not inside, 'nested --@@IF'; inside, keep = True, t[7:].strip() == part; continue
        if t == '--@@END':
            assert inside, 'stray --@@END'; inside, keep = False, True; continue
        if keep: out.append(line)
    assert not inside, 'unclosed --@@IF'
    return '\n'.join(out)


def suboptions(presets, unit='x', extra=()):
    def label(name, v):
        # (1.2.2) the camera's real distance behind the turret: half a metre further back than the game's 1 m, then the
        # preset's metres along the camera's 10 degree rise (1.2.0-1.2.1 showed the preset's step, e.g. "+2 m")
        if unit == 'm': return '%s (%g m behind)' % (name, round(1.5 + v * math.cos(math.radians(10)), 1))
        return '%s (x%s)' % (name, v)
    return [{'Name': label(name, mult), 'Description': desc, 'Include': [folder] + list(extra)} for folder, name, mult, desc in presets]


def package(kind):
    """kind: 'test' (NAME_SUFFIX, tester logging), 'release' or 'tester' (the release with tester logging)."""
    release = kind != 'test'
    version = VERSION + ('' if release else NAME_SUFFIX)
    out = os.path.join(HERE, 'build', kind); os.makedirs(out, exist_ok=True)
    core = core_source(version + ('' if kind == 'release' else ' (tester)'), kind != 'release')
    tflag = 'false' if kind == 'release' else 'true'       # tester logging: test and Tester builds only
    turret_src = open(os.path.join(HERE, 'mbt_turrets.lua.in'), encoding='utf-8').read().replace('@@VERSION@@', version) \
        .replace('@@TESTER@@', tflag)
    turrets = turret_src
    assert '@@' not in turrets
    handling_src = open(os.path.join(HERE, 'handling.lua.in'), encoding='utf-8').read().replace('@@VERSION@@', version) \
        .replace('@@TESTER@@', tflag)
    variants = {}      # folder -> (addon name, source)
    for part, addon, presets in (('grip', HANDLING, GRIP_PRESETS), ('steering', STEERING, STEERING_PRESETS), ('power', POWER, POWER_PRESETS)):
        for folder, name, mult, _ in presets:
            src = handling_src.replace('@@ADDON@@', addon).replace('@@PART@@', part).replace('@@PRESET_NAME@@', name) \
                .replace('@@PRESET@@', repr(float(mult)))
            assert '@@' not in src
            variants[folder] = (addon, src)
            open(os.path.join(out, '%s_%s.lua' % (part, name.lower())), 'w', encoding='utf-8').write(src)
    tracker = open(os.path.join(HERE, 'turret_tracker.lua.inc'), encoding='utf-8').read()
    camera_src = open(os.path.join(HERE, 'camera.lua.in'), encoding='utf-8').read().replace('@@VERSION@@', version) \
        .replace('@@TESTER@@', tflag).replace('@@TURRET_TRACKER@@', tracker)
    for folder, name, mult, _ in CAMERA_PRESETS:
        src = camera_src.replace('@@PRESET_NAME@@', name).replace('@@PRESET@@', repr(float(mult)))
        assert '@@' not in src
        variants[folder] = (CAMERA, src)
        open(os.path.join(out, 'camera_%s.lua' % name.lower()), 'w', encoding='utf-8').write(src)
    # the sims' default files: the x1.5 strengths
    open(os.path.join(out, 'handling.lua'), 'w', encoding='utf-8').write(variants['Grip Strong'][1])
    open(os.path.join(out, 'steering.lua'), 'w', encoding='utf-8').write(variants['Steering Quick'][1])
    ind_src = open(os.path.join(HERE, 'indicator.lua.in'), encoding='utf-8').read().replace('@@VERSION@@', version) \
        .replace('@@TESTER@@', tflag).replace('@@TURRET_TRACKER@@', tracker)
    indicator = part_source(ind_src, 'outline').replace('@@ADDON@@', INDICATOR).replace('@@GLOBAL@@', 'ArmoredOverhaulIndicator')
    panel = part_source(ind_src, 'panel').replace('@@ADDON@@', PANEL).replace('@@GLOBAL@@', 'ArmoredOverhaulDriverPanel')
    for src in (indicator, panel):
        assert '@@' not in src
    open(os.path.join(out, 'indicator.lua'), 'w', encoding='utf-8').write(indicator)
    open(os.path.join(out, 'driver_panel.lua'), 'w', encoding='utf-8').write(panel)
    open(os.path.join(out, 'gunner_drive_on.lua'), 'w', encoding='utf-8').write(FLAG_SRC)
    open(os.path.join(out, 'gunner_drive.lua'), 'w', encoding='utf-8').write(core)
    open(os.path.join(out, 'mbt_turrets.lua'), 'w', encoding='utf-8').write(turrets)
    manifest = {
        'Version': 1, 'Guid': GUID_LIVE if kind == 'release' else GUID_TEST,
        'Name': 'Armored Overhaul ' + version + (' (Tester)' if kind == 'tester' else ''), 'IconPath': 'thumbnail.png',
        'Description': ('PERSONAL TESTER BUILD: the release with extra logging. Install instead of the '
                        'release, not next to it. ' if kind == 'tester' else '')
                       + 'Upgrades for the TD-220 Bastion and TD-110 Maelstrom tanks, each an option: engine power, track '
                       'grip, steering and suspension; a main battle tank turret that turns all the way round, with its '
                       'traverse speed, elevation speed and aim range; a turret indicator with the tank\'s health; '
                       'driving from the gunner seat; a gunner camera distance; and FRV stability. '
                       'Requires Bingus Shared Loader.',
        'Options': [
            {'Name': 'Tank power', 'Description': 'More engine pulling power for the Bastion and Maelstrom: quicker off '
             'the line, up slopes and through rough ground. Top speed stays the game\'s own. Pick how much; turn the '
             'option off for the game\'s own engine.',
             'Image': 'options/tank_power.png', 'SubOptions': suboptions(POWER_PRESETS)},
            {'Name': 'Tank grip', 'Description': 'More track grip for the Bastion and Maelstrom: they hold their line on '
             'slopes and in turns instead of sliding. Pick how much; turn the option off for the game\'s own grip.',
             'Image': 'options/tank_grip.png', 'SubOptions': suboptions(GRIP_PRESETS)},
            {'Name': 'Tank suspension', 'Description': 'Stiffer, better damped suspension for the Bastion and Maelstrom: '
             'less bouncing and body roll. Pick Firm or Heavy; turn the option off for the game\'s own suspension.',
             'Image': 'options/tank_suspension.png',
             'SubOptions': [
                 {'Name': 'Firm', 'Description': 'Springs a third stiffer and three times the bump damping.',
                  'Include': ['Suspension Firm']},
                 {'Name': 'Heavy', 'Description': 'Springs two thirds stiffer and six times the bump damping, for a '
                  'planted, heavy ride.', 'Include': ['Suspension Heavy']},
             ]},
            {'Name': 'Tank steering', 'Description': 'Quicker steering response for the Bastion and Maelstrom: they start '
             'and stop turning sooner, so they turn in place and change direction more readily. Pick how quick; turn '
             'the option off for the game\'s own steering.',
             'Image': 'options/tank_steering.png', 'SubOptions': suboptions(STEERING_PRESETS)},
            {'Name': 'Turret indicator', 'Description': 'While you sit in the Bastion or Maelstrom, a small tank outline on '
             'your screen shows which way the turret points compared to the hull, like a real tank\'s display: the '
             'Helldivers skull is your turret and always points up, the hull turns around it with a marker at its front, '
             'and its color shows the tank\'s health (blue, green, yellow, orange, red). With Gunner Drive it sits just '
             'left of the driver panel. Only you see it. Move, resize or adjust it in ArmoredOverhaul-TurretIndicator.cfg '
             'in the Bingus logs folder.',
             'Image': 'options/turret_indicator.png', 'Include': ['Tank Core', 'Turret Indicator', 'Turret Skull']},
            {'Name': 'MBT Turrets', 'Description': 'The Bastion and Maelstrom guns turn all the way round, and the whole top '
             'of the tank turns with them like a main battle tank turret, built from the game\'s own armor. The guns '
             'can also aim lower (6 degrees below level, twice the game\'s 3). The gunner view turns with it. On the Maelstrom the missile pods ride on the back of the turret and the smoke launchers '
             'turn with it too. Turret armor always looks undamaged. Only you see the new turret models; other '
             'players see the normal tanks.',
             'Image': 'options/mbt_turrets.png', 'Include': ['Turret Core', 'MBT Turrets', 'Turret Models']},
            {'Name': 'Turret traverse', 'Description': 'How fast the Bastion and Maelstrom turrets turn side to side. '
             'Pick how fast; turn the option off for the game\'s own speed. Works with or without MBT Turrets.',
             'Image': 'options/turret_traverse.png',
             'SubOptions': [{'Name': '%s (x%g)' % (n, m), 'Description': d, 'Include': [f, 'Turret Core']} for f, n, m, d in TRAVERSE_PRESETS]},
            {'Name': 'Turret elevation', 'Description': 'How fast the Bastion and Maelstrom guns move up and down. Pick how '
             'fast; turn the option off for the game\'s own speed.',
             'Image': 'options/turret_elevation.png',
             'SubOptions': [{'Name': '%s (x%g)' % (n, m), 'Description': d, 'Include': [f, 'Turret Core']} for f, n, m, d in ELEVATION_PRESETS]},
            {'Name': 'Turret aim range', 'Description': 'How far down and up the Bastion and Maelstrom guns aim. The gunner '
             'view follows. Pick a range; turn the option off for the game\'s own (with MBT Turrets: 6 below to 25 above).',
             'Image': 'options/turret_aim_range.png',
             'SubOptions': [{'Name': '%s (%+g..%+g deg)' % (n, r[0], r[1]), 'Description': d, 'Include': [f, 'Turret Core']} for f, n, r, d in RANGE_PRESETS]},
            {'Name': 'Gunner Drive', 'Description': 'Drive the Bastion or Maelstrom from the gunner seat when nobody is in '
             'the driver seat. You stay the gunner: the turret HUD, camera and fire keys work as normal while your '
             'movement keys drive the tank. While you drive, a driver panel like the game\'s own shows the gear, rpm, '
             'speed and fuel (only you see it; move it or turn it off in ArmoredOverhaul-DriverPanel.cfg in the Bingus '
             'logs folder). In the Maelstrom, Mouse 3 (or the left stick click on a controller) pops the smoke screen.',
             'Image': 'options/gunner_drive.png', 'Include': ['Tank Core', 'Gunner Drive']},
            {'Name': 'Gunner camera', 'Description': 'How far behind the turret the gunner camera follows in the Bastion '
             'and Maelstrom: lower than the game\'s and rising only a little as it goes back, so you see more around the tank. '
             'The camera stays behind the turret as it turns. Pick a distance; '
             'turn the option off for the game\'s own.',
             'Image': 'options/gunner_camera.png', 'SubOptions': suboptions(CAMERA_PRESETS, 'm', ['Tank Core'])},
            {'Name': 'FRV stability', 'Description': 'The M-102 FRV, M-103 Supply FRV and M-104 incendiary FRV stay on '
             'their wheels over rough ground, jumps and hard turns: the soft front suspension gets the rear\'s damping, '
             'the center of mass sits lower and the chassis resists rolling. Pick how much; mass, grip, speed and '
             'steering stay the game\'s own.',
             'Image': 'options/frv_stability.png',
             'SubOptions': [
                 {'Name': 'Mild', 'Description': 'Calmer front end and a slightly lower center of mass: still lively, '
                  'far less likely to roll.', 'Include': ['FRV Mild']},
                 {'Name': 'Stable', 'Description': 'Stays on its wheels in hard turns and over jumps; still slides and '
                  'drifts.', 'Include': ['FRV Stable']},
                 {'Name': 'Planted', 'Description': 'Very hard to roll: a low center of mass and a stiff chassis. '
                  'Feels heavier in turns.', 'Include': ['FRV Planted']},
             ]},
        ],
    }
    zpath = os.path.join(out, 'Armored-Overhaul-%s%s.zip' % (version.replace(' ', '-'), '-Tester' if kind == 'tester' else ''))
    with zipfile.ZipFile(zpath, 'w', zipfile.ZIP_DEFLATED) as z:
        names = [o['Name'] for o in manifest['Options']]
        assert sorted(names) == sorted(OPTION_ORDER), names
        manifest['Options'].sort(key=lambda o: OPTION_ORDER.index(o['Name']))
        # (2.0) every sub-option has its own icon: the option's glyph over a level gauge (art/icons.py SUBS=1)
        for o in manifest['Options']:
            for sub in o.get('SubOptions', []):
                img = 'options/sub/%s.png' % sub['Include'][0].lower().replace(' ', '_')
                assert os.path.exists(os.path.join(HERE, img)), img
                sub['Image'] = img
        z.writestr('manifest.json', json.dumps(manifest, indent=2))
        z.write(os.path.join(HERE, 'art', 'thumbnail.png'), 'thumbnail.png')
        for opt in manifest['Options']:
            z.write(os.path.join(HERE, opt['Image']), opt['Image'])
            for sub in opt.get('SubOptions', []):
                z.write(os.path.join(HERE, sub['Image']), sub['Image'])
        for folder, entries in {'Tank Core': [(resource_hash(CORE), resource(core))],
                                'Gunner Drive': [(resource_hash(DRIVE_FLAG), resource(FLAG_SRC)), (resource_hash(PANEL), resource(panel))],
                                'Turret Core': [(resource_hash(TURRETS), resource(turrets))],
                                'MBT Turrets': [(resource_hash(TURRET_FLAGS['mbt']), resource(turret_flag('mbt', True)))],
                                **{f: [(resource_hash(TURRET_FLAGS['traverse']), resource(turret_flag('traverse', m)))] for f, _, m, _ in TRAVERSE_PRESETS},
                                **{f: [(resource_hash(TURRET_FLAGS['elevation']), resource(turret_flag('elevation', m)))] for f, _, m, _ in ELEVATION_PRESETS},
                                **{f: [(resource_hash(TURRET_FLAGS['range']), resource(turret_flag('range', r)))] for f, _, r, _ in RANGE_PRESETS},
                                **{folder: [(resource_hash(addon), resource(src))] for folder, (addon, src) in variants.items()}}.items():
            base = folder + '/9ba626afa44a3aa3.patch_0'
            z.writestr(base, archive(entries)); z.writestr(base + '.gpu_resources', b''); z.writestr(base + '.stream', b'')
        # the skull texture in its own folder (its own patch), so the indicator's Lua archive stays Lua only
        base = 'Turret Indicator/9ba626afa44a3aa3.patch_0'
        z.writestr(base, archive([(resource_hash(INDICATOR), resource(indicator))])); z.writestr(base + '.gpu_resources', b''); z.writestr(base + '.stream', b'')
        toc, gpu = mixed_archive([], [(resource_hash(SKULL_TEX), texture_rgba(os.path.join(HERE, 'art', 'skull_header_icon.png')))])
        check_texture_patch(toc, gpu, resource_hash(SKULL_TEX), 64, 64)
        base = 'Turret Skull/9ba626afa44a3aa3.patch_0'
        z.writestr(base, toc); z.writestr(base + '.gpu_resources', gpu); z.writestr(base + '.stream', b'')
        for ext in ('', '.gpu_resources', '.stream'):
            z.write(os.path.join(HERE, 'models', '9ba626afa44a3aa3.patch_0' + ext), 'Turret Models/9ba626afa44a3aa3.patch_0' + ext)
            for preset in ('Suspension Firm', 'Suspension Heavy', 'FRV Mild', 'FRV Stable', 'FRV Planted'):
                z.write(os.path.join(HERE, 'physics', preset, '9ba626afa44a3aa3.patch_0' + ext), preset + '/9ba626afa44a3aa3.patch_0' + ext)
    print('built', zpath)
    return zpath


if __name__ == '__main__':
    for kind in (('release', 'tester') if 'release' in sys.argv else ('test',)):
        package(kind)
