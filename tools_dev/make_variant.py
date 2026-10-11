"""Armored Overhaul - builds a numbered test build from src/ (the release form of every file).

  python tools_dev/make_variant.py test N        -> src/build/Armored-Overhaul-<version>-Test-N.zip

(4.6.6-era rebuild of the lost work-tree tool; it reproduces 3.5.1 Test 5 byte for byte from the 3.5.1 source.)
A numbered test build is the release with, in every Lua addon that writes a log:
- the test-log helper block after the addon line (logs go to Logs\\test),
- the log opened through that helper instead of the loader's open_log,
- TESTER switched on and the version shown as '<version> Test N';
plus the test-only Research Probe addon (tools_dev/Research Probe.lua) in every option that includes Tank Core, the test
GUID (it installs next to the release and updates in place) and the test thumbnail. Game parts and icons are the
release's own (tools/unpack_release.py first, as for build.py).
"""
import json, os, re, sys, zipfile
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), 'src')
sys.path.insert(0, SRC)
import build   # noqa: E402  (src/build.py: lua_text, lua_patch, zput, the folder lists)

GUID_TEST = '8d3e5a71-2c94-4f06-b1e8-6a7c0d9f4e25'
PROBE = 'Research Probe'
HELPER = b"""if not rawget(_G, 'ArmoredOverhaulTestLog') then rawset(_G, 'ArmoredOverhaulTestLog', function(name)   -- (test build: logs in Logs\\test)
    local dir = rawget(_G, 'ArmoredOverhaulLogsDir')
    local root = dir and dir()                       -- (3.3.0) the loader's log folder (v19), else LOCALAPPDATA's
    if root and root ~= '' and type(package) == 'table' and type(package.config) == 'string' and package.config:sub(1, 1) == '\\\\' then
        local f = io.open(root .. '\\\\test\\\\' .. name, 'w')
        if f then return f end
    end
    local L = rawget(_G, 'CowboyBingusModLoader')
    return type(L) == 'table' and L.open_log and L.open_log(name)
end) end
"""
OPEN_LOG = b'loader.open_log and loader.open_log('
TEST_LOG = b"rawget(_G, 'ArmoredOverhaulTestLog')("


def test_lua(text, version, n):
    """The release Lua of one addon as numbered test build n has it."""
    if OPEN_LOG not in text:
        return text                                    # (the tiny flag addons: no log, unchanged)
    tag = ('%s Test %d' % (version, n)).encode()
    first, rest = text.split(b'\n', 1)
    rest = rest.replace(b'Armored Overhaul ' + version.encode() + b' ', b'Armored Overhaul ' + tag + b' ', 1)
    rest = rest.replace(b"'" + version.encode() + b"'", b"'" + tag + b"'")
    rest = rest.replace(OPEN_LOG, TEST_LOG)
    rest, k = re.subn(rb'^local TESTER = false(\s)', rb'local TESTER = true\1', rest, flags=re.M)
    assert k <= 1, 'more than one TESTER line'
    return first + b'\n' + HELPER + rest


def test_manifest(manifest, version, n):
    m = json.loads(manifest)
    m['Guid'], m['Name'] = GUID_TEST, 'Armored Overhaul %s Test %d' % (version, n)
    for o in m['Options']:
        for x in [o] + o.get('SubOptions', []):
            if 'Tank Core' in x.get('Include', []) and PROBE not in x['Include']:
                x['Include'].append(PROBE)
    return json.dumps(m, indent=2, ensure_ascii=False).encode()


def main():
    if len(sys.argv) != 3 or sys.argv[1] != 'test' or not sys.argv[2].isdigit():
        sys.exit('usage: python tools_dev/make_variant.py test N')
    n = int(sys.argv[2])
    manifest = build.read_text(os.path.join(SRC, 'manifest.json'))
    version = json.loads(manifest)['Name'].rsplit(' ', 1)[-1]
    out_dir = os.path.join(SRC, 'build'); os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, 'Armored-Overhaul-%s-Test-%d.zip' % (version, n))
    with zipfile.ZipFile(out + '.tmp', 'w') as z:
        build.zput(z, 'manifest.json', test_manifest(manifest, version, n))
        build.zput(z, 'thumbnail.png', open(os.path.join(HERE, 'test_thumbnail.png'), 'rb').read())
        for im in build.IMAGES:
            build.zput(z, 'options/%s.png' % im, open(os.path.join(SRC, 'options', im + '.png'), 'rb').read())
        lua = [(f, test_lua(build.lua_text(f), version, n)) for f in build.LUA_FOLDERS]
        lua.append((PROBE, build.read_text(os.path.join(HERE, PROBE + '.lua'))))
        for folder, text in lua:
            for ext, data in zip(('', '.gpu_resources', '.stream'), build.lua_patch(text)):
                build.zput(z, '%s/%s%s' % (folder, build.PATCH, ext), data)
        for folder, sub in build.GAME_FOLDERS:
            for ext in ('', '.gpu_resources', '.stream'):
                build.zput(z, '%s/%s%s' % (folder, build.PATCH, ext), open(os.path.join(SRC, sub, build.PATCH + ext), 'rb').read())
    os.replace(out + '.tmp', out)
    print('wrote', os.path.relpath(out, SRC), 'Armored Overhaul %s Test %d' % (version, n))


if __name__ == '__main__':
    main()
